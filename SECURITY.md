# Security

Token Bar is a local macOS utility. It reads local tool logs, stores counts
under `~/Library/Application Support/CodexTokenBar/`, and contacts no service
of its own; installed provider tools may contact their providers with your
existing sign-ins. A security issue is anything that breaks those boundaries:
data leaving the Mac, credentials being read, private files being written
world-readable, or a signed installer differing from its commit.

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

Every advertised installer is a notarized GitHub Release asset with a SHA-256
in `site/public/release.json`. `./scripts/verify-release.sh <commit>
<package.pkg>` proves a package came from a commit.
