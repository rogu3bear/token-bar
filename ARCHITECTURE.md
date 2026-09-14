# ARCHITECTURE.md

> Describes the shipped v0.1 system. Known limitations are listed separately;
> a future scene or navigation migration is not current implementation.

## Runtime shape

Two independent surfaces. A single-module Swift/SwiftUI menu-bar app compiled
with plain `swiftc` over sources discovered recursively (no Xcode project, no package
manifest, no third-party Swift code) runs as an accessory process on Apple
silicon, macOS 14+. A static Cloudflare Pages site under `site/` serves four
HTML pages and one small feedback API. They share product language and
native-rendered synthetic stills and recordings,
not application state or UI code.

## Components

| Component | Responsibility | Owns |
|---|---|---|
| `AppDelegate`, `UsageModel` (`App.swift`) | status item, popover, dashboard, timers, flag dispatch; observable hub for views | refresh cadence, query state |
| `UsageScanner` (`Usage.swift`) with `EventIndex`, `RequestArchive`, `UsageMetadata` | tail Codex logs from byte cursors, deduplicate, admit, compact | `ledger.json`, `ledger.events.sqlite`, `ledger.requests.sqlite` |
| `GrokUsage` | file-based Grok session usage through the same admission path; live activity from `active_sessions.json` and summary recency | Grok cursors in the ledger |
| `LogStream` | FSEvents watcher on Codex, Claude, Grok and OpenCode homes | nothing |
| `ActivityFeed`, `Activity`, `ClaudeActivityReader`, `Tachometer` | tool-scoped tasks, counter deltas, independent dials | in-memory |
| `ClaudeQuotaMonitor`, `ClaudeStatuslineConnection` | Account-matched Claude Code usage cache with a 30-minute horizon; identity-free relay is connection evidence only; Connect/Disconnect edits only `statusLine` in Claude Code's user settings; no credential or network access | In-memory quota samples; `claude-statusline-relay.sh` stable copy; `claude-statusline.json` is written by the relay, not the app; `settings.json.token-bar-backup-*` beside Claude Code settings |
| `GrokQuotaMonitor` | JSON-RPC to `grok agent --no-leader stdio`, `_x.ai/billing` | In-memory quota samples only |
| `LiveMonitor`, `LiveStateStore`, `ProviderUsage`, `CodexInstallation` | JSON-RPC to `codex app-server --stdio` for quota, plan, account usage | `live-accounts.sqlite`; legacy JSON retained for migration/rollback |
| `SignInTimeline`, `PlanHistory` | sign-in switches and plan observations | `sign-ins.json`, ledger plans |
| `Cost*`, `CoverageAudit` | dated API-equivalent estimates, coverage, recovery, audit | shipped rate data |
| `*View.swift`, `MenuBarSettings`, `Appearance`, `DashboardNavigation` | seven dashboard sections, popover, settings | `UserDefaults` preferences |
| `site/lib/*.mjs`, `site/worker.js`, `site/functions/` | feedback and config handlers; advanced-mode and Functions routing | nothing |

## Sources of truth

| Concern | Canonical owner | Derived views | Proof |
|---|---|---|---|
| Admitted usage | `~/Library/Application Support/CodexTokenBar/ledger.json` | reports, charts, CSV | `Tests/main.swift`, `Tests/Accuracy` |
| Event identity | `ledger.events.sqlite` plus in-flight ledger IDs | duplicate counts | `Tests/main.swift` |
| Request detail | `ledger.requests.sqlite` | request CSV, evidence panel | `Tests/Accuracy` |
| Quota and accounts | app-server responses, incrementally persisted in `live-accounts.sqlite` | runway, account cards | `Tests/main.swift`, `Tests/MenuBar` |
| Pricing | `CostRateCard` and `CostRateHistory` in source | cost report, CSV | `Tests/Cost`, `docs/COST.md` |
| Preferences | `UserDefaults` keys `appearance.*`, `menuBarConfiguration.v1`, `dashboard.rateUnit.<tool>` | tool units, menu bar title, theme | `Tests/Appearance`, `Tests/MenuBar` |
| Version | `VERSION` | Info.plist, package name, `release.json` | `scripts/build.sh` |
| Public download | Notarized GitHub Release asset; `site/public/release.json` binds its URL/hash | landing page button | `scripts/verify-release.sh`, `site/tests/site.test.mjs` |
| GitHub Packages copy | OCI artifact containing the same installer and checksum | repository Packages listing; visibility is independent | registry export and extracted installer SHA-256; `docs/RELEASING.md` |
| Harness and project | `session_meta.originator` and `cwd`, normalized by `Project` | harness and project reports | `Tests/Dimensions` |
| Claude Code usage | `CLAUDE_HOME`, then `CLAUDE_CONFIG_DIR`, then `~/.claude`, with `projects/**/*.jsonl` message snapshots plus verified increments; a missing explicit root stays unavailable | tool and project reports | `Tests/Harnesses` |
| OpenCode usage | `opencode.db` `message` table, read-only | tool, provider and project reports | `Tests/Harnesses` |
| Counter convention | `Tokens.canonical` | every total and cache share | `Tests/Harnesses` |

## Critical flows

### Log to ledger

1. FSEvents dispatch changed paths only to the owning provider, including OpenCode database/WAL and Codex catalog changes. Launch, Refresh history, dropped-event recovery and a 30-minute timer discover missed files. Full history discovery also rebinds newly present or changed Claude/OpenCode roots, retaining path-scoped history cursors and replacing obsolete live readers/watchers; no extra polling loop or restart is required. Catalog database events bypass the ordinary metadata throttle. Provider warnings persist across unrelated successful paths and clear only when the failed scope or a full provider scan succeeds; the failed scope survives restart. Grok child metadata remains available when its event precedes the child summary.
2. Read from the cursor offset; decode only `token_count`, `turn_context`,
   `session_meta` lines.
3. Claude uses persisted transcript byte cursors with boundary/inode checks, separate from live rate cursors. Only complete lines advance; counter baselines admit verified increases. OpenCode pages by a persisted `(time_created, id)` watermark and rereads unfinished messages by ID. Grok rereads only the changed session. Missing legacy baselines remain an explicit gap.
   OpenCode retains one read-only SQLite connection across scanner refreshes while the resolved database path and inode match. Missing or replaced files and failed scans release it; scanner teardown releases the final connection. Every page finalizes its statement so new WAL commits remain visible and checkpoints are not pinned between reads. Standalone full reads still scope their connection to that call; admission and cursor authority are unchanged.
4. Delta from previous totals; a first report or fork admits only
   `last_token_usage`; the identity hash is checked against the index.
5. Write pending to the archive, append to the ledger or a day bucket, save a dirty ledger atomically, index its captured IDs, then acknowledge archive rows. Indexed IDs retire from memory; JSON retains only the last recovery batch until the next genuine save. Failed index/ack phases retry without re-encoding. Delayed saves and normal termination flush outstanding work; storage-load failures preserve the original ledger. Cost recovery uses the same checkpoint owner.
   Cursor/provider-metadata-only changes atomically write `ledger.checkpoint.json` with no entries, bound by UUID to the full `ledger.json` baseline. Entry mutations still save the full ledger with a new UUID before indexing and acknowledgement. Restart overlays only matching metadata; stale checkpoints cannot replace newer totals. Invalid checkpoints fail closed. Legacy ledgers acquire a UUID on their next full save; older apps ignore the sidecar and may replay from older cursors, with the durable identity index retaining deduplication.
   The request archive calculates its admitted-row count once per connection, then updates it only for successful admissions. Rollback or another connection's committed database change invalidates that baseline; refreshes reuse the exact count without traversing all retained rows.
6. Publish saved usage before scanning, then admission snapshots at most twice
   per second and a final result before cost/catalog work. Reports rebuild on
   background queues, coalescing pending updates while retaining visible results.
   History and Cost share query state and publish together only for the current
   rebuild generation; their shared filter controls expose the scope on both pages. ReportEngine builds a date/context index per entry revision and reuses History when only pricing assumptions change. Metadata revisions and minute/future-entry boundaries invalidate the cache.
   Single-day charts use minute timestamps; display-only archive expansion must
   reconcile with daily aggregates before it can supply their timing.
   The usage store prepares the compact timeline per entry revision. Clock ticks only check for local midnight, a future record becoming current, clock rollback, or a calendar/time-zone change; SwiftUI body evaluation never aggregates history.

### Quota read

1. Every 30 seconds, or on `auth.json` change, spawn the Codex app-server.
2. `account/read`, `account/rateLimits/read`; re-read identity and reject the
   result on change.
3. Append a quota sample; compute runway from recent burn.
4. Show remaining percent, reset, and projected zero.
   Current metadata and ordered quota history commit in one SQLite transaction.
   Normal updates insert only new observations; retention removes expired rows
   without rewriting the retained range. Identical snapshots perform no writes.
   On first save, migration publishes a fully committed private database from a
   temporary path; the original `live-accounts.json` remains unchanged as rollback
   evidence, not a second writable store. A present database is authoritative:
   invalid metadata, missing history rows or corruption surface a load failure
   instead of silently restoring older JSON. Reopening reads saved observations
   once; it does not contact providers or replay source transcripts to restore them.
5. Grok remaining uses the installed `grok agent --no-leader stdio` process:
   `initialize`, then `_x.ai/billing`. No session is created. Used percent and
   period end map to a Grok-labeled reading; missing fields stay unavailable.
6. Claude remaining uses the passive cache whose own account matches
   `oauthAccount` in `~/.claude.json`. Claude Code's `cachedUsageUtilization`
   is refreshed only
   on demand (session start, its usage screen). `Assets/claude-statusline-relay.sh`
   ships in `Contents/Resources`; at launch `ClaudeConnectionModel` copies it,
   when its bytes differ, to a stable path in the support directory so the
   settings entry survives moving the app. **Connect Claude Code** (Claude
   panel, Menu bar settings, or `--claude-code connect`) edits only the
   `statusLine` key of the user-level Claude Code `settings.json` (respecting
   `CLAUDE_CONFIG_DIR`): relay alone when absent, relay prefixed to an existing
   command through `/bin/sh -c` otherwise, with a timestamped backup (three
   kept) and an atomic
   replace. The previous value is remembered in preferences so Disconnect
   restores it, or only strips the relay prefix if the user edited the command
   since. A `settings.local.json` status line is reported as shadowing, not
   changed. Claude Code then pipes its status JSON, including `rate_limits`,
   after every turn and the relay stores it 0600 as `claude-statusline.json`;
   with no chained command the relay prints a short default line via `jq` or
   JXA. The relay has no originating account identity, so its readings are
   rejected as quota evidence even across restart. Only account-matched cache
   observations supply quota. Readings older than `ClaudeQuotaSource.horizon`
   (30 minutes) are unavailable; older than two minutes they show their age.
   State is Connected (settings hold the relay and a relay reading has been
   seen), Configured, or Not connected.

### Feedback

1. The app opens the site with only its version in the URL.
2. The page loads config, then Turnstile; submit posts JSON to `/api/feedback`.
3. The server checks exact Origin, body size, field bounds, Turnstile hostname
   and action, and refuses an email inside public fields.
4. Resend accepts the mail to the fixed recipient; only then a reference and an
   email-free GitHub issue draft URL return.

## Boundaries

- Prompt text never crosses into the ledger, archive, exports, or previews.
- Provider-reported cost never crosses into the estimate total.
- Credential values are not exported or logged. Grok account binding reads
  identity fields from its local auth file; provider subprocesses use existing
  sign-ins. Feedback secrets stay server-side; the public origin and Turnstile
  site key are intentionally returned by the config endpoint.
- Preview and audit modes never cross into the real support directory.
- The site never becomes a control plane; deployment stays with the Cloudflare
  Authority.

## Known divergence

**Claude Code multi-iteration messages.** A message may carry an `iterations`
array whose counters sum higher than the message-level `usage`. Token Bar
reports the message-level figure, which is the provider's own statement for
that message. It does not substitute the sum of iteration counters, so those
two representations can differ. Synthetic fixtures in `Tests/Harnesses`
pin this choice.

- Internal counters remain Codex-shaped: cache reads sit within input and
  reasoning within output. Adapters convert disjoint provider fields through
  `Tokens.canonical` before admission.
- Claude and OpenCode counters are read locally with tool-scoped identities.
  Claude streams into live activity; OpenCode remains history-only.
- Pricing covers OpenAI models only. Anthropic, local, and free models stay
  unpriced by design until a dated rate card exists.
- Codex quota uses the app-server. Claude quota reads only account-matched
  local files: Claude Code's account-matched usage cache. The status-line relay
  only proves connection transport; its quota observations have no identity.
  Grok remaining uses the installed Grok
  agent’s `_x.ai/billing` reading. OpenCode has no quota integration.
- Grok counters come from `usage.json`. Live activity uses
  `active_sessions.json` and summary `last_active_at`;
  `usage.json` age is not a liveness signal. Project comes from summary `info.cwd`.
- Prompt insights read Codex transcripts only.

## Validation

```bash
./scripts/test.sh [group]    # thirteen groups; each prints PASS lines, traps on failure
(cd site && bun test)        # site and backend tests
./scripts/build.sh           # compiles every discovered source, signs, verifies
```

Grok live speed retains its cumulative session-counter baseline across turn
boundaries. A first snapshot is still only a baseline; decreases and long gaps
do not create an estimated rate. `MenuBarPresentation.combined` owns automatic
multi-tool presentation for both the status item and settings preview. It sums
available output rates, never provider allowances; `UsageModel.quota(for:)`
uses GrokQuotaMonitor for identity-bound Grok quota and never falls through to Codex quota.

## Persistence and lazy work

The durable stores are the ledger, matching metadata checkpoint, event index,
request archive, sign-in timeline and Codex account database. Report/query caches,
live output-rate baselines and prompt analysis are process memory. Launch restores
saved usage and starts source discovery. Changed files resume from validated
cursors; unchanged files reuse checkpoints. Full discovery does not imply
replaying every transcript.

Report changes rebuild on background queues. Returning to History or Cost does
not invalidate an unchanged result. Insights waits for its destination to settle,
defers while import/report work is busy, and throttles automatic prompt reads.
Leaving Insights stops future scheduling. Prompt text stays in memory. Normal
quit flushes pending usage; a crash can interrupt the deferred save window.
Provider quota freshness is separate from usage/report cache freshness.

## Native state and clocks

UsageModel coordinates process-owned UsageStore (scanner, snapshot, import state)
and ReportState (shared query and reports). Live monitors, meters, preferences
and insight models use property-level Observation; queue implementation state
is excluded. Navigation and window identity retain their existing owners. One
app-owned one-second clock updates labels and rate expiry; observed rate, quota
and preference changes publish the status item directly. Equal attributed titles
are left untouched.
