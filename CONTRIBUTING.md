# Contributing

Open an issue describing the observable behavior or proposed improvement. Avoid posting account details, API keys, private task names, or raw usage logs. The app's Feedback button supports private contact email and a separately reviewed public issue draft.

Start with `README.md`, `ARCHITECTURE.md`, and the relevant guide under `docs/`.
Source and the website live together in this repository. Internal operating
notes and local verification records are excluded from the public tree.

Use a focused branch and synthetic fixtures. Run `./scripts/test.sh`, `(cd site && bun test)`, and `./scripts/build.sh` before proposing a change. Include what changed, why, and how it was checked. This repository uses local CI; do not add GitHub Actions workflows.

Before committing, run `python3 scripts/check-public-tree.py` against the staged
files. `.gitignore` cannot protect a file that Git already tracks. Keep credentials,
personal usage records and diagnostic captures out of commits; use synthetic
fixtures and sanitized configuration examples instead.

Preserve the distinction between measured counters, estimated speed, subscription quota, and historical account inference. New service integrations should keep credentials server-side and make data transmission explicit.

For a suspected security issue, follow [SECURITY.md](SECURITY.md): use GitHub private vulnerability reporting or [private feedback](https://token-bar-9v8.pages.dev/feedback/) and keep the optional GitHub draft unpublished. Include a minimal synthetic reproduction and affected version, never credentials or real transcripts. There is no guaranteed response time. If private feedback is unavailable, do not put exploit details or private data in a public issue.
