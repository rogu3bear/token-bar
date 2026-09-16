# macOS release

The current public release is **v0.1.7**, with application version **0.1.7** and build
**30107**. [Download the signed, notarized installer](https://github.com/rogu3bear/token-bar/releases/download/v0.1.7/TokenBar-0.1.7-arm64.pkg)
for Apple silicon and macOS 14 or later. Open the `.pkg`, follow macOS Installer,
then open Token Bar from Applications. No build tools or reboot are required.
The installer preserves existing usage history and preferences.

The app and installer are separately signed: Developer ID Application for the
app, Developer ID Installer for the `.pkg`. Maintainers store notarization
credentials in Keychain; users need none of these to install.

## Preparing the successor

The source candidate is **0.1.8**, build **30108**. It keeps Auto quiet unless a
tool is working, freezes glance grammar in `docs/DESIGN.md`, and treats Claude
at a measured-zero remaining as the one idle named exception. It is not a
public download until its exact source-bound installer passes signing,
notarization, source binding and the authorized publication step. The public
links above, the README download and the site release manifest remain on 0.1.7
until that publication is verified.

## Current release binding

The v0.1.7 tag is bound to source commit
`b93352d104f5b7dca7709b7d6e059010181bea2f`. The signed, notarized package
reproduces from that commit through `scripts/verify-release.sh`. Its anonymous
GitHub download was verified on September 16, 2026: 3,958,088 bytes, SHA-256
`9d69a2d671f14a63691bc2fdb9dfe0beecb61a11d0d6be753ae993c8c52cc537`.
Later site and documentation commits do not move the native release tag.

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
Thus 0.1.0 becomes 30100, a higher build number than the earlier development
builds (202xx). Keep minor and patch components below 100 so build numbers
remain distinct. The bundle identifier and local storage paths stay stable
across this transition.

macOS Installer does not decide upgrades by build number. With bundle version
checking on, it compares the short version first, so an installed 2.x
development build counts as newer than any 0.1.x package: Installer skips the
bundle, still reports success and writes a receipt, and the old app stays.
Packages 0.1.0 through 0.1.4 behave this way over a 2.x build (reproduced from
`/var/log/install.log` and a synthetic-bundle install). From 0.1.5 the component
plist leaves version checking off, and `preinstall` compares build numbers
itself: it replaces an older or legacy build, reinstalls the same build in
place, and refuses a newer installed build with a visible error before stopping
anything. `package.sh` stages the packaged bundle's exact `CFBundleVersion`
beside the scripts for that comparison, and a package without it fails closed.
Anyone on a 2.x build who installs 0.1.4 or earlier must first move the old
`/Applications/Token Bar.app` to the Trash.

The package installs only `/Applications/Token Bar.app`, explicitly sets
BundleIsRelocatable to false in its component plist, and declares `upgrade-bundle`
and `strict-identifier`. Expanded PackageInfo must not list a relocation bundle,
and its `bundle-version` element must be empty.
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

It checks any checksum sidecar beside the package first, then rebuilds the
unsigned installer using the commit's own scripts. Disposable
expanded copies have their app signatures removed; complete executable bytes,
payload paths and modes, resources, installer scripts and install metadata must
match. Signature directories, signing-dependent installed sizes and the `__LINKEDIT`
mapping size that signature removal leaves behind are excluded; that size must
stay page-aligned and within signature slack of the compared file size.
Unexpected payloads and toolchain differences fail closed. This content check
is separate from the shipped package signature and notarization checks. A stapler
exit of 68 means Apple could not be reached, not that a ticket is invalid.

## GitHub publication

Bind the exact clean source commit, version, final package hash, notarization
receipt and local test receipts. Inspect remote workflow policy; no Actions
should run. GitHub Releases is the primary public installer distribution path.
Upload the notarized `.pkg` and its checksum. Keep notarization receipts, logs
and account-specific evidence local.

The checksum must name only the installer basename, never a private build
path: the file is published beside the installer, and a path in it fails
`shasum -a 256 -c` for every downloader. `scripts/checksum.sh` is the single
owner of that rule. `package.sh` calls it after `pkgbuild`, and `release.sh`
calls it again immediately after stapling, because stapling rewrites the
package. `verify-release.sh` fails when a sidecar beside the package names
something else or does not match its bytes, and says so when none exists.
`Tests/SingleInstance/release.py` covers `checksum.sh`, `package.sh` reaching
it, and that gate.

Confirm before upload, from the release output directory:

```sh
shasum -a 256 -c TokenBar-0.1.7-arm64.pkg.sha256
```

A package built before commit `24d4d0c` carries a sidecar naming an absolute
path. Regenerate it with `./scripts/checksum.sh <package>`.

Use the actual `VERSION` for later releases. A public tag remains bound to its
original source; later documentation commits do not move the release tag.

Draft releases may hold development artifacts during preparation, but are not public downloads. An unsigned development package must never be described as a signed release or linked by the public download manifest.

After release publication, update `site/public/release.json` with `available: true`, the exact GitHub asset URL, package SHA-256, and `notarized: true`. Deploy the site with `cfctl` under `docs/DEPLOYMENT.md` and verify the public download resolves to the same bytes.

The existing bundle identifier is retained to preserve upgrades and saved menu-bar settings. Package installation does not delete local usage history or alter the user's Codex installation.

## GitHub Packages

GitHub Releases is the only installer distribution path. A private OCI archive
`ghcr.io/rogu3bear/token-bar:0.1.0` was uploaded at the initial public release.
It is not the current 0.1.7 installer, not an anonymous download, and not a
runnable container. Do not publish a new Packages copy; do not treat a registry
digest as Apple signing or notarization. Delete the leftover listing with a
token that has `delete:packages` (this checkout's `gh` token has
`write:packages` only).
