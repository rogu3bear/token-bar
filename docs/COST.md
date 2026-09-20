# Cost estimates

## Shipped behavior

The Cost view estimates API-equivalent cost by period, model and recorded
reasoning level using the shipped, dated rules below. It preserves unknown
fields, token accounting and fork deduplication. Filters, contribution details,
source recovery and CSV export use the same evidence boundaries. This describes
the v0.1 rate card; the original verification dates do not claim that current
market prices were rechecked during a documentation update.

## Meaning of the estimate

Cost defaults to **Historical rates**: a dated USD API-equivalent estimate where a verified schedule exists. **Reference rates** instead applies the 2026-09-09 card to any selected period. Neither is an invoice, subscription charge or reconstruction of amounts paid. Standard and Fast are explicit comparison scenarios. Recorded tier uses only `token_count.info.service_tier`; a turn's requested `service_tier` is retained separately and never substituted for observed usage metadata. Missing or unsupported tiers remain unpriced. Pricing is shipped as sourced, versioned data; there are no network pricing requests or uploads.

Historical base rates (USD per million input / cached input / output tokens):

| Model | Dated interval | Rates | Source |
| --- | --- | --- | --- |
| 5.6 Sol and documented 5.6 alias | July 9–August 20 | 5 / 0.5 / 30 | [Launch](https://openai.com/index/gpt-5-6/) |
| 5.6 Sol and alias | August 21 onward | 4 / 0.4 / 20 | [Changelog](https://developers.openai.com/api/docs/changelog) |
| 5.6 Terra | July 9–29; July 30 onward | 2.5 / 0.25 / 15; 2 / 0.2 / 12 | [Launch](https://openai.com/index/gpt-5-6/), [reduction](https://openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/) |
| 5.6 Luna | July 9–29; July 30 onward | 1 / 0.1 / 6; 0.2 / 0.02 / 1.2 | Same launch and reduction |
| 6 Astra | September 3 onward | 10 / 1 / 50 | [Changelog](https://developers.openai.com/api/docs/changelog) |

The [launch post](https://openai.com/index/gpt-5-6/), rechecked September 13,
2026 for this qualification, describes the August 21 Sol API/credit reduction
as lasting three months. The shipped open interval retains the last verified
rate; it does not establish a permanent tariff. An exact expiration instant or
replacement rate is not established here and is not invented.

Verification date is September 9, 2026. Price-change days are entirely unpriced because the exact UTC cutover is unknown. Historical Fast pricing is supported only from July 31; historical long-context surcharges only from September 9. Complete older GPT-5.5 and GPT-5.3-Codex schedules are not established here; their historical rules start at the September 9 observation. The last verified version continues forward until explicitly updated; it can become stale. CSV schema 2 preserves the original column prefix and appends each applied version, source, verification date, interval, selected service and applied service. Legacy reference columns are blank for historical rows; generic rate-card and price-basis columns identify the historical schedule. Unsupported intervals stay unpriced even when reference pricing is available.

The model/provider match is exact. Current verified rules cover OpenAI GPT-6 Astra, GPT-5.6 Sol/Terra/Luna, the documented GPT-5.6 alias, GPT-5.5, and GPT-5.3-Codex. Other models, providers, and unsupported service scenarios remain unpriced. Extending the rate card does not add another usage connector. There are no network pricing calls or uploads.

Sources checked 2026-09-09:

- [OpenAI pricing](https://developers.openai.com/api/docs/pricing): standard and Fast text rates, cache writes, short/long context schedules for Astra and the 5.6 family.
- [Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), [Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna): request-wide surcharge above 272,000 input tokens. Sol documents the unsuffixed alias.
- [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5): standard rates and session-wide long-context rule. The entire observed task/model history supplies this context, even outside the selected filter.
- [GPT-5.3-Codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex): standard input/cache/output rates.
- [Token accounting](https://help.openai.com/en/articles/4936856-w): reasoning belongs to output usage.

Charges for tools, images outside reported token counters, taxes, regional uplifts, billing-specific discounts, credits and subscriptions are excluded. Date selectors filter usage dates. Historical pricing selects the retained UTC usage day; unresolved legacy daily buckets need exact source recovery before historical pricing; a local-day bucket date alone cannot supply a UTC pricing day. Summaries retain daily granularity while the separate request archive preserves source timestamps.

## Accounting and unknowns

### Claude pricing qualification — September 13, 2026

Claude API-equivalent cost remains unpriced. `ClaudeCodeUsage` retains the
disjoint base input, cache read, total cache creation, and output counters,
but does not retain `cache_creation.ephemeral_5m_input_tokens` and
`cache_creation.ephemeral_1h_input_tokens`. The ledger, request archive, and
compacted records therefore cannot distinguish cache-write lifetimes.
The [official Anthropic pricing table](https://platform.claude.com/docs/en/about-claude/pricing),
checked September 13, 2026, prices those writes separately: for Opus 5,
five-minute writes are $6.25 per million tokens and one-hour writes are $10.
The [prompt-caching response contract](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#1-hour-cache-duration)
confirms that `cache_creation_input_tokens` is the sum of those two fields,
so the aggregate alone cannot select a correct write rate. No default lifetime or model alias is inferred, and no Anthropic
rate card is shipped in 0.1.0. Adding one requires retaining and qualifying
the lifetime split through admission, increments, compaction, and recovery;
legacy records without that evidence must remain unpriced. Claude also lacks
a separately recorded reasoning-output counter; its total output must not be
presented as a measured answer/reasoning split.

### Calculation rules

USD arithmetic uses Decimal without rounding intermediate entries. Displayed contributions round independently and can differ from the rounded total by a cent; CSV retains decimal precision. Input is divided into uncached input, cache reads, and cache writes. Output is divided into reasoning and answer. Their five priced contributions sum once. Invalid subsets are unpriced rather than clamped into a plausible cost. A missing cache-write counter is not treated as zero where the tariff distinguishes it.

The selected reasoning effort comes from each turn context; a missing setting resets it to Unknown. Effort does not multiply a price. Provider comes from session metadata or an explicit turn override. Request size is classified only when the admitted usage delta matches the reported last request, including cache-write counters. Multi-request cumulative deltas retain usage totals but cannot establish a request-size band. Daily compaction preserves provider, effort, context band and cache-write availability separately.

Coverage uses processed tokens in priced records divided by all processed tokens matching the filters. A zero denominator is unavailable (an em dash), not 0%. Displayed coverage is one tenth-of-a-percent face on the Cost headline, evidence grid, and output comparison. Empty selections have no estimate; supported zero-token records can have a measured zero-dollar estimate, including in model and effort rows. Nonzero usage with no supported prices has 0% coverage and an unavailable estimate. Unpriced records remain visible by model/effort and reason. A partial dollar amount is labeled partial. CSV carries full-precision decimal amounts, reference card/service, unknown reasons, observed request context band, effective pricing context band/scope and granularity; blank dollar cells mean unpriced, never zero. Formula-leading source labels are escaped for spreadsheet use.

## Cost relative to output

Cost shows the full estimated request cost in USD per million output tokens,
by selected period, local day, model and reasoning level. The numerator includes
all priced input, cache and output contributions. The denominator uses output
from exactly those priced records, including reasoning. Input-only priced
records still contribute cost. Zero output, an empty selection or wholly
unpriced usage has no ratio. This is neither an output-only tariff nor a measure
of answer quality, task success or productivity.

The companion input-per-output ratio uses that same priced cohort. Output
coverage is priced output divided by all recorded output in the selection;
missing output counters are excluded and their record count is shown separately.
This differs from the existing processed-token pricing coverage. Daily detail
shows its own output denominator and coverage; absent or unpriceable days do not
become zero-cost bars. Ratios are computed from summed costs and counters, not
an average of request ratios. The same History/Cost filters apply throughout.

Historical rates show both dated rate changes and usage changes. Reference rates
hold the shipped card fixed across days; model mix, caching, input volume and
context bands can still change the ratio. Filter to a model/task to narrow that
comparison. Existing CSV retains the full cost and output counters needed to
reconstruct this calculation; blank estimates remain unpriced.

## Separate completeness and provider comparison

The report details panel reports model, reasoning level, cache reads, cache writes, request size, usage-reported tier, requested tier and price availability separately. Each field has a token-weighted denominator (all selected input + output tokens), and recorded-field rows also show record counts. These measure available local evidence, not the unknowable share of logs that never reached this machine. A usage record can contain multiple requests, so record counts must not be called request counts.

**What this usage covers** explains that reports use records available on this
Mac; origin-host identity is not retained. Copied logs do not establish where
work ran, and absent remote/cloud records remain unseen. The directly accessible
**Compare with Codex account totals** sheet provides account context without a
transfer or sync feature. Account-minus-local differences cannot distinguish
other hosts from attribution gaps, unavailable logs or reporting differences.

**Refresh account usage** reads `account/usage/read` through the installed app-server, bracketed by account-bound quota/identity reads on the serialized provider queue. Account changes reject the read. Private per-account snapshots persist alongside existing quota observations, with source and observation time. The panel reports lifetime tokens and available daily buckets, then compares only complete UTC days returned by the provider inside the selected local-time period. Missing days stay unknown. Tool, model, effort, task or different-account filters disable the comparison; provider daily totals have no such breakdown. Local inferred-account tokens and unattributed tokens remain separate. Unknown UTC dates are excluded and counted. A difference is arithmetic, not a finding of missing usage or a billing error: the provider's counter rules and delay are not established by this endpoint. Today may have no complete eligible day.

The app's Usage & billing screen also displays quota percentages and turn-count analytics; these are different denominators. An advertised monthly plan price is not payment evidence. Subscription charges and paid amounts are not estimated from token statistics. No invoice export is required to use this comparison, and no API-equivalent amount is relabeled as an actual charge.

## Published rates and allowance observations

**Published model price history** shows the shipped standard API input,
cache-read and output rates by effective interval, including the change from
the preceding version, source link and verification date. It does not flatten
history into today's reference card. Change-day ambiguity, unsupported older
intervals and the last verification date remain visible. These public prices
are separate from subscription metering.

**Allowance changes and observed tokens** compares one active Codex account and
one retained allowance window across the selected Cost dates. Each interval
uses consecutive observations at most ten minutes apart, with unchanged reset,
window duration and name. Resets, decreases, invalid percentages and larger gaps
are excluded. Input/output/cache-read counters are summed only for exact
single-request observations inside the same interval, inferred to that account;
cache reads remain within input. Known foreign providers/tools are excluded.
Unattributed or unidentified Codex work remains an explicit coverage gap.

The diagnostic local-token-per-percentage-point ratio is unavailable for zero
allowance change, zero local tokens, ambiguous attribution/counters, or unresolved
daily timing that could overlap that interval. Unresolved older days do not
invalidate precise later intervals. Matched request archive details recover
timing only when the existing totals, counts and account/group identity reconcile;
no source-log replay or proportional split is performed. Model mix remains visible,
but even one observed model cannot prove a subscription multiplier: provider
reporting lag and unseen activity can change the relationship. Retained Codex
quota observations cover up to 90 days; Claude/Grok historic metering remains
unavailable. Account/model/tool/task filter restrictions prevent comparing unlike
scopes. This is evidence for investigating divergence, not a billing-error claim.

`UsageComparisonStore` prepares process-owned results on a serial utility queue.
Source, retained quota, account, query, day and archive-count changes invalidate
results. Navigation reuses them; queued updates retain completed results for the
same account/query and reject results for obsolete scopes. Archive recovery first
merges eligible account/window intervals and filters local
records with logarithmic timestamp lookup. Only overlapping coarse groups are
read through the archive group index; whole-group totals/counts/account
reconciliation remains required before timing can be used. Recovered groups are
cached against their ledger entries, independently of unrelated source appends.
Complete groups reuse immutable admitted details; incomplete groups are retried
when archive count changes. The cache retains only groups needed by the current
selection. Read/open failures do not become successful cache entries: the sheet
shows the failure, retains a previous completed comparison when available, and
a later refresh retries even with the same source/query/count, at most once
every 30 seconds for unchanged data. Source/quota/query changes still invalidate
normally. Group reads explicitly select the group index so SQLite cannot choose
a full admitted-date traversal before filtering. No source transcripts are replayed.

## Retained details

`ledger.requests.sqlite` is a private 0600 SQLite archive containing only usage metadata and counters, never prompt text. Records retain source timestamp (including fractions), stable event identity, task and turn, provider/model/effort, field presence, requested and usage-reported service with provenance, and exact request input size when established. Multi-request deltas are explicitly marked in the streaming request CSV; missing fields remain blank. The export follows period/tool/model/effort/account/task filters and atomically replaces the destination only after success.

Archive rows are written pending before ledger admission. After the JSON ledger is durable, its IDs acknowledge those rows; startup finishes acknowledgment after a crash. Admitted IDs are immutable and deduplicated. Failed transactions stay invisible. Historical recovery imports details only for matching groups with uniform account attribution; conflicting existing event identities exclude archive import for that group. Detail enrichment never increases admitted token totals. Existing ledgers receive their archive by recovery; the visible all-history retained count can be lower than the selected summary's record count.

## Compatible recovery

Optional fields preserve old ledger decoding. On the first historical refresh with legacy records, and on explicit **Recover details**, source records are read using the existing scanner and event deduplication into a temporary private ledger. A day/task/model group can be enriched only if all four original token counters and its record count match exactly, attribution is uniform, and already recorded metadata is preserved. Known cache-write counts must match exactly even when other metadata is missing. Unmatched or unavailable groups remain intact. No guessed proportional allocation is performed.

Before saving enrichment, retain a private `ledger-before-cost-<UUID>.json` next to the original ledger. Cursor offsets and the event index are not replaced. Metadata on an old cursor is enriched only when the reconstructed file offset, model, turn identity and token counters match its existing boundary; otherwise it remains unchanged. Recovering details never adds raw prompt text to the ledger. The temporary ledger is removed after use; failures preserve existing history.

## Local verification

`./scripts/test.sh` includes cost calculation, coverage, unknowns, request threshold, fork/restart, and recovery fixtures in `Tests/Cost`. `./scripts/build.sh` compiles the native interface. `build/Token Bar.app/Contents/MacOS/TokenBar --render-cost-preview /absolute/output.png` renders synthetic native data. `--preview-cost` opens the same synthetic data for interaction without starting live monitors; quit that preview process when done. `--preview-cost-navigation` opens the full dashboard with the same isolated synthetic data and a synthetic sign-in boundary for History → Since sign-in → Cost verification. These modes never read the real usage ledger.

`Tests/Accuracy` exercises the private archive's pending/admitted transition, crash retry, immutable IDs, rollback, precise exports, conflicting recovery IDs, historical cutovers, service provenance, separate completeness denominators, and provider date/account/filter boundaries. `--audit-coverage /absolute/private-output.json` reads actual available source logs through the production scanner into disposable storage without reading account credentials or changing the installed ledger. The output contains counts, dates and field coverage only. Audit output is private and is never committed.

### Shared report scope

Cost exposes the same period, Tool, Model, Account and task-search scope as
History, with an additional Cost-only Reasoning level filter. Clear filters
removes those non-period restrictions, preserving period and pricing assumptions.
Rate dates and Service are valuation choices, not data filters. Every Cost
headline, chart, breakdown and report CSV uses the resulting selection; request
exports apply that scope to retained detail (which can have different granularity
or retention coverage). Session-wide context evidence still considers observations
outside the selected scope when required by the tariff. Account-wide provider
comparisons are unavailable under a Tool filter, as under a model/effort filter.
