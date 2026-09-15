# macOS release

The current public release is **v0.1.3**, with application version **0.1.3** and build
**30103**. [Download the signed, notarized installer](https://github.com/rogu3bear/token-bar/releases/download/v0.1.3/TokenBar-0.1.3-arm64.pkg)
for Apple silicon and macOS 14 or later. Open the `.pkg`, follow macOS Installer,
then open Token Bar from Applications. No build tools or reboot are required.
The installer preserves existing usage history and preferences.

The app and installer are separately signed: Developer ID Application for the
app, Developer ID Installer for the `.pkg`. Maintainers store notarization
credentials in Keychain; users need none of these to install.

## Preparing the successor

The source candidate is **0.1.4**, build **30104**. It is not a public download
until its exact source-bound installer passes signing, notarization, source
binding and the authorized publication step. The public links above, the README
download and the site release manifest remain on 0.1.3 until that publication
is verified. The candidate's website copy, including the privacy page's Claude
usage refresh, deploys with that publication through the registered Cloudflare route.

## Current release binding

The v0.1.3 tag is bound to source commit
`a493aa0196521b39cd58d5b7b6e3bdaa0abb34db`. The signed, notarized package
reproduces from that commit through `scripts/verify-release.sh`. Its anonymous
GitHub download was verified on September 15, 2026: 3,962,631 bytes, SHA-256
`02bd08b0605319cd860ef25aed31510bc3ef9efbaf11f97e2108f8d7d20ed289`.
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

Before upload, ensure the checksum names only the installer basename, not a
private build path. From the release output directory:

```sh
shasum -a 256 TokenBar-0.1.3-arm64.pkg > TokenBar-0.1.3-arm64.pkg.sha256
shasum -a 256 -c TokenBar-0.1.3-arm64.pkg.sha256
```

Use the actual `VERSION` for later releases. A public tag remains bound to its
original source; later documentation commits do not move the release tag.

Draft releases may hold development artifacts during preparation, but are not public downloads. An unsigned development package must never be described as a signed release or linked by the public download manifest.

After release publication, update `site/public/release.json` with `available: true`, the exact GitHub asset URL, package SHA-256, and `notarized: true`. Deploy the site through the registered Cloudflare route and verify the public download resolves to the same bytes.

The existing bundle identifier is retained to preserve upgrades and saved menu-bar settings. Package installation does not delete local usage history or alter the user's Codex installation.

## GitHub Packages distribution

The separate [Packages listing](https://github.com/users/rogu3bear/packages/container/package/token-bar)
uses `ghcr.io/rogu3bear/token-bar:0.1.0`. It archives the initial 0.1.0 release,
not the current 0.1.3 installer. It contains
`TokenBar-0.1.0-arm64.pkg`, its basename-only `.sha256`, and `README.txt`.
This is an OCI distribution artifact, not a runnable macOS container. The
installer inside is byte-identical to the v0.1 Release asset.

As verified September 13, 2026, the package is uploaded and linked to the public
repository, but its own visibility remains **private**. Do not describe it as an
anonymous download. Package visibility is independent of the linked repository;
a maintainer changes it under Package settings → Change visibility. The public
Release download remains available regardless of registry visibility. See
[GitHub's visibility rules](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

Maintainer publication uses an authenticated OCI client with `write:packages`.
Retain an existing version if its digest already matches; reconcile any uncertain
upload before retrying. Include source, version, revision, license and a description
identifying the installer archive. Never add credentials or local operating records
to its layer. Link it with
`org.opencontainers.image.source=https://github.com/rogu3bear/token-bar`.
After publication, verify the registry digest, repository and visibility, then
export and compare the extracted installer with the Release checksum. Public
availability requires repeating the download anonymously.

An authorized registry user can extract it with the `crane` OCI client:

```sh
crane export ghcr.io/rogu3bear/token-bar:0.1.0 token-bar.tar
tar -xOf token-bar.tar TokenBar-0.1.0-arm64.pkg > TokenBar-0.1.0-arm64.pkg
tar -xOf token-bar.tar TokenBar-0.1.0-arm64.pkg.sha256 > TokenBar-0.1.0-arm64.pkg.sha256
shasum -a 256 -c TokenBar-0.1.0-arm64.pkg.sha256
```

Authenticate first while the listing is private. For ordinary macOS installation,
use the direct Release asset instead of installing registry tooling.
