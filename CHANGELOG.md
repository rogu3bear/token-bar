# Changelog

## Unreleased

- Give the installer the bundle identifier from the built Info.plist. pkgbuild no longer spells a second copy of the identity build.sh already wrote.
- Put remaining in the same Now column as that tool's rate and dial. Working Codex no longer shows 64% remaining on a full-bleed row while the gauge sits in a separate centered column.
- Admit Claude remaining when the cache still has utilization even if `resets_at` is null. A missing reset stays unavailable and is not a projected-zero clock; a failed decode is not a measured zero.

## 0.1.9 — Released 2026-09-16

- Keep Now columns aligned with working tools. Auto already stayed quiet and the popover already omitted unused remaining; Now still minted an empty Claude chair from a connection with no reading, so one Codex dial sat between two names. While any tool is working, Now shows exactly those tools. Measured remainings stay when nothing is working. Connection without a reading is not a seat.

## 0.1.8 — Released 2026-09-16

- Keep the menu bar quiet when nothing is running. Auto no longer invents an idle Codex readout, omits unused remaining (including unused Fable remaining and unused Codex or Grok zeros) and a measured Fable zero, and keeps Codex off the bar until it has a measured rate or is running. The dropdown still shows Claude at 0% when that remaining is a measured zero. Fable time left still says no recent use on an explicit or working Claude line. An enabled Quota Guard warning may appear on idle Auto as warning text, not occupancy. `docs/DESIGN.md` states that occupancy rule as a closed glance grammar: Claude-at-zero is the one named idle exception, not a pattern for the next tool.

## 0.1.7 — Released 2026-09-16

- Name History, Accounts and Settings owners in source so DestinationHost matches dashboard titles. The dashboard still uses the capsule destinations; this is not a scene rewrite.
- Declare CFBundlePackageType APPL so Launch Services treats the bundle as an application. The app already launched without it; this fills the omitted application package type.

## 0.1.6 — Released 2026-09-16

- Keep the menu-bar line readable while values change. The status item crossfaded every update, and when a number changed its digit count the whole line shifted, so for a moment it drew two offset copies of itself; with the Fable fields enabled this read as the line rolling to a different value. Text now crossfades only when the old and new lines align exactly, and otherwise switches at once while the speed dial still moves smoothly.

## 0.1.5 — Released 2026-09-16

- Replace an installed 2.x development build. macOS Installer compared short versions first, so 0.1.x packages reported a successful install while leaving the older 2.x app in place. The installer now compares build numbers itself, and refuses a newer installed build with a visible message instead of silently skipping.

## 0.1.4 — Released 2026-09-15

- Keep Claude Code allowance current: every 15 minutes Token Bar asks the installed Claude Code for usage, without a prompt or saved session, and reads only its account-matched cache. The status-line relay still supplies no quota.
- Add optional Fable quota and Fable time-left menu-bar fields. Fable quota is the lowest remaining of Claude’s 5-hour, weekly and Fable weekly limits, named by the limit that binds; time left projects the first of them to run out from a time-weighted average of recent burn.
- Compare Claude reset times at whole seconds so readings from one period line up, letting Claude projected zero and Quota Guard forecasts form.

## 0.1.3 — Released 2026-09-15

- Keep each active tool’s name, rate, status and model details attached to its speed gauge, with aligned column separators and provider-specific accessibility groups.
- Keep account allowances visible while tools are idle; hide Spark allowance cards on Accounts & plans without deleting saved account or plan history.
- Warn on fresh, account-bound quota exhaustion risk while keeping stale or unavailable readings explicit.
- Recover Codex log continuity and delayed appends without recounting previously admitted usage.
- Release synthetic preview models and database owners before removing their temporary files, including interactive close and failure paths.

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
An OCI archive with the identical installer was uploaded to GitHub Packages at
launch; that listing is private and is not the current 0.1.9 installer. The
public website and README used the direct v0.1 Release asset at launch.
Installation needs no build tools or reboot.
Claude after-turn account allowance refresh remains unavailable; the
account-matched local cache is used when fresh. OpenCode provides history only.
