# Admission and presentation repair history

This note holds rationale and predecessor descriptions, not an additional
specification. Current admission and allowance authorities are in
[Architecture](../../ARCHITECTURE.md); cost, design and upgrade contracts remain
in [Cost](../COST.md), [Design](../DESIGN.md) and [Releasing](../RELEASING.md).
Dated private qualification records remain local and are not copied here.

## Admission model diagnostic correction

The pre-change mixed-scope fixture required 350 tokens after an initial A100/B200
admission followed by a replacement containing historical 100→150 and C300.
The admitted-coverage model requires 300: 100→150 is contained in the already
admitted live 100→200 extent. Counting it again conflicts with the proposed
single authority. The operator delegated this choice; the implementation chooses
count-once coverage and preserves the original date/account assignment. This is
an explicit correction to that diagnostic fixture, not a claim that its earlier
expected number was preserved.

The Dimensions fixture also used fresh cursors for overlapping counters in one
session/turn while asserting two separate requests. It now carries the first
baseline into the second request and supplies cumulative 100→300 with a stated
200-token last request. The project-separation assertion is retained and extended
to exact per-project totals and request counts; project is not a usage identity.

Existing ledgers lack complete interval evidence. No migration retcons their
saved totals, reconstructs missing ranges from watermarks or attributes usage to
a current account. Legacy reconciliation witnesses remain necessary. The fixed
Codex resumption fence came from replacement/delayed-record repairs; its current
proof predicates remain in the admission contract independently of that history.

## Guard and allowance history

A 121-second Claude warning disappearance motivated separate display/action
qualification. Aged warning visibility now follows the two horizons and distinct
source observations. Confirmation, recovery hysteresis and fixed reset anchors
remain observable suppression policy; calling them defensive did not make them
removable. The redundant forecast-before-reset recheck is removed because the
canonical Runway estimator owns that condition.

The Claude request/cache interface was checked against Claude Code 2.1.272;
that dated observation does not establish compatibility with later versions.
Undated replies and identity-free relay numbers never authenticate current quota.
Refresh timing observations and noisy reset samples explain the cache-date and
whole-second reset rules; they are not additional eligibility paths.

## Design research and production

Linear on Refero Styles was inspected September 8, 2026. Carbon, web.dev and W3C
research checked September 11 informed spacing, motion and accessibility. These
are research provenance, while the adopted visual and accessibility rules are
in the design owner.

The icon was generated with the built-in image tool, then converted with sips
and iconutil. Prompt: a finished macOS rounded-square graphite glass icon with
a 270-degree frosted-silver speedometer arc, five scale marks, a polished needle
pointing upper-right, Frost edge highlights and a transparent 8% margin; no
text, numbers, lime, green, yellow, purple or rainbow accents.

### Control cardinality audit — 2026-09-12

| Surface | Old → new | Reason |
|---|---|---|
| DashboardNavigation | Restrained selection capsule → retained | Persistent destination identity and arrow-key navigation already fit |
| ChoiceRow | Custom button flow → native Picker with explicit caller-selected style | Native keyboard/selection semantics; option identity keyed by value |
| History Measure | Four custom choices → segmented Picker | Four stable mutually exclusive measures |
| History Compare | Six custom choices → menu Picker | Larger stable list, explicit Compare label |
| Cost Compare | Two custom choices → segmented Picker | Models versus reasoning levels |
| Shared period | Seven custom choices → menu Picker | Larger list; custom-date fields stay native and conditional |
| Tool/model/account/reasoning filters | Dynamic button grids → menu Pickers | Data-dependent cardinality; missing selected values remain represented |
| Search | Rounded TextField → NSSearchField | Native search and clear behavior, live binding retained |
| Active filter removal | Bordered buttons → plain labeled actions | Commands, not additional choices |
| Rate dates/service | Two/three custom choices → segmented Pickers | Stable valuation alternatives, no query change |
| Appearance mode | Segmented Picker → retained | Three stable modes |
| Accent presets | Four separate buttons → menu Picker with current Custom value | Includes custom selection without falsely selecting a preset |
| Custom accent | ColorPicker → retained | Native color editing and saved custom values |
| Contribution rows | Drill-down buttons → retained | Actually disclose selected record details; focus and chevrons remain |
| Timeline and cost bars | Noninteractive chart/progress marks → retained | Magnitude, not navigation |

## Surface consolidation rationale

| Repeated element and owner | Decision | Reason |
| --- | --- | --- |
| Insights usage timeline vs History timeline (`UsageInsightsView`) | REMOVE from Insights | History already supports period, measure and tool scope; the second chart added no inference. |
| Insights top working directories vs History project comparison (`UsageInsightsView`) | REMOVE from Insights | Project attribution is a distribution question; History retains it with unattributed usage. |
| Insights two weekly output totals (`UsageInsightsSummary`, `UsageInsightsView`) | DERIVE | Show recorded percentage change across complete seven-day periods; supporting totals remain evidence for the calculation. `UsageInsightsSummary` owns the claim: no percentage for missing periods, unknown output counters or a zero baseline; the view only renders it. |
| Insights active days and busiest day (`UsageInsightsView`) | REMOVE | Descriptive summaries of the same History series, without evidence of an unusual condition. |
| Insights peak context in counting details (`UsageInsightsView`) | MOVE to main evidence section | Known request context and its measurable-record count help interpret coverage. A maximum does not establish anomaly or predict exhaustion. |
| Insights cached-input share (`UsageInsightsView`) | MOVE to counting details | Mechanism/context, not a primary insight or a savings claim. |
| Cost time chart and model/reasoning contributions (`CostView`) vs History | KEEP | Dollar valuation excludes unpriced usage visibly; token distribution cannot answer the pricing question. |
| Accounts quota remaining/reset and slope (`QuotaTrendCard`) vs Now | KEEP | Now gives a current operational summary. Accounts binds readings to identity and shows historical quota evidence, with saved readings labeled. |
| History account attribution vs Accounts observations (`HistoryView`, `AccountsView`) | KEEP | Recorded token attribution and current sign-in/allowance are different claims; historical unknowns must not inherit current identity. |
| Shared integrity/freshness disclosures | KEEP | Each independently viewed result needs its evidence limitations. Compact status and native details avoid dominant repeated warning surfaces. |
| Prompt sample (`PromptInsightsSection`) | KEEP | Sampled repeated instructions and time patterns do not appear in token History; sample limits and read failures remain explicit. |

## Capture and qualification limits

Cost capture previously used a bare view; captures now use the shipping shell.
A previous two-surface data-state composition became sixteen separate images.
Older idle-image captions described remaining in the status item; the current
idle face is a quiet mark. A conflicting Cost ordering passage placed comparisons
before time series; the implementation uses composition, time series, attribution.
No public assets were recaptured by this change.

The prior MenuBarExtra/sidebar/NavigationSplitView/Settings-scene proposal was
retired. The adopted AppDelegate/NSStatusItem/NSPopover and retained report/settings
windows remain the host. A preview launcher repair and synthetic routing/render
receipts did not prove actual popover expansion, screen fit, footer reachability,
VoiceOver traversal or installation. Those proof boundaries remain required.
The September 26 correction plan and candidate-specific local acceptance records
remain private dated evidence; the plan is archived locally rather than treated
as current work instructions.

September 13 pricing qualification described older Claude duration/output gaps.
Current retention and pricing supersede the unpriced-only behavior, while unknown
older metadata and unestablished tariffs still refuse unsupported valuations.
Applied rate sources, dates and effective intervals stay in the cost owner as data.

## Installer history

macOS Installer does not decide upgrades by build number. With bundle version
checking on, it compares the short version first, so an installed 2.x
development build counts as newer than any 0.1.x package: Installer skips the
bundle, still reports success and writes a receipt, and the old app stays.
Packages 0.1.0 through 0.1.4 behave this way over a 2.x build (reproduced from
installer logs and a synthetic-bundle install). From 0.1.5 the component
plist leaves version checking off, and `preinstall` compares build numbers
itself: it replaces an older or legacy build, reinstalls the same build in
place, and refuses a newer installed build with a visible error before stopping
anything. `package.sh` stages the packaged bundle's exact `CFBundleVersion`
beside the scripts for that comparison, and a package without it fails closed.
Anyone on a 2.x build who installs 0.1.4 or earlier must first move the old
`/Applications/Token Bar.app` to the Trash.

A successful receipt did not prove that PackageKit replaced the bundle. The
explicit build comparison and version-check bypass protect remaining legacy
installations. Runtime single-writer locking is independent of this workaround
and is not a retirement candidate.
