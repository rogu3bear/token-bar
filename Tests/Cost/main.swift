import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
let now = Date()
func usage(input: Int = 1_000_000, cached: Int = 600_000, writes: Int? = 100_000, output: Int = 100_000, reasoning: Int = 80_000) -> Tokens {
    var values = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning]
    if let writes { values["cache_write_input_tokens"] = writes }
    return Tokens(values)
}
func entry(_ date: Date = now, model: String = "gpt-6-astra", effort: String? = "high", band: String? = "short", tokens: Tokens = usage()) -> Entry {
    var e = Entry(date: date, session: "synthetic", model: model, tokens: tokens, account: nil)
    e.tokenFields = UsageMetadata.fields.filter { $0 != "cache_write_input_tokens" || tokens.cacheWrite != nil }
    e.provider = "openai"; e.effort = effort; e.contextBand = band; e.costMetadataVersion = 1
    return e
}
let priced = CostPricing.estimate(entry()).amounts!
check(priced.total == Decimal(string: "9.85")!, "Input/cache reads/cache writes/output must be disjoint")
check(priced.reasoning == 4 && priced.answer == 1, "Reasoning is a subset of output, not an extra charge")
let long = CostPricing.estimate(entry(band: "long")).amounts!
check(long.total == Decimal(string: "17.2")!, "Long context changes both input/cache and output rates")
check(CostPricing.estimate(entry(band: "long"), service: .fast).amounts!.total == long.total * 2, "Fast comparison uses the applicable long rates")
check(CostPricing.estimate(entry(effort: "low")).amounts!.total == priced.total, "Effort must never become a price multiplier")
check(CostPricing.estimate(entry(effort: nil)).amounts!.total == priced.total, "Unknown effort can still have a known price")
check(CostPricing.estimate(entry(model: "gpt-6-astra-custom")).amounts == nil, "Never guess aliases")
check(CostPricing.estimate(entry(band: nil)).amounts == nil, "Never infer short context from aggregate counts")
check(CostPricing.estimate(entry(tokens: usage(writes: nil))).amounts == nil, "Unknown cache writes are not zero")
check(CostPricing.estimate(entry(tokens: usage(writes: -1))).amounts == nil, "Reject negative writes")
check(CostPricing.estimate(entry(tokens: usage(cached: 950_000))).amounts == nil, "Reject overlapping cache partitions")
check(CostPricing.estimate(entry(tokens: usage(reasoning: 100_001))).amounts == nil, "Reject reasoning above output")
var unknown = entry(); unknown.provider = nil
check(CostPricing.estimate(unknown).amounts == nil, "A model name does not establish a provider")
print("PASS: decimal pricing, five disjoint contributions, long context, Fast scenario, effort independence and unavailable evidence")

let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
let rows = [entry(yesterday, effort: "low"), entry(effort: "high"), entry(effort: nil), unknown]
let report = CostReport.build(source: rows, query: UsageQuery(period: 1), catalog: [:], now: now)
check(report.pricedTokens == 3_300_000 && report.unpricedTokens == 1_100_000 && report.coverage == 0.75, "Coverage includes unpriced usage")
check(report.efforts.contains { $0.id == "Unknown" }, "Missing effort has a visible bin")
check(report.output.output == 300_000 && report.output.unpricedOutput == 100_000 && report.output.outputCoverage == 0.75,
      "Output coverage keeps priced and unpriced output in separate cohorts")
check(report.output.usdPerMillionOutput == Decimal(string: "98.5")! && report.output.inputPerOutput == 10,
      "Full input/cache/output cost is normalized against the same priced output, never unpriced output")
check(report.models.reduce(0) { $0 + $1.output.output } == report.output.output
      && report.days.reduce(Decimal.zero) { $0 + $1.output.cost } == report.amounts.total,
      "Model and daily output comparisons reconcile with the selected priced cohort")
let inputOnly = entry(tokens: usage(input: 100, cached: 0, writes: 0, output: 0, reasoning: 0))
let inputOnlyReport = CostReport.build(source: [inputOnly], query: UsageQuery(period: 1), catalog: [:], now: now)
check(inputOnlyReport.output.cost > 0 && inputOnlyReport.output.usdPerMillionOutput == nil,
      "Input-only work has cost but no cost-per-output denominator")
let mixedOutput = CostReport.build(source: [entry(), inputOnly], query: UsageQuery(period: 1), catalog: [:], now: now)
check(mixedOutput.output.usdPerMillionOutput == Decimal(string: "98.51")!,
      "Input-only requests remain in the full cost numerator when priced output exists")
var absentOutput = entry(); absentOutput.tokenFields?.removeAll { $0 == "output_tokens" }
let missingOutputReport = CostReport.build(source: [entry(), absentOutput], query: UsageQuery(period: 1), catalog: [:], now: now)
check(missingOutputReport.output.missingOutputRecords == 1 && missingOutputReport.output.unpricedOutput == 0
      && missingOutputReport.output.usdPerMillionOutput == Decimal(string: "98.5")!,
      "Missing output fields never become a measured zero or dilute the priced ratio")
var otherAccount = entry(); otherAccount.account = Account(id: "other", label: "Synthetic", plan: "pro")
let outputScoped = CostReport.build(source: [entry(), otherAccount, unknown], query: UsageQuery(period: 1, account: "other"), catalog: [:], now: now)
check(outputScoped.output.output == 100_000 && outputScoped.output.unpricedOutput == 0,
      "Output comparisons follow the same account selection as cost")
check(CostReport.build(source: [entry()], query: UsageQuery(period: 1, model: "absent"), catalog: [:], now: now).output.usdPerMillionOutput == nil,
      "An empty filtered selection has no output comparison")
print("PASS: matched cost/output cohorts, daily and model reconciliation, input-only cost, absent output and account/model filters")
let high = CostReport.build(source: rows, query: UsageQuery(period: 0), catalog: [:], effort: "high", now: now)
check(high.lines.count == 2 && high.unpricedTokens > 0, "Combined date and effort filtering preserves unknown prices")
check(CostReport.build(source: rows, query: UsageQuery(period: 4, start: now, end: yesterday), catalog: [:]).lines.isEmpty, "Reversed date range has no usage")
var oldSession = entry(yesterday, model: "gpt-5.5", effort: "low", band: "long", tokens: usage(writes: 0))
var currentSession = entry(model: "gpt-5.5", effort: "high", tokens: usage(writes: 0))
let session = CostReport.build(source: [oldSession, currentSession], query: UsageQuery(period: 0), catalog: [:], effort: "high", now: now)
check(session.amounts.total == CostPricing.estimate(currentSession, sessionBand: "long").amounts!.total, "Session context must consider excluded dates and efforts")
var uncertainSession = oldSession; uncertainSession.provider = nil; uncertainSession.contextBand = nil
let uncertainReport = CostReport.build(source: [uncertainSession, currentSession], query: UsageQuery(period: 0), catalog: [:], effort: "high", now: now)
check(uncertainReport.pricedTokens == 0, "Unattributed older session context must not be assumed short")
var malicious = entry(); malicious.session = "=1+1,\"line\"\nnext"
let csv = CostReport.build(source: [malicious, unknown], query: UsageQuery(period: 1), catalog: [:]).csv()
check(csv.contains("\"'=1+1,"), "CSV neutralizes formula-leading labels")
check(csv.contains("\"Provider not recorded\"") && csv.contains("\"openai-text-2026-09-09\""), "CSV carries missing-price reasons and dated reference basis")
print("PASS: time/model/effort reports, coverage, unknown bins, session-wide tariff outside filters and safe CSV")

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let scanner = UsageScanner(home: root, stateURL: root.appendingPathComponent("state.json"))
var cursor = Cursor()
func data(_ type: String, _ payload: [String: Any], date: Date = now) -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": ISO8601DateFormatter().string(from: date), "payload": payload], options: [.sortedKeys])
}
func counts(_ input: Int, output: Int, write: Int = 0) -> [String: Any] {
    ["input_tokens": input, "cached_input_tokens": 0, "cache_write_input_tokens": write, "output_tokens": output, "reasoning_output_tokens": output / 2]
}
func event(_ total: [String: Any], _ last: [String: Any], date: Date = now) -> Data {
    data("event_msg", ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last]], date: date)
}
scanner.consume(data("session_meta", ["model_provider": "openai"]), session: "s", cursor: &cursor, account: nil, poll: now)
scanner.consume(data("turn_context", ["model": "gpt-6-astra", "effort": "high", "turn_id": "one"]), session: "s", cursor: &cursor, account: nil, poll: now)
scanner.consume(event(counts(CostPricing.threshold, output: 10), counts(CostPricing.threshold, output: 10)), session: "s", cursor: &cursor, account: nil, poll: now)
check(scanner.ledger.entries[0].contextBand == "short" && scanner.ledger.entries[0].effort == "high", "Threshold is strictly greater than CostPricing.threshold; capture effort")
scanner.consume(data("turn_context", ["model": "gpt-6-astra", "turn_id": "two"]), session: "s", cursor: &cursor, account: nil, poll: now)
scanner.consume(event(counts(CostPricing.threshold * 2 + 1, output: 20), counts(CostPricing.threshold + 1, output: 10)), session: "s", cursor: &cursor, account: nil, poll: now)
check(scanner.ledger.entries[1].contextBand == "long" && scanner.ledger.entries[1].effort == nil, "Missing new-turn effort must not inherit high")
scanner.consume(event(counts(600_000, output: 30), counts(100, output: 2)), session: "s", cursor: &cursor, account: nil, poll: now)
check(scanner.ledger.entries.last!.contextBand == nil, "Multiple-request deltas do not have an established request band")
var fork = Cursor(); fork.turnID = "two"; fork.model = "gpt-6-astra"
let previousCount = scanner.ledger.entries.count
scanner.consume(event(counts(600_000, output: 30), counts(100, output: 2)), session: "fork", cursor: &fork, account: nil, poll: now)
check(scanner.ledger.entries.count == previousCount, "Cost metadata does not change logical event deduplication")
let legacyJSON = "{\"date\":0,\"session\":\"s\",\"model\":\"m\",\"tokens\":{\"input\":10,\"cached\":0,\"output\":2,\"reasoning\":0}}"
let legacy = try JSONDecoder().decode(Entry.self, from: Data(legacyJSON.utf8))
check(legacy.provider == nil && legacy.effort == nil && legacy.tokens.cacheWrite == nil, "Legacy ledgers decode without inventing metadata")
print("PASS: recorded provider/effort, missing-effort reset, exact threshold, multi-call uncertainty, fork dedup and legacy decoding")

let home = root.appendingPathComponent("recovery")
let sessions = home.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
let id = "11111111-1111-1111-1111-111111111111"
let a = counts(100, output: 10, write: 10), b = counts(300, output: 30, write: 30), last = counts(200, output: 20, write: 20)
let records = [data("session_meta", ["model_provider": "openai"], date: yesterday),
               data("turn_context", ["model": "gpt-6-astra", "effort": "low", "turn_id": "r1"], date: yesterday), event(a, a, date: yesterday),
               data("turn_context", ["model": "gpt-6-astra", "effort": "high", "turn_id": "r2"], date: yesterday), event(b, last, date: yesterday)]
try records.reduce(Data()) { $0 + $1 + Data([10]) }.write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
let ledgerURL = home.appendingPathComponent("state.json")
var saved: Ledger = { let seed = UsageScanner(home: home, stateURL: ledgerURL); _ = seed.scan(historical: true); _ = seed.scan(); return seed.ledger }()
func oldCursor(_ cursor: Cursor) -> Cursor { var c = cursor; c.provider = nil; c.effort = nil; c.previous?.cacheWrite = nil; return c }
saved.cursors = saved.cursors.mapValues(oldCursor)
saved.historyCursors = saved.historyCursors?.mapValues(oldCursor)
var retained = Entry(date: Calendar.current.startOfDay(for: yesterday), session: id, model: "gpt-6-astra", tokens: Tokens(["input_tokens": 300, "output_tokens": 30, "reasoning_output_tokens": 15]), account: nil)
retained.bucket = "day"; retained.sampleCount = 2
var unavailable = retained; unavailable.session = "missing-source"
saved.entries = [retained, unavailable]
try JSONEncoder().encode(saved).write(to: ledgerURL)
let recovery = UsageScanner(home: home, stateURL: ledgerURL)
let originalOffsets = recovery.ledger.cursors.mapValues(\.offset)
try recovery.saveIfNeeded(force: true)
let beforePlanCheckpoint = try Data(contentsOf: ledgerURL)
recovery.recordPlan("Synthetic checkpoint plan", date: Date(), account: nil, evidence: "test", model: nil)
try recovery.saveIfNeeded(force: true)
let afterPlanCheckpoint = try Data(contentsOf: ledgerURL)
check(beforePlanCheckpoint == afterPlanCheckpoint && FileManager.default.fileExists(atPath: UsageScanner.metadataURL(for: ledgerURL).path),
      "Rollback fixture stores its plan only in a metadata sidecar")
let before = recovery.ledger.entries.reduce(0) { $0 + $1.tokens.total }
_ = try recovery.recoverCostDetails()
check(recovery.ledger.entries.reduce(0) { $0 + $1.tokens.total } == before, "Recovery never drops or adds historical totals")
check(recovery.ledger.cursors.mapValues(\.offset) == originalOffsets, "Recovery cannot advance live cursors")
check(recovery.ledger.cursors.values.allSatisfy { $0.provider == "openai" && $0.effort == "high" && $0.previous?.cacheWrite == 30 }, "Recover metadata at the exact persisted EOF boundary")
var partial = entry(); partial.provider = nil
let enrichedPartial = CostRecovery.reconcile(original: [partial], reconstructed: [entry()])
check(enrichedPartial.groups == 1 && enrichedPartial.entries[0].provider == "openai", "Partially upgraded unknown metadata can still be enriched")
check(Set(recovery.ledger.entries.filter { $0.session == id }.compactMap(\.effort)) == ["low", "high"], "Recover both effort bins")
check(recovery.ledger.entries.first { $0.session == "missing-source" }?.costMetadataVersion == nil, "Missing raw history remains unchanged")
let again = UsageScanner(home: home, stateURL: ledgerURL)
check(again.ledger.entries.count == 3, "Effort bins survive restart and compaction")
check(again.ledger.entries.filter { $0.session == id }.reduce(0) { $0 + ($1.tokens.cacheWrite ?? 0) } == 30, "Cache writes survive historical reduction")
_ = try again.recoverCostDetails()
check(again.ledger.entries.reduce(0) { $0 + $1.tokens.total } == before, "Repeated recovery is idempotent")
var mismatch = retained; mismatch.tokens.input += 1
check(CostRecovery.reconcile(original: [mismatch], reconstructed: recovery.ledger.entries).groups == 0, "Changed source totals cannot replace history")
let preservedFiles = try FileManager.default.contentsOfDirectory(atPath: home.path)
check(preservedFiles.contains { $0.hasPrefix("ledger-before-cost-") }, "Preserve private rollback ledger")
let rollbackLedgers = try preservedFiles.filter { $0.hasPrefix("ledger-before-cost-") }.map {
    try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: home.appendingPathComponent($0)))
}
check(rollbackLedgers.allSatisfy { $0.plans?.values.contains { $0.plan == "Synthetic checkpoint plan" } == true },
      "Self-contained rollback includes metadata stored outside the full history baseline")
check(again.scan(historical: true).entries.reduce(0) { $0 + $1.tokens.total } == before, "Recovery preserves cursors and committed event identities")
print("PASS: end-to-end raw-log backfill, exact totals, missing-source retention, restart, cache-write bins, idempotence and rollback")

var freshCursor = Cursor(); freshCursor.offset = 100; freshCursor.model = "gpt-6-astra"; freshCursor.turnID = "t"; freshCursor.previous = usage(); freshCursor.provider = "openai"; freshCursor.effort = "high"
var savedCursor = freshCursor; savedCursor.provider = nil; savedCursor.effort = nil; savedCursor.previous?.cacheWrite = nil
check(CostRecovery.enrichCursor(savedCursor, from: freshCursor).provider == "openai", "Exact boundary enriches unknown cursor metadata")
savedCursor.offset = 99
check(CostRecovery.enrichCursor(savedCursor, from: freshCursor).provider == nil, "Different offsets cannot borrow future metadata")
savedCursor.offset = 100; savedCursor.provider = "different-provider"
check(CostRecovery.enrichCursor(savedCursor, from: freshCursor).effort == nil, "Conflicting known provider must not borrow metadata")
print("PASS: cursor metadata boundary and known-provider conflict preservation")

// Review regressions: preserve a known cache-write count even with incomplete metadata.
var tenWrites = entry(tokens: usage(writes: 10)); tenWrites.effort = nil
var twentyWrites = tenWrites; twentyWrites.effort = "high"; twentyWrites.tokens.cacheWrite = 20
let conflictingWrites = CostRecovery.reconcile(original: [tenWrites], reconstructed: [twentyWrites])
check(conflictingWrites.groups == 0 && conflictingWrites.entries[0].tokens.cacheWrite == 10, "Recovery cannot change known writes from 10 to 20 when effort was unknown")
var sameWrites = tenWrites; sameWrites.effort = "high"
check(CostRecovery.reconcile(original: [tenWrites], reconstructed: [sameWrites]).groups == 1, "Exact known writes still permit recovery of unknown effort")
var missingWrites = sameWrites; missingWrites.tokens.cacheWrite = nil
check(CostRecovery.reconcile(original: [tenWrites], reconstructed: [missingWrites]).groups == 0, "Known writes cannot become unknown")
var unversionedWrites = tenWrites; unversionedWrites.costMetadataVersion = nil
check(CostRecovery.reconcile(original: [unversionedWrites], reconstructed: [twentyWrites]).groups == 0, "Known cache writes remain protected without a metadata-version marker")
let sessionCSV = session.csv()
check(session.lines[0].entry.contextBand == "short" && session.lines[0].estimate.effectiveContextBand == "long" && session.lines[0].estimate.contextScope == "session", "Observed request band and applied session band have distinct owners")
check(sessionCSV.contains("context_band,effective_context_band,context_scope") && sessionCSV.contains("\"short\",\"long\",\"session\""), "CSV explains session-wide long pricing outside the selected period")
let sinceSignIn = CostReport.build(source: rows, query: UsageQuery(period: 5, start: now.addingTimeInterval(-60)), catalog: [:], now: now)
check(sinceSignIn.lines.count == 3, "Since sign-in filters the Cost report at the same shared boundary")
print("PASS: review regressions for exact known writes, applied session tariff CSV, and Since sign-in filtering")

var grokTicks = entry(); grokTicks.provider = "xai"; grokTicks.model = "grok-4.6-build"; grokTicks.costUsdTicks = 12_345
check(CostPricing.estimate(grokTicks).amounts == nil, "xAI provider/model is not an OpenAI rate-card match")
check(grokTicks.costUsdTicks == 12_345, "Grok costUsdTicks stays off the OpenAI historical/reference estimate")
check(CostPricing.estimate(entry()).amounts != nil, "OpenAI fixtures still price after Grok stays unpriced")
print("PASS: Grok ticks remain distinct from OpenAI API-equivalent cost")
let costMinuteDay = Calendar.current.startOfDay(for: now)
let costMinuteNow = costMinuteDay.addingTimeInterval(3600)
let minuteCosts = CostReport.build(source: [entry(costMinuteDay.addingTimeInterval(60)), entry(costMinuteDay.addingTimeInterval(180))], query: UsageQuery(), catalog: [:], now: costMinuteNow)
check(minuteCosts.minuteResolution && minuteCosts.timeline.count == 2, "A single-day cost chart needs separate minute positions")
check(minuteCosts.timeline.last?.amounts.total == minuteCosts.amounts.total, "Minute cost cumulative total must reconcile")
var dayCost = entry(costMinuteDay); dayCost.bucket = "day"
let dailyCost = CostReport.build(source: [dayCost], query: UsageQuery(), catalog: [:], now: costMinuteNow)
check(dailyCost.timeline.isEmpty && dailyCost.dailyOnlyAmount.total == dailyCost.amounts.total, "A daily cost bucket cannot invent a midnight measurement")
print("PASS: minute cost timeline reconciles and daily-only estimates remain outside the minute line")

let emptySelection = CostReport.build(source: rows, query: UsageQuery(period: 1, model: "no-matching-model"), catalog: [:], now: now)
check(emptySelection.calculatedAt == now && emptySelection.coverage == nil && !emptySelection.hasPricedRecords, "Empty selection has no coverage denominator or estimate")
check(emptySelection.availabilityMessage.contains("No usage matches"), "Empty selection is explicit")
let zeroSelection = CostReport.build(source: [entry(tokens: usage(input: 0, cached: 0, writes: 0, output: 0, reasoning: 0))], query: UsageQuery(period: 1), catalog: [:], now: now)
check(zeroSelection.hasPricedRecords && zeroSelection.amounts.total == 0 && zeroSelection.coverage == nil, "A supported zero-token record is a measured zero cost, with undefined token coverage")
let unpricedSelection = CostReport.build(source: [unknown], query: UsageQuery(period: 1), catalog: [:], now: now)
check(unpricedSelection.coverage == 0 && !unpricedSelection.hasPricedRecords, "Unpriced nonzero usage has measured zero coverage")
check(report.availabilityMessage.contains("Partial estimate") && report.coverage == 0.75, "Mixed pricing is partial rather than unavailable")
check(CostReport().calculatedAt == nil && CostReport().coverage == nil, "Uncalculated report is unavailable")
print("PASS: uncalculated, empty selection, measured zero, unpriced and partial cost availability")
check(emptySelection.statusMessage(sourceAvailable: false).contains("unavailable"), "A failed source cannot masquerade as an empty selection")

check(zeroSelection.models.first?.hasPricedRecords == true && zeroSelection.efforts.first?.hasPricedRecords == true, "Zero-cost detail rows remain priced rather than labeled Unpriced")

let mixedZero = CostReport.build(source: [entry(tokens: usage(input: 0, cached: 0, writes: 0, output: 0, reasoning: 0)), unknown], query: UsageQuery(period: 1), catalog: [:], now: now)
check(mixedZero.hasPricedRecords && mixedZero.coverage == 0 && mixedZero.availabilityMessage.contains("Partial"), "Known zero plus unpriced usage is a partial estimate")

// The indexed/cached path must remain equivalent to the reference aggregation.
let cacheNow = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
var cacheRows = [entry(cacheNow.addingTimeInterval(-86400), band: "long"),
                 entry(cacheNow.addingTimeInterval(-10), band: "short"),
                 entry(cacheNow.addingTimeInterval(2), band: "short")]
for i in cacheRows.indices { cacheRows[i].model = "gpt-5.5"; cacheRows[i].tokens.cacheWrite = 0 }
cacheRows[2].session = "future"
let engine = ReportEngine()
var cacheInputs = ReportRevisionInputs(entries: 1, catalog: 1, query: UsageQuery(), effort: "All levels", service: .standard, basis: .reference)
let cacheResult = engine.build(source: cacheRows, inputs: cacheInputs, catalog: [:], now: cacheNow)
let directUsage = UsageReport.build(entries: cacheRows, query: cacheInputs.query, catalog: [:], now: cacheNow)
let directCost = CostReport.build(source: cacheRows, query: cacheInputs.query, catalog: [:], now: cacheNow)
check(cacheResult.0.csv() == directUsage.csv() && cacheResult.1.csv() == directCost.csv(), "Indexed reports preserve exports, selection and session-wide tariffs")
check(cacheResult.1.lines.first?.estimate.effectiveContextBand == "long", "Out-of-period long-context observation still controls pricing")
_ = engine.build(source: cacheRows, inputs: cacheInputs, catalog: [:], now: cacheNow.addingTimeInterval(1))
check(engine.indexBuilds == 1 && engine.usageBuilds == 1 && engine.costBuilds == 1, "Unchanged inputs perform no aggregation")
cacheInputs.service = .fast
_ = engine.build(source: cacheRows, inputs: cacheInputs, catalog: [:], now: cacheNow.addingTimeInterval(1))
check(engine.indexBuilds == 1 && engine.usageBuilds == 1 && engine.costBuilds == 2, "Pricing-only changes reuse the date index and History report")
let futureResult = engine.build(source: cacheRows, inputs: cacheInputs, catalog: [:], now: cacheNow.addingTimeInterval(2))
check(futureResult.0.entries.count == 2 && engine.usageBuilds == 2, "Future entry invalidates at its exact clock boundary")
cacheRows[1].contextBand = nil
cacheInputs.entries += 1
let enriched = engine.build(source: cacheRows, inputs: cacheInputs, catalog: [:], now: cacheNow.addingTimeInterval(2))
check(engine.indexBuilds == 2 && enriched.1.csv() == CostReport.build(source: cacheRows, query: cacheInputs.query, catalog: [:], service: .fast, now: cacheNow.addingTimeInterval(2)).csv(), "Metadata revision rebuilds indexed context without changing cost semantics")
for period in [0, 1, 2, 3, 4, 5, 6] {
    let query = UsageQuery(period: period, start: cacheNow.addingTimeInterval(-86400), end: cacheNow)
    let selected = ReportIndex(cacheRows).select(query, catalog: [:], now: cacheNow)
    check(selected == cacheRows.filter { query.includes($0, catalog: [:], now: cacheNow) }, "Indexed date bounds match period \(period)")
}
print("PASS: indexed/cache equivalence, out-of-period tariffs, pricing-only reuse, metadata invalidation and future-clock boundaries")

do {
    let lazy = ReportEngine()
    let inputs = ReportRevisionInputs(entries: 1, catalog: 1, query: UsageQuery(), effort: "All levels", service: .standard, basis: .reference)
    _ = lazy.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow.addingTimeInterval(10))
    _ = lazy.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow.addingTimeInterval(3600))
    check(lazy.indexBuilds == 1 && lazy.usageBuilds == 1 && lazy.costBuilds == 1, "Returning to unchanged reports after an hour reuses all aggregation")
    let rolledBack = lazy.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow.addingTimeInterval(1))
    check(lazy.usageBuilds == 2 && !rolledBack.0.entries.contains(where: { $0.session == "future" }), "Clock rollback cannot retain a record that is future again")
    let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: cacheNow))!
    let tomorrow = lazy.build(source: cacheRows, inputs: inputs, catalog: [:], now: midnight)
    check(tomorrow.0.entries.isEmpty && lazy.indexBuilds == 1 && lazy.usageBuilds == 3, "Today expires at local midnight without rebuilding the unchanged source index")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
        let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        let validity = ReportValidity(now: start, futureRecord: nil, calendar: calendar)
        check(validity.until.timeIntervalSince(start) == Double(hours * 3600), "Local-day expiry honors daylight-saving transitions")
        check(validity.contains(start.addingTimeInterval(3600), calendar: calendar) && !validity.contains(validity.until, calendar: calendar), "Cached values span the actual local day only")
        var otherZone = calendar; otherZone.timeZone = TimeZone(secondsFromGMT: 0)!
        var otherWeek = calendar; otherWeek.firstWeekday = calendar.firstWeekday == 1 ? 2 : 1
        check(!validity.contains(start, calendar: otherZone) && !validity.contains(start, calendar: otherWeek), "Timezone and calendar changes invalidate cached selections")
        check(!validity.contains(start.addingTimeInterval(-1), calendar: calendar), "Clock rollback invalidates even within the same local day")
    }
}
print("PASS: lazy page reuse, midnight, future-record, clock rollback, calendar and timezone boundaries")

// Relaunch and new usage must not re-index settled entries.
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("report-index.json")
    let contentID = UUID()
    var inputs = cacheInputs
    let original = ReportEngine(storageURL: url)
    let first = original.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow, sourceID: contentID)
    let restarted = ReportEngine(storageURL: url)
    let restored = restarted.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow, sourceID: contentID)
    check(restarted.indexRestores == 1 && restarted.indexBuilds == 0, "Restart restores the durable index without rebuilding it")
    check(restored.0.csv() == first.0.csv() && restored.1.csv() == first.1.csv(), "Durable index preserves exact reports")
    var appended = cacheRows
    var late = cacheRows[0]; late.date = cacheNow.addingTimeInterval(-100); late.session = "new-task"
    appended.append(late); inputs.entries += 1
    let updated = restarted.build(source: appended, inputs: inputs, catalog: [:], now: cacheNow, sourceID: UUID())
    check(restarted.indexBuilds == 0 && restarted.indexAppends == 1, "Only appended observations extend a restored index")
    check(updated.0.csv() == UsageReport.build(entries: appended, query: inputs.query, catalog: [:], now: cacheNow).csv(), "Late dated appends keep chronological selection correct")
    let mismatched = ReportEngine(storageURL: url)
    _ = mismatched.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow, sourceID: contentID)
    check(mismatched.indexRestores == 0 && mismatched.indexBuilds == 1, "A crash's newer cache cannot substitute for the older durable ledger")
    try Data("broken".utf8).write(to: url)
    let corrupt = ReportEngine(storageURL: url)
    _ = corrupt.build(source: cacheRows, inputs: inputs, catalog: [:], now: cacheNow, sourceID: contentID)
    check(corrupt.indexBuilds == 1, "A damaged derived index rebuilds from saved usage")
}
print("PASS: durable report index restart, incremental append, late events, mismatched baseline and corrupt-cache recovery")

// Same observed account/window interval: no cross-window sums or model tariff inference.
let meterNow = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
let meterAccount = Account(id: "meter-account", label: "Synthetic", plan: "pro")
func allowance(_ seconds: Double, _ used: Double, reset: Date? = nil) -> QuotaReading {
    QuotaReading(accountID: meterAccount.id, bucket: "standard", name: "Codex", window: "primary", minutes: 300,
                 used: used, reset: reset ?? meterNow.addingTimeInterval(3600), date: meterNow.addingTimeInterval(seconds))
}
func metered(_ seconds: Double, model: String = "gpt-6-astra") -> Entry {
    var value = entry(meterNow.addingTimeInterval(seconds), model: model, tokens: usage(input: 1000, cached: 200, writes: 0, output: 100, reasoning: 20))
    value.account = meterAccount; value.harness = "codex-cli"; value.requestInputTokens = 1000
    return value
}
let meterHistory = [allowance(-600, 10), allowance(-300, 11), allowance(0, 13)]
let meterSource = [metered(-450), metered(-150, model: "gpt-5.6-sol")]
let windowID = meterHistory[0].id
let meterReport = MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource, query: UsageQuery(period: 1), effort: "All levels", now: meterNow)
check(meterReport.intervals.map(\.usedPoints) == [1, 2] && meterReport.intervals.map(\.tokensPerPoint) == [1100, 550],
      "Matched intervals expose observed allowance divergence for identical local token mix")
check(meterReport.intervals[0].cached == 200 && meterReport.intervals[0].input == 1000,
      "Cache reads remain a subset of input")
let mixedMeter = MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource + [metered(-350, model: "gpt-5.6-sol")], query: UsageQuery(period: 1), effort: "All levels", now: meterNow)
check(mixedMeter.intervals[0].models.count == 2, "Mixed-model usage remains explicitly mixed at the account level")
let resetHistory = [allowance(-1800, 5), allowance(-600, 10), allowance(-300, 1, reset: meterNow.addingTimeInterval(7200)), allowance(0, 0)]
check(MeteringComparison.build(history: resetHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource, query: UsageQuery(period: 1), effort: "All levels", now: meterNow).intervals.isEmpty,
    "Long gaps, resets and decreases cannot become comparable depletion intervals")
var unbound = metered(-400); unbound.account = nil
let incompleteMeter = MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource + [unbound], query: UsageQuery(period: 1), effort: "All levels", now: meterNow)
check(incompleteMeter.intervals[0].tokensPerPoint == nil && incompleteMeter.intervals[0].unattributed == 1100,
      "Unattributed usage prevents a seemingly complete local ratio")
var coarseMeter = metered(-400); coarseMeter.bucket = "day"
check(MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource + [coarseMeter], query: UsageQuery(period: 1), effort: "All levels", now: meterNow).intervals.allSatisfy { $0.tokensPerPoint == nil },
    "Unreconciled daily records prevent precise metering ratios")
check(MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource, query: UsageQuery(period: 1, model: "gpt-6-astra"), effort: "All levels", now: meterNow).intervals.isEmpty,
    "A model-filtered denominator cannot explain whole-account allowance")
let comparisonStore = UsageComparisonStore()
var comparisonState = LiveState()
comparisonState.accounts[meterAccount.id] = LiveAccount(id: meterAccount.id, email: "sample@example.com", plan: "pro", observed: meterNow, quotas: [meterHistory.last!])
comparisonState.quotaHistory = meterHistory
let comparisonQuery = UsageQuery(period: 1)
func refreshComparison(_ revision: UInt64 = 1, quota: UInt64 = 1, query: UsageQuery? = nil) {
    comparisonStore.refresh(source: meterSource, revision: revision, quotaRevision: quota, state: comparisonState,
                            currentID: meterAccount.id, query: query ?? comparisonQuery, effort: "All levels", now: meterNow)
}
func settleComparison() {
    let deadline = Date().addingTimeInterval(10)
    while comparisonStore.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(!comparisonStore.busy, "Background comparison completes")
}
refreshComparison(); settleComparison()
check(comparisonStore.metering[windowID]?.intervals.count == 2, "Background owner publishes interval evidence")
refreshComparison(); settleComparison()
check(comparisonStore.builds == 1, "Navigation/re-entry reuses unchanged comparison results")
refreshComparison(2); settleComparison()
check(comparisonStore.builds == 2, "Usage revision invalidates comparison")
refreshComparison(2, quota: 2); settleComparison()
check(comparisonStore.builds == 3, "Retained quota revision invalidates comparison")
refreshComparison(2, quota: 2, query: UsageQuery(period: 1, model: "gpt-6-astra")); settleComparison()
check(comparisonStore.metering[windowID]?.intervals.isEmpty == true, "Query changes replace incompatible comparisons")
print("PASS: matched allowance/token intervals, divergence, mixed models, resets/gaps, attribution/timing gaps and process-owned reuse/invalidation")

var previousDayBucket = coarseMeter; previousDayBucket.date = meterNow.addingTimeInterval(-86400)
let preciseDay = MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource + [previousDayBucket], query: UsageQuery(period: 1), effort: "All levels", now: meterNow)
check(preciseDay.coarseRecords == 1 && preciseDay.intervals.allSatisfy { $0.tokensPerPoint != nil },
      "A coarse bucket on another day cannot invalidate precise intervals")
var foreign = unbound; foreign.provider = "anthropic"; foreign.harness = "Claude Code"
check(MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id,
    source: meterSource + [foreign], query: UsageQuery(period: 1), effort: "All levels", now: meterNow).intervals[0].tokensPerPoint == 1100,
    "Known foreign usage is outside the unknown Codex attribution denominator")
refreshComparison(3, quota: 3); settleComparison()
let completeBeforeQueue = comparisonStore.calculatedAt
refreshComparison(4, quota: 4); refreshComparison(5, quota: 5)
check(comparisonStore.calculatedAt == completeBeforeQueue && comparisonStore.metering[windowID]?.intervals.count == 2,
      "Source/quota changes preserve the last completed result in the same scope")
settleComparison()
check(comparisonStore.metering[windowID]?.intervals.count == 2 && comparisonStore.calculatedAt != nil,
      "Coalesced background updates publish without starving the view")
print("PASS: coarse timing is interval-local, foreign-tool scope is separate, queued updates preserve completed comparison")

let timingArchiveURL = root.appendingPathComponent("meter-timing.sqlite")
let timingArchive = try RequestArchive(url: timingArchiveURL)
var detailOne = metered(-450); detailOne.recordID = "meter-detail-one"
var detailTwo = metered(-150); detailTwo.recordID = "meter-detail-two"
try timingArchive.record(detailOne, admitted: true); try timingArchive.record(detailTwo, admitted: true)
var dailyMeter = detailOne; dailyMeter.date = Calendar.current.startOfDay(for: meterNow)
dailyMeter.tokens = detailOne.tokens + detailTwo.tokens; dailyMeter.bucket = "day"; dailyMeter.sampleCount = 2
dailyMeter.recordID = nil; dailyMeter.requestInputTokens = nil
let archivedComparison = UsageComparisonStore()
archivedComparison.refresh(source: [dailyMeter], revision: 1, quotaRevision: 1, state: comparisonState,
    currentID: meterAccount.id, query: comparisonQuery, effort: "All levels", now: meterNow,
    archiveURL: timingArchiveURL, archiveCount: 2)
let archiveDeadline = Date().addingTimeInterval(10)
while archivedComparison.busy && Date() < archiveDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(archivedComparison.metering[windowID]?.coarseRecords == 0 && archivedComparison.metering[windowID]?.intervals.map(\.tokensPerPoint) == [1100, 550],
      "Background comparison recovers exact matching archived timing after daily compaction")
var since = comparisonQuery; since.period = 5; since.start = meterNow.addingTimeInterval(-600)
check(MeteringComparison.build(history: meterHistory, windowID: windowID, accountID: meterAccount.id, source: [dailyMeter],
    query: since, effort: "All levels", now: meterNow).coarseRecords == 2,
    "A bucket starting before a partial-day selection still makes overlapping intervals uncertain")
print("PASS: reconciled request archive supplies exact metering timing; partial-day coarse overlap stays unavailable")

// Exercise indexed archive reads through the production decoder, not a synthetic
// replacement list. Irrelevant days/accounts must never be materialized.
let boundedArchiveURL = root.appendingPathComponent("bounded-meter.sqlite")
let boundedArchive = try RequestArchive(url: boundedArchiveURL)
try boundedArchive.record(detailOne, admitted: true); try boundedArchive.record(detailTwo, admitted: true)
var oldDetail = detailOne; oldDetail.date = oldDetail.date.addingTimeInterval(-10 * 86400)
oldDetail.recordID = "outside-period"; try boundedArchive.record(oldDetail, admitted: true)
let irrelevantRows = 1024
for index in 0..<irrelevantRows {
    var irrelevant = oldDetail; irrelevant.recordID = "irrelevant-\(index)"
    try boundedArchive.record(irrelevant, admitted: true)
}
var oldDaily = oldDetail; oldDaily.bucket = "day"; oldDaily.recordID = nil
var foreignDetail = detailOne; foreignDetail.session = "foreign-account"
foreignDetail.account = Account(id: "foreign", label: "Synthetic foreign", plan: "pro")
foreignDetail.recordID = "foreign-detail"; try boundedArchive.record(foreignDetail, admitted: true)
var foreignDaily = foreignDetail; foreignDaily.bucket = "day"; foreignDaily.recordID = nil
var archiveOpens = 0
var failRead = false
let boundedDetails = ComparisonDetails(open: { _ in
    archiveOpens += 1
    return { group in
        if failRead { throw RequestArchive.failure("Injected interrupted group read") }
        var rows: [Entry] = []
        try boundedArchive.forEach(group: group) { rows.append($0) }
        return rows
    }
})
let boundedStore = UsageComparisonStore(details: boundedDetails)
let boundedSource = [dailyMeter, oldDaily, foreignDaily]
func settle(_ store: UsageComparisonStore) {
    let deadline = Date().addingTimeInterval(10)
    while store.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(!store.busy, "Bounded comparison completes")
}
func refreshBounded(_ source: [Entry], revision: UInt64, count: Int, at: Date = meterNow) {
    boundedStore.refresh(source: source, revision: revision, quotaRevision: 1, state: comparisonState,
        currentID: meterAccount.id, query: comparisonQuery, effort: "All levels", now: at,
        archiveURL: boundedArchiveURL, archiveCount: count)
    settle(boundedStore)
}
refreshBounded(boundedSource, revision: 1, count: 4 + irrelevantRows)
check(boundedArchive.decodedRowCount == 2 && archiveOpens == 1 && boundedArchive.readVMSteps < irrelevantRows,
      "Group-index read work stays below irrelevant row count; only relevant account/day payloads decode")
check(boundedStore.metering[windowID]?.intervals.map(\.tokensPerPoint) == [1100, 550],
      "Indexed group reads preserve exact reconciliation")
var currentAppend = metered(-30); currentAppend.session = "new-current-task"; currentAppend.recordID = "current-append"
try boundedArchive.record(currentAppend, admitted: true)
refreshBounded(boundedSource + [currentAppend], revision: 2, count: 5 + irrelevantRows)
check(boundedArchive.decodedRowCount == 2 && archiveOpens == 1
      && boundedStore.metering[windowID]?.intervals.last?.tokensPerPoint == 1100,
      "A new current request updates counters without reopening or decoding unchanged recovered history")
let previousIntervals = boundedStore.metering[windowID]?.intervals.map(\.tokensPerPoint)
var extraDetail = metered(-100); extraDetail.recordID = "new-historical-detail"
try boundedArchive.record(extraDetail, admitted: true)
var changedDaily = dailyMeter; changedDaily.tokens = changedDaily.tokens + extraDetail.tokens; changedDaily.sampleCount = 3
failRead = true
refreshBounded([changedDaily, currentAppend], revision: 3, count: 6 + irrelevantRows)
check(boundedStore.recoveryError != nil && boundedStore.metering[windowID]?.intervals.map(\.tokensPerPoint) == previousIntervals,
      "An interrupted group read is visible and preserves the completed comparison")
failRead = false
refreshBounded([changedDaily, currentAppend], revision: 3, count: 6 + irrelevantRows, at: meterNow.addingTimeInterval(31))
check(boundedStore.recoveryError == nil && boundedStore.metering[windowID]?.intervals.last?.tokensPerPoint == 1650,
      "The identical source/query/count can retry a failed expansion and publish recovered timing")

var openAttempts = 0
let retryOpenStore = UsageComparisonStore(details: ComparisonDetails(open: { url in
    openAttempts += 1
    if openAttempts == 1 { throw RequestArchive.failure("Injected transient open failure") }
    let archive = try RequestArchive(url: url, readOnly: true)
    return { group in
        var rows: [Entry] = []; try archive.forEach(group: group) { rows.append($0) }; return rows
    }
}))
func retryOpen(at: Date = meterNow) {
    retryOpenStore.refresh(source: [dailyMeter], revision: 1, quotaRevision: 1, state: comparisonState,
        currentID: meterAccount.id, query: comparisonQuery, effort: "All levels", now: at,
        archiveURL: timingArchiveURL, archiveCount: 2)
    settle(retryOpenStore)
}
retryOpen()
check(retryOpenStore.recoveryError != nil && retryOpenStore.metering[windowID]?.coarseRecords == 2,
      "An archive-open failure retains visible coarse uncertainty")
retryOpen()
check(openAttempts == 1 && retryOpenStore.builds == 1,
      "A one-second dashboard refresh cannot loop on the same failed archive")
retryOpen(at: meterNow.addingTimeInterval(31))
check(openAttempts == 2 && retryOpenStore.recoveryError == nil
      && retryOpenStore.metering[windowID]?.intervals.map(\.tokensPerPoint) == [1100, 550],
      "A later same-source refresh retries archive open instead of caching the failure")
print("PASS: indexed period/account recovery, historical cache reuse on append, visible read failure and same-source open/read retries")

let scopedDetails = ComparisonDetails()
let intervals = [MeteringInterval(start: meterNow.addingTimeInterval(-600), end: meterNow.addingTimeInterval(-300), usedPoints: 1),
                 MeteringInterval(start: meterNow.addingTimeInterval(-450), end: meterNow.addingTimeInterval(-200), usedPoints: 1),
                 MeteringInterval(start: meterNow.addingTimeInterval(-100), end: meterNow, usedPoints: 1)]
let points = [-600.0, -500, -300, -200, -150, -100, -50, 0, 10].map { metered($0) }
let selectedPoints = try scopedDetails.recover(points, intervals: intervals, account: meterAccount.id, url: nil, archiveCount: nil)
check(selectedPoints.map { $0.date.timeIntervalSince(meterNow) } == [-500, -300, -200, -50, 0],
      "Merged interval lookup preserves open starts, closed ends, overlaps and excluded gaps")
print("PASS: merged interval scope boundaries and indexed physical archive read work")
