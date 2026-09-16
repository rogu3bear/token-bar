# Security

Token Bar is a local macOS utility. It reads local tool logs, stores counts
under `~/Library/Application Support/CodexTokenBar/`, and does not upload usage
history or add telemetry. Installed provider tools
may contact providers using existing sign-ins. Grok attribution reads identity
fields from its local auth file; credential values must not be exported or
logged. Voluntary reports are drafted in the browser and sent to GitHub in a
review URL only after an explicit action; they are intended for public issues.
Security issues include unintended data disclosure, credential exposure,
world-readable private state, or an installer
differing from its declared source.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/rogu3bear/token-bar/security/advisories/new)
(Security → Report a vulnerability), which is enabled for this repository.
The app's Feedback button and website prepare public issues; do not use them
for security reports. If private reporting is unavailable, keep exploit details
and private data out of public issues.

Include the app version (`VERSION` or About), macOS version, a minimal
synthetic reproduction, and the affected file or surface. Never include
credentials, API keys, account identifiers, usage ledgers, transcripts, or
raw logs. There is no guaranteed response time; the maintainer will confirm
receipt through the same private channel.

## Verifying a release

The public installer and basename-only checksum are attached to the
[v0.1 Release](https://github.com/rogu3bear/token-bar/releases/tag/v0.1).
`site/public/release.json` binds the asset URL and SHA-256. Verify the checksum
before opening the installer; macOS also checks the Developer ID signature and
stapled notarization ticket. The source verifier additionally rebuilds and
compares the complete unsigned package:

```sh
./scripts/verify-release.sh <source-commit> <package.pkg>
```

Use the release tag's commit, not a later documentation commit. GitHub Releases
is the installer distribution path. A registry digest does not establish Apple
signing or notarization. See [the release guide](docs/RELEASING.md)
for the separate trust checks and current distribution status.
