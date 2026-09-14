# Security

Token Bar is a local macOS utility. It reads local tool logs, stores counts
under `~/Library/Application Support/CodexTokenBar/`, and does not upload usage
history or add telemetry. Installed provider tools
may contact providers using existing sign-ins. Grok attribution reads identity
fields from its local auth file; credential values must not be exported or
logged. Voluntary feedback opens the website and sends the submitted report
and contact email to the maintainer. Security issues include unintended data
disclosure, credential exposure, world-readable private state, or an installer
differing from its declared source.

## Reporting

- Preferred: GitHub private vulnerability reporting on this repository
  (Security → Report a vulnerability).
- Alternative: the app's Feedback button or the site's private feedback page,
  which reaches only the maintainer. Keep any optional public issue draft
  unpublished.

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

Use the release tag's commit, not a later documentation commit. An OCI copy in
GitHub Packages must contain identical installer bytes; a registry digest alone
does not establish Apple signing or notarization. See [the release guide](docs/RELEASING.md)
for the separate trust checks and current distribution status.
