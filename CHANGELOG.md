# Changelog

## 0.1.2 — Released 2026-09-13

- Restore equal active-provider columns and aligned separators, quota rows and large gauges on Now, with complete rate digits and explicit units.
- Compare full request cost per output token, with daily/model coverage, and inspect sourced model API rate changes by effective date.
- Compare account-bound Codex allowance changes with the locally observed input/output/cache mix over matching retained intervals. Resets, gaps and ambiguous evidence remain explicit; no model-specific subscription tariff or host identity is inferred.
- Reuse background comparison results across navigation and matching archived timing when available. Bound archived timing recovery to relevant groups, reuse unchanged history, and retry visible failures with backoff.

### 0.1.1 work included in 0.1.2

These changes shipped in 0.1.2; there was no separate public 0.1.1 release.

- Keep History and Cost reports warm across navigation; publish completed results while new usage is queued.
- Persist the report index and extend it with appended usage instead of rebuilding settled entries.
- Persist private per-chat prompt statistics and byte checkpoints; relaunch and repeat reads reuse processed chats, and changed chats read only their new tail. Prompt text stays out of storage.
- Show native menu-bar and dashboard previews at the top of README.

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
README used the direct v0.1 Release asset at launch. Installation needs no build tools or reboot.
Claude after-turn account allowance refresh remains unavailable; the
account-matched local cache is used when fresh. OpenCode provides history only.
