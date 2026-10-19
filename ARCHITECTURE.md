# ARCHITECTURE.md

> Describes the current source, including unreleased changes. Known limitations
> are listed separately; local qualification is recorded in `docs/VERIFICATION.md`.
> A future scene or navigation migration is not current implementation.

## Runtime shape

Two independent surfaces. A single-module Swift/SwiftUI menu-bar app compiled
with plain `swiftc` over sources discovered recursively (no Xcode project, no package
manifest, no third-party Swift code) runs as an accessory process on Apple
silicon, macOS 14+. A static Cloudflare Pages site under `site/` serves four
HTML pages and local GitHub report drafting. They share product language and
native-rendered synthetic stills and recordings,
not application state or UI code.

## Components

| Component | Responsibility | Owns |
|---|---|---|
| `AppDelegate`, `UsageModel` (`App.swift`) | AppDelegate owns native surfaces, commands and clocks; UsageModel connects process stores and services | host lifetime and orchestration |
| `UsageReadHealth`, `UsageDiagnostic` | Structured source failure and coverage evidence; completed read clock, scope and recovery | Derived snapshot evidence; first-recorded diagnostic dates in ledger metadata |
| `ReportScheduler`, `ReportState` | Utility-queue report work, latest-request publication and retained report choices | Derived reports and query state |
| `UsageScanner` (`Usage.swift`, `UsageAdmission.swift`) with `EventIndex`, `RequestArchive`, `UsageMetadata` | qualify source intervals, admit once, retain and compact | `ledger.json`, `ledger.events.sqlite`, `ledger.requests.sqlite` |
| `GrokUsage` | file-based Grok session usage through the same admission path; live activity from `active_sessions.json` and summary recency | Grok cursors in the ledger |
| `LogStream` | FSEvents watcher on Codex, Claude, Grok and OpenCode homes | nothing |
| `ActivityFeed`, `Activity`, `ClaudeActivityReader`, `Tachometer` | tool-scoped tasks, counter deltas, independent dials | in-memory |
| `ClaudeQuotaMonitor`, `ClaudeUsageRefresh`, `ClaudeStatuslineConnection` | Account-matched Claude Code usage cache with a 30-minute horizon, refreshed by the installed Claude Code every 15 minutes; model-scoped weekly rows (Fable) kept apart in the allowance model; identity-free relay is connection evidence only; Connect/Disconnect edits only `statusLine` in Claude Code's user settings; Token Bar reads no credential and makes no Claude network request itself | In-memory quota samples; empty private `claude-usage-refresh/` working directory; `claude-statusline-relay.sh` stable copy; `claude-statusline.json` is written by the relay, not the app; `settings.json.token-bar-backup-*` beside Claude Code settings |
| `GrokQuotaMonitor` | JSON-RPC to `grok agent --no-leader stdio`, `_x.ai/billing` | In-memory quota samples only |
| `LiveMonitor`, `LiveStateStore`, `ProviderUsage`, `CodexInstallation` | JSON-RPC to `codex app-server --stdio` for quota, plan, account usage | `live-accounts.sqlite`; legacy JSON retained for migration/rollback |
| `QuotaGuardEvaluator`, `QuotaGuardCoordinator`, `QuotaGuardNotifications` | Typed quota assessment, process-owned confirmation/suppression, opt-in native notifications; no transcript parsing or second burn formula | Private `quota-guard.json` suppression/settings and exact notification target; no copied quota history |
| `SignInTimeline`, `PlanHistory` | sign-in switches and plan observations | `sign-ins.json`, ledger plans |
| `Cost*`, `CoverageAudit`, `UsageComparisonStore` | dated API-equivalent estimates, rate history, matched allowance/token observations, coverage, recovery, audit | shipped rate data; process-owned background comparison cache |
| `LiveOverview`, `HistoryView`, `CostView`, `AccountsView`, `DashboardNavigation` | one canonical live module tree plus three Reports destinations and navigation | query state via `UsageModel` |
| `InsightsView` | Hostable Insights destination, unpublished from the capsule | query state via `UsageModel` |
| `MenuBarSettingsView`, `AppearanceControls` | Settings owner: menu-bar fields and appearance. They are not equal capsule destinations and not a third SwiftUI scene | `UserDefaults` preferences |
| `UpdateCheck`, `UpdateCheckControl` | Optional launch-time read of the site's public `release.json` over an ephemeral session with no cookies, cache, or app version; numeric version ordering; offers only a newer, notarized GitHub Release asset and opens it in the browser on click. Previews never construct a live check | `updateCheck.enabled.v1`; outcome is process-owned |
| `site/public/feedback*.js`, `site/worker.js` | local report drafting; advanced-mode static fallback and retired API responses | browser local storage for the draft |

## Sources of truth

| Concern | Canonical owner | Derived views | Proof |
|---|---|---|---|
| Admitted usage | `~/Library/Application Support/CodexTokenBar/ledger.json` | reports, charts, CSV | `Tests/main.swift`, `Tests/Accuracy` |
| Admitted counter coverage | Optional `ledger.usageCoverage`, keyed by logical source and established epoch | New / Covered / Unresolved decisions; coverage diagnostics | `Tests/main.swift`, `Tests/Harnesses`, `Tests/Grok` |
| Event identity | `ledger.events.sqlite` plus in-flight ledger IDs | duplicate counts | `Tests/main.swift` |
| Request detail | `ledger.requests.sqlite` | request CSV, evidence panel | `Tests/Accuracy` |
| Cost reconstruction scratch | `CostRecoveryWorkspace`: one exclusively owned `cost-recovery-workspace` per ledger, reset on a new recovery and removed on normal return | Metadata reconciliation only; never admitted usage | `Tests/Cost`, `docs/COST.md` |
| Quota and accounts | app-server responses, incrementally persisted in `live-accounts.sqlite` | runway, account cards | `Tests/main.swift`, `Tests/MenuBar` |
| Pricing | `CostRateCard` and `CostRateHistory` in source | cost report, CSV | `Tests/Cost`, `docs/COST.md` |
| Preferences | `UserDefaults` keys `appearance.*`, `menuBarConfiguration.v1`, `dashboard.rateUnit.<tool>`, `updateCheck.enabled.v1` | tool units, menu bar title, theme, update check | `Tests/Appearance`, `Tests/MenuBar`, `Tests/UpdateCheck` |
| Version | `VERSION` | Info.plist, package name, `release.json` | `scripts/build.sh` |
| Public download | Notarized GitHub Release asset; `site/public/release.json` binds its URL/hash | landing page button, in-app update notice | `scripts/verify-release.sh`, `site/tests/site.test.mjs`, `Tests/UpdateCheck` |
| Harness and project | `session_meta.originator` and `cwd`, normalized by `Project` | harness and project reports | `Tests/Dimensions` |
| Claude Code usage | `CLAUDE_HOME`, then `CLAUDE_CONFIG_DIR`, then `~/.claude`, with `projects/**/*.jsonl` message snapshots plus verified increments; a missing explicit root stays unavailable | tool and project reports | `Tests/Harnesses` |
| OpenCode usage | `opencode.db` `message` table, read-only | tool, provider and project reports | `Tests/Harnesses` |
| Counter convention | `Tokens.canonical` | every total and cache share | `Tests/Harnesses` |
| Event timestamp | `EventTime.parse` | Codex/Claude activity, Claude turns, provider day bounds | `Tests/main.swift` |

## Critical flows

### Log to ledger

`UsageScanner.assessUsage` in `UsageAdmission.swift` is the single authority for
new usage. Readers supply normalized counters, a provider-scoped logical source,
an established counter epoch, the unchanged event fingerprint, and evidence of
an interval or an independently identified request. The decision is:

| Result | Admission behavior |
|---|---|
| New | Admit the exact positive supported increment. |
| Covered | Add nothing: a durable/in-flight receipt or admitted extent already represents it. |
| Unresolved | Retain the observation and coverage limitation; do not guess an increment. |

`ledger.usageCoverage` distinguishes observed counters, admitted extents and
unresolved overlap. Its optional admitted counter baseline supports Claude
message revisions. A high endpoint never implies admission of its prefix.
Contained extents are covered even under another receipt, path or date scope;
partial overlaps and incomparable vectors are unresolved rather than subtracted
into a guessed remainder. Adjacent admitted extents coalesce. Coverage advances
only with successful integrity/archive/ledger admission, never with a reader
checkpoint alone. Repeated observations, ordinary cumulative growth, supported
revisions, replay, copied paths and delayed records therefore use the same decision.

The surrounding pipeline preserves these responsibilities:

1. **Discovery selects evidence.** FSEvents routes changes to the owning provider,
   including OpenCode database/WAL and Codex catalog changes. Launch, Refresh
   history, dropped events and a 30-minute discovery timer recover missed files
   and changed Claude/OpenCode roots. Catalog events bypass the metadata throttle.
   Source failures clear only after their failed scope or full provider scan
   succeeds; unrelated successful paths do not clear them. Grok child metadata
   remains available when its event precedes the child summary.
2. **Readers establish coherence and comparability.** Codex validates descriptor
   device/inode, metadata, prefix, cursor boundary and final pathname before
   buffered records reach admission. Only complete counter/context records advance
   the cursor; prompt bytes are skipped. Unchanged validation reads at most 768
   digest bytes. These witnesses do not detect arbitrary interior changes that
   preserve both digests and evade metadata checks. Claude retains separate
   transcript and activity cursors, clean-read checkpoints and complete-line
   boundaries. OpenCode pages by `(time_created, id)` and rereads unfinished IDs.
   Its read-only connection is reused only for a matching resolved path/inode;
   replacement, failure and teardown release it. Statements finalize each page
   so WAL commits remain visible and checkpoints are not pinned. Grok rereads the
   changed session. Byte positions, modification dates, turn watermarks and
   live/history date partitions select observations; they do not establish novelty.
3. **Admission validates and persists.** Fatal integrity failures are counted and
   excluded; permitted subordinate-counter reductions preserve core totals.
   Write request detail pending, add the ledger entry/day bucket and coverage,
   save atomically, index captured IDs, then acknowledge archive rows. Index/ack
   failures retry the captured checkpoint without re-encoding. Indexed IDs retire
   from memory; JSON retains the last recovery batch until the next genuine save.
   Normal termination flushes outstanding work; storage-load failure preserves
   saved data. Metadata-only changes write an entry-free UUID-bound sidecar;
   only a matching full-ledger baseline accepts it. Legacy ledgers acquire a UUID
   on full save; older apps may replay older cursors against the durable ID index.
   Archive admitted-row counts update only on successful admissions and invalidate
   after rollback or another connection's committed change.
4. **Reports derive from admitted usage.** Publish saved results before scanning,
   intermediate admissions at most twice per second and a final result before
   cost/catalog work. Background reports coalesce work and publish only the current
   shared History/Cost query generation. A completed current report can publish
   while newer usage queues. The private report index binds to the ledger content
   UUID; append extends it and enrichment/replacement rebuilds it. Pricing-only
   changes reuse History. Metadata, minute/future-entry and calendar boundaries
   invalidate applicable caches. Archive details supply minute timing only after
   exact reconciliation with daily aggregates. SwiftUI body evaluation never
   aggregates history; clock ticks check midnight, future-entry admission, clock
   rollback and calendar/time-zone changes.

#### Residual source and compatibility rules

- **Observation grain:** provider canonicalization remains explicit. Claude uses
  `message.usage`, never an additional sum of `iterations`; monotone revisions add
  counters without another request. OpenCode retains once-per-message admission,
  without inventing revision/finality semantics. Grok turns share session coverage
  when their endpoints can be located; independently identified turns without
  those endpoints retain receipt admission.
- **Lineage and epochs:** first Codex reports/forks admit only stated
  `last_token_usage`. Unproved inherited prefixes and counter resets cannot supply
  a cumulative prefix. Grok's first-fork adapter holds a turn equal to inherited
  session totals and admits a smaller independently stated last turn. These are
  source witnesses, not inferred host or account identity.
- **Legacy gaps, aliases and resumption:** old ledgers lack uniform interval
  history. Migration uses only verified admitted evidence: retained Claude
  baselines/exact archive rows and Codex admitted-boundary witnesses. It never
  promotes arbitrary saved `previous`, offsets or watermarks to admitted coverage.
  Fingerprints and totals remain compatible. Codex replacement reconciliation
  retains exact-anchor recovery, disjoint last-request proof, conservative legacy
  floors and namespace-specific alias evidence. An absent anchor can resume only
  on a continuous append, matching session and disjoint counters with source time
  after the initial verified scan. Delayed records advance observation without
  moving that fixed fence; a discontinuity establishes a new fence. Gaps remain
  disclosed after supported usage resumes. Session changes reset source context;
  replacement replay remains unattributed.
- **Unavailable evidence and attribution:** missing identity/storage evidence
  fails closed. Account assignment independently requires the stable 45-second
  sign-in/poll boundary; proving usage does not prove an account.

Historical repair rationale and superseded design descriptions are kept in
[the archive note](docs/archive/admission-repair-history.md). They do not define
additional admission paths.

### Quota Guard

`UsageModel` owns one coordinator; the main-actor app delegate observes provider
quota changes. The existing one-second meter timer ages in-app evidence only.
Notifications require distinct source timestamps and never come from UI ticks.
The pure evaluator receives explicit identity, authentication, failure, time,
policy and tool-scoped samples. It uses the allowance qualification boundary
below, then calls canonical `Runway.estimate`; that owner already refuses a
forecast reaching or passing reset. A cached Codex account is ineligible until a successful quota
refresh; rereading an unchanged Claude cache does not confirm a forecast.

`QuotaGuardEvaluator.evaluate` supplies only action decisions; `display` supplies
separate `displayDecisions` to live modules, the status item, summaries and detail.
Display uses the provider horizon (Claude 30 minutes, Codex/Grok two minutes),
while preserving identity, authentication, failure and reset validation. Source
age remains visible after two minutes. Expired display evidence removes warning
chrome; an aged but display-valid reading cannot trigger a new notification.
The selected detail presents both display and action freshness for the exact
account/window/reset. Missing resets retain measured display warnings without
inventing a forecast or qualifying a notification.

Display forecasts use canonical `Runway.estimate` at the reading's source time,
with the provider horizon bounding sample gaps. This preserves the measured burn
window while the reading remains valid. Invalid values, decreases, reset changes,
duplicate conflicts and out-of-order samples still discard the affected slope.
Elapsed projection is never promoted to observed exhaustion.

Action freshness is the smaller of the provider horizon and 120 seconds.
Positive burn for notifications needs at least 120 seconds;
gaps over 120 seconds, counter decreases, reset changes, invalid values and
conflicting or out-of-order timestamps discard the affected slope. Observed
exhaustion requires the provider to report 100% used. Forecast elapsed time
never becomes an observed stop. Evidence and warning severity remain separate.

Default low allowance is 10% remaining; forecast lead is 30 minutes before the
reset. Forecast alerts require two distinct fresh observations. Escalations are
5% remaining, a forecast within 10 minutes, and observed exhaustion. Recovery
requires two fresh observations above low + 3 percentage points and beyond
lead + 5 minutes (or no positive burn). A gap resets confirmation. Reset jitter
up to 60 seconds uses a fixed anchor, never a drifting chain; a new period is
accepted only after the previous anchored reset.

Private state is bounded to 256 episodes and snoozes and prunes expired records
after 35 days. Stable opaque request IDs distinguish evaluated, submitted and
observed delivery; one delayed retry is permitted on fresh evidence. Corrupt
or unwritable state pauses notifications and preserves data. Account switches
retain suppression. Snooze is 30 minutes for the selected account/bucket/window
and reset period, including escalation. Old actions never redirect to another
account or cancel a new period's warning. Detail resolves current evidence only
within the same verified period and otherwise labels the historical snapshot.

`UNUserNotificationCenter` is constructed only in a normal app model. Enabling
notifications explicitly requests permission; sound defaults off. macOS delivery
is not guaranteed. View quota and Snooze actions use opaque request identifiers;
private labels and raw account IDs are not placed in notification content.
`--preview-quota-guard` and `--render-quota-guard` use disposable files/preferences,
fixed synthetic time and no notification adapter. `Tests/QuotaGuard` injects a
fake adapter for permission, submission, delivery and action routing.

### Quota read

`AllowanceQualification.assess` is the single eligibility boundary for a current
numeric allowance in Live, Settings, Fable and Quota Guard. Adapters supply account
and successful-process/cache authentication witnesses. A reading requires finite
0–100 utilization, positive window duration, nonempty bucket/window, exact current
account match, no provider failure, a nonfuture source date and age strictly below
the provider horizon (Codex/Grok 120 seconds, Claude 1,800 seconds). A supplied
reset must be finite and future. The Claude cache adapter refuses a supplied
reset string that cannot be parsed, isolating that window in ordinary and model-scoped
rows. A missing Claude reset retains measured remaining, including zero, while
supplying no reset clock, forecast, notification or Fable roll-up. Guard uses the
same qualification with its stricter action horizon.
Raw arithmetic and persisted observations supply no authentication. Refused
readings can explain an unconfirmed module or explicitly historical account card;
they cannot supply a current remaining number. The relay is connection transport
only, and an undated refresh reply is completion evidence only.

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
6. Claude remaining uses the cache whose own account matches
   `oauthAccount` in `~/.claude.json`. Claude Code rewrites
   `cachedUsageUtilization` on demand (session start, its usage screen) and
   after a successful usage fetch. At launch and every 15 minutes,
   `ClaudeUsageRefresh` runs the installed `claude -p` in stream-json mode from
   an empty private directory, with project-only setting sources, no MCP
   servers, skills or session persistence, and telemetry, error reporting and
   auto-update disabled, then sends one experimental `get_usage` control
   request. The reply is undated and can come from saved data when the fetch
   is rate limited, so it is ignored; only the rewritten cache's account and
   `fetchedAtMs` date a reading. Model-scoped weekly rows in the cache's
   `limits[]` (`weekly_scoped`, such as Fable) stay out of the prioritized Claude
   allowance and Quota Guard. The Fable quota model retains the
   lowest remaining among the current 5-hour, weekly and Fable weekly readings,
   named by the binding limit; any missing, stale or other-account input makes it
   unavailable. The time-left model keeps up to four hours of the signed-in
   account's readings in process memory and projects each limit at its
   time-weighted average burn (one-hour half-life, restarting at a reset, at least
   30 minutes of readings); it shows the earliest exhaustion that precedes that
   limit's reset. Claude Code reports resets with sub-second noise that differs
   between fetches, so reset times keep whole seconds. `Assets/claude-statusline-relay.sh`
   ships in `Contents/Resources`; at launch `ClaudeConnectionModel` copies it,
   when its bytes differ, to a stable path in the support directory so the
   settings entry survives moving the app. **Connect Claude Code** (Claude
   panel, Menu bar settings, or `--claude-code connect`) edits only the
   `statusLine` key of the user-level Claude Code `settings.json` (same root as
   usage: `CLAUDE_HOME`, then `CLAUDE_CONFIG_DIR`, then `~/.claude`): relay
   alone when absent, relay prefixed to an existing
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
2. The page restores/saves a local browser draft with title, report and optional
   app/macOS version fields. The convenience version query is removed locally.
3. Explicit Review on GitHub opens a safely encoded URL matching the issue-form
   IDs. It transmits fields to GitHub but never submits an issue automatically.
4. Encoded-length and clipboard failures retain the draft with a selectable copy
   fallback. Retired feedback/config API paths return 410/no-store without
   reading bindings or contacting upstream providers.

## Boundaries

- Prompt text never crosses into the ledger, archive, exports, or previews.
- Provider-reported cost never crosses into the estimate total.
- Credential values are not exported or logged. Grok account binding reads
  identity fields from its local auth file; provider subprocesses use existing
  sign-ins. Website report drafting requires no feedback secrets or provider
  bindings. Drafts are public-intended user text, never copied agent logs.
- Preview and audit modes never cross into the real support directory.
- The site never becomes a control plane. Deployment follows the operator-approved,
  hash-bound local plan in `docs/DEPLOYMENT.md`; source changes grant no deployment authority.

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
- Pricing covers verified OpenAI, Anthropic and xAI API model IDs. Claude cache
  lifetimes and optional thinking subsets travel with the retained counters;
  unsplit output remains combined. Grok Build recorded USD is separate from
  API estimates. Exact model/rate, request-size and date evidence gates leave
  unsupported records unpriced; local and free names do not imply zero cost.
- Codex quota uses the app-server. Claude quota reads only Claude Code's
  account-matched usage cache, which the installed Claude Code rewrites after
  Token Bar's quarter-hour `get_usage` request. That request, its reply and the
  cache's `limits[]` rows are undocumented, experimental Claude Code interfaces;
  a changed shape leaves Claude quota and the Fable
  roll-up unavailable. The status-line relay only proves connection transport;
  its quota observations have no identity.
  Grok remaining uses the installed Grok
  agent’s `_x.ai/billing` reading. OpenCode has no quota integration.
- Grok counters come from `usage.json`. Live activity uses
  `active_sessions.json` and summary `last_active_at`;
  `usage.json` age is not a liveness signal. Project comes from summary `info.cwd`.
- Prompt insights read Codex transcripts only.

## Validation

```bash
./scripts/test.sh [group]    # fifteen groups; each prints PASS lines, traps on failure
(cd site && bun test)        # site and backend tests
./scripts/build.sh           # compiles every discovered source, signs, verifies
```

Grok live speed retains its cumulative session-counter baseline across turn
boundaries. A first snapshot is still only a baseline; decreases and long gaps
do not create an estimated rate. `MenuBarPresentation.face` owns automatic multi-tool presentation for both the
status item and settings preview. It renders one dial/rate per confirmed active
CLI, follows each tool's unit unless explicitly overridden, and keeps names-off
instruments and spoken identities separate. Optional five-second roll selects
only from current active tools using the app-owned clock. `LiveTool.confirmed`
derives membership from dated lifecycle/counter evidence at evaluation time;
retained meter flags, file mtime and discovery cannot admit an instrument.
A disposable presentation projection never changes the process meter. Idle is
one quiet mark; remaining and inactive warnings stay in the popover. Legacy menu
fields remain stored for compatibility, while settings exposes active fields.
`LiveTool.modules` owns the live provider modules: known providers, working
providers and retained allowance evidence. Module identity persists through idle
or unavailable states; missing values never become zero.
`QuickLiveView` and the hostable Now route use the same `LiveOverview` tree.
Reports defaults to History and exposes History, Cost and Allowances; Settings
reuses one dedicated window. `MethodSheet` and `ReadPresentation` share method
geometry and independent availability, coverage and freshness language. `UsageModel.quota(for:)`
uses GrokQuotaMonitor for identity-bound Grok quota and never falls through to Codex quota.

## Persistence and lazy work

The durable stores are the ledger, matching metadata checkpoint, event index,
request archive, sign-in timeline and Codex account database. The derived report
index and per-chat prompt checkpoints are durable too. Report results and live
output-rate baselines are process memory. Launch restores
saved usage and starts source discovery. Changed files resume from validated
cursors; unchanged files reuse checkpoints. Full discovery does not imply
replaying every transcript.

Report changes rebuild on a utility queue before navigation needs them. Returning
to History or Cost does not invalidate an unchanged result. Scanner-owned content
identities avoid comparing all saved entries on the main thread for metadata updates. Insights waits for its destination to settle,
defers while import/report work is busy, and throttles automatic prompt reads.
Leaving Insights stops future scheduling. `prompt-index/` stores private per-chat
byte cursors, file stamps, boundary hashes, hashed message/repeat identities and
derived word/language/action counters. A restart loads those counters and only
tails changed chats. Partial lines do not advance checkpoints; replacement or
truncation invalidates that chat alone. The sampled window remains 30 days and
120 human chats. Cached numeric results appear before background refresh; the
few repeated-prompt labels are read by saved byte position and kept only in memory.
Prompt and answer text are never stored in these checkpoints. Normal
quit flushes pending usage; a crash can interrupt the deferred save window.
Provider quota freshness is separate from usage/report cache freshness.

## Native state and clocks

UsageModel coordinates process-owned UsageStore (scanner, snapshot, import state)
and ReportState (shared query, report choices and results). ReportScheduler owns
queueing, coalescing, cache validity and publication. Obsolete query generations
cannot publish, including an away/back selection; source-only updates may publish
a completed report while the latest data queues. NativeCommands is injected
by AppDelegate; data models do not hold window callbacks. Navigation only changes
the selected destination; it never sets a global reporting mode. Live monitors, meters, preferences
and insight models use property-level Observation; queue implementation state
is excluded. Navigation and window identity retain their existing owners. One
app-owned one-second clock updates labels and rate expiry; observed rate, quota
and preference changes publish the status item directly. Equal attributed titles
are left untouched.


### Usage read health and diagnostic lifecycle

A completed read may have incomplete coverage. `Snapshot.readHealth` derives
failure, coverage and availability from scanner-supplied diagnostics and the
last completed read clock. Legacy `Snapshot.error` remains a compatibility text
projection. History, Cost, Live and hostable Insights use the structured owner.
Unrecognized diagnostics fail closed. Source errors remain scoped until the
owning source scan recovers; an unrelated successful path cannot clear them.

Diagnostics carry provider, source and live/history scope. Cursor reconciliation
and admitted boundaries distinguish unresolved recovery from resumed supported
usage; the old gap remains disclosed. Counts distinguish occurrences from unique
source files. Optional `diagnosticObservations` metadata records when this version
first reported each issue, without inventing the historical gap's onset. The
completed-read clock survives restart through the existing checkpoint. Repeated
poll timestamps alone do not force a save. Coverage diagnostics do not change
counters, cursor boundaries or historical attribution.

### Native host and geometry owners

The host is AppDelegate with NSStatusItem, an intrinsic-height NSPopover,
a retained Reports NSWindow and a retained Settings NSWindow.

| Owner | Geometry and identity |
|---|---|
| ReportWindowGeometry | Reports default 1120×800 and minimum 900×700; shared by AppKit and DashboardRoot |
| DashboardRoot / DestinationHost | Stable navigation and host; only the selected report changes |
| Feature scroll region / PageStyle | One document scroll and shared gutter; no second destination inset |
| QuickLiveView / NSHostingController | 440-point width, vertical `fixedSize`, and `.preferredContentSize` request intrinsic popover height; actual expansion and screen fit require native host verification |
| SettingsPage | One settings scroll and bounded content width |
| ReportState | History measure/breakdown and Cost breakdown survive navigation and window reopening within the process |

NativeCommands supplies Reports, History and Settings actions through the host
environment. Guard reveal retains its exact Allowances route. Feature state owns
transient sheets and disclosures; persisted preferences retain their existing stores.

The dated qualification in docs/VERIFICATION.md binds scanner state transitions,
restart/recovery, report publication, native navigation, keyboard, VoiceOver and
installation to an actual candidate. Rendering and routing receipts alone do not
prove interaction or installation.
