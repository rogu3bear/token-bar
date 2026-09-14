# Contributing

Open an issue describing the observable behavior or proposed improvement. Avoid posting account details, API keys, private task names, or raw usage logs. The app's Feedback button supports private contact email and a separately reviewed public issue draft.

Start with `README.md`, `ARCHITECTURE.md`, and the relevant guide under `docs/`.
Source and the website live together in this repository. Internal operating
notes and local verification records are excluded from the public tree.

Use a focused branch and synthetic fixtures. Install site dependencies with
`(cd site && bun install)` before the first site build. Native code changes need
the affected `./scripts/test.sh <group>` checks and `./scripts/build.sh`; site
behavior needs `(cd site && bun test && bun run build)`. A release runs all
thirteen native groups and the site tests. Documentation-only changes need
source/command/link verification and the public-tree check, not an unrelated
native rebuild. Include what changed, why, checks actually run and untested
behavior. This repository uses local CI; do not add GitHub Actions workflows.

Before committing, run `python3 scripts/check-public-tree.py` against the staged
files. `.gitignore` cannot protect a file that Git already tracks. Keep credentials,
personal usage records and diagnostic captures out of commits; use synthetic
fixtures and sanitized configuration examples instead.

Preserve the distinction between measured counters, estimated speed, subscription quota, and historical account inference. Native integrations use the provider's existing local sign-in; web-service secrets stay server-side. Make data transmission explicit and distinguish saved usage, process-only reports and fresh provider observations.

For a suspected security issue, follow [SECURITY.md](SECURITY.md): use GitHub private vulnerability reporting or [private feedback](https://token-bar-9v8.pages.dev/feedback/) and keep the optional GitHub draft unpublished. Include a minimal synthetic reproduction and affected version, never credentials or real transcripts. There is no guaranteed response time. If private feedback is unavailable, do not put exploit details or private data in a public issue.
