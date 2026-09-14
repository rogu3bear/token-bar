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
scanner.consume(event(counts(272_000, output: 10), counts(272_000, output: 10)), session: "s", cursor: &cursor, account: nil, poll: now)
check(scanner.ledger.entries[0].contextBand == "short" && scanner.ledger.entries[0].effort == "high", "Threshold is strictly greater than 272K; capture effort")
scanner.consume(data("turn_context", ["model": "gpt-6-astra", "turn_id": "two"]), session: "s", cursor: &cursor, account: nil, poll: now)
scanner.consume(event(counts(544_001, output: 20), counts(272_001, output: 10)), session: "s", cursor: &cursor, account: nil, poll: now)
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
