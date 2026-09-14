# macOS release

The installer and app are different signed objects. A custom password alone cannot sign either. Use a Developer ID Application certificate for the app, a Developer ID Installer certificate for the `.pkg`, and an Apple app-specific password stored in Keychain for notarization.

## One-time credential setup

Create an app-specific password in the Apple account UI. In a local Terminal, run the following and supply the password only at the hidden prompt:

```sh
xcrun notarytool store-credentials codex-token-bar \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Do not put the password in a command argument, repository file, shell history, GitHub secret, or chat. This project needs no GitHub Actions credentials. The `codex-token-bar` profile name is safe to share; its contents are not.

Inspect public certificate identities with `security find-identity -v -p basic`. Set identity names or fingerprints in your local environment, then run:

```sh
export APP_SIGNING_IDENTITY='Developer ID Application: YOUR ORGANIZATION (TEAM_ID)'
export INSTALLER_SIGNING_IDENTITY='Developer ID Installer: YOUR ORGANIZATION (TEAM_ID)'
export NOTARY_PROFILE=codex-token-bar
./scripts/release.sh
```

The script runs local tests, builds with hardened runtime, signs the app and installer, submits the installer to Apple, requires `Accepted`, staples the ticket, checks the signature and Gatekeeper assessment, then records a SHA-256 checksum. It does not publish. Notarization receipts are versioned as `notarization-<version>.json` in the output directory. Both package and release commands refuse existing package/checksum outputs before building; release also refuses an existing receipt before testing or submission. Preserve and inspect an uncertain submission before retrying.

Outputs default to `dist/`. To retain older same-version artifacts, set
`TOKENBAR_DIST_DIR` to a fresh directory (absolute paths are recommended) for
both development packaging and release. A new directory is a new attempt, not
a way to resume an uncertain notarization submission. The source-binding
verifier ignores this override when rebuilding in its disposable source archive.

Inspect package contents with `pkgutil --expand-full` into a new scratch directory. Confirm `/Applications/Token Bar.app` is the only payload. Test installation and launch on a clean supported Mac before treating installation usability as verified.

## One install, one writer

`VERSION` is the public semantic version. The public sequence begins at 0.1.0.
`CFBundleVersion` uses a fixed epoch: 30000 + major × 10000 + minor × 100 + patch.
Thus 0.1.0 becomes 30100, newer than the earlier development builds (202xx).
Keep minor and patch components below 100 so build numbers remain distinct.
The bundle identifier and local storage paths stay stable across this transition.

The package installs only `/Applications/Token Bar.app`, explicitly sets
BundleIsRelocatable to false in its component plist, and declares `upgrade-bundle`
and `strict-identifier`. Expanded PackageInfo must not list a relocation bundle.
Its `preinstall` sends TERM only to the executable at that exact installed path,
waits up to ten seconds, and refuses to replace a still-running copy. It does
not request Apple Events permission or terminate development copies by name.
Installation on a non-startup volume is refused. `postinstall` re-registers the
installed bundle with Launch Services so the identifier resolves to
`/Applications` and not to a stale copy elsewhere.

The installer never deletes anything outside `/Applications`. Removing a
person's files is not an installer's job, so the app reports other copies
instead: `Token Bar.app/Contents/MacOS/TokenBar --find-duplicates`.

The real guarantee is at runtime and does not depend on the installer. The app
takes an exclusive lock beside the ledger at launch and holds it for the
process lifetime. A second copy, from any path and any version, is refused and
told which copy holds the history. That is what makes two writers impossible.

## Proving the binding

`scripts/release.sh` produces the package but does not prove which commit it
came from. Before publication, run:

```
./scripts/verify-release.sh <commit> dist/TokenBar-<version>-arm64.pkg
```

The app build passes repository-relative source paths to Swift from the
repository root. Absolute paths can change optimized runtime diagnostic
instructions when archive directory lengths differ. Source discovery still
owns membership; full executable comparison remains required.

It rebuilds the unsigned installer using the commit's own scripts. Disposable
expanded copies have their app signatures removed; complete executable bytes,
payload paths and modes, resources, installer scripts and install metadata must
match. Signature directories and signing-dependent installed sizes are excluded.
Unexpected payloads and toolchain differences fail closed. This content check
is separate from the shipped package signature and notarization checks. A stapler
exit of 68 means Apple could not be reached, not that a ticket is invalid.

## GitHub publication

Bind the exact clean source commit, version, final package hash, notarization receipt, and local test receipts. Inspect remote workflow policy; no Actions should run. Publish only the notarized package and checksum through the repository's GitHub Release. Keep receipt details and account-specific evidence local.

Draft releases may hold development artifacts during preparation, but are not public downloads. An unsigned development package must never be described as a signed release or linked by the public download manifest.

After release publication, update `site/public/release.json` with `available: true`, the exact GitHub asset URL, package SHA-256, and `notarized: true`. Deploy the site through the registered Cloudflare route and verify the public download resolves to the same bytes.

The existing bundle identifier is retained to preserve upgrades and saved menu-bar settings. Package installation does not delete local usage history or alter the user's Codex installation.
