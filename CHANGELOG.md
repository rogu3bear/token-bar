# Changelog

## 0.1.0 — Initial public release

- Native macOS menu-bar readout for active AI tools, with explicit output-rate units.
- Local usage history for Codex, Claude Code, Grok and OpenCode.
- Account allowance where supported, with freshness and availability labels.
- Durable incremental storage and lazy report updates across launches and pages.
- History filters, CSV exports, API-equivalent cost estimates and local insights.
- Configurable menu-bar fields, rate units, appearance and accent color.
- Product website and private-contact feedback flow in the same source repository.

The public version sequence starts at 0.1.0. A Developer ID signed and
Apple-notarized macOS installer is available in the [v0.1 GitHub Release](https://github.com/rogu3bear/token-bar/releases/tag/v0.1).
An OCI archive with the identical installer is uploaded to GitHub Packages;
its listing remains private as of September 13, 2026. The public website and
README use the direct Release asset. Installation needs no build tools or reboot.
Claude after-turn account allowance refresh remains unavailable; the
account-matched local cache is used when fresh. OpenCode provides history only.
