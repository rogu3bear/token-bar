import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
func date(_ day: String) -> Date { ProviderUsage.dayDate(day)! }
func entry(_ day: String, id: String = "one", effort: String? = "high", tokens: Int = 100) -> Entry {
    var value = Entry(date: date(day).addingTimeInterval(123.456), session: "fixture", model: "gpt-5.6-sol",
                      tokens: Tokens(["input_tokens": tokens, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 10, "reasoning_output_tokens": 5]), account: nil)
    value.recordID = id; value.turnID = "turn"; value.provider = "openai"; value.effort = effort
    value.tokenFields = UsageMetadata.fields; value.pricingDay = day; value.firstObserved = value.date
    value.requestInputTokens = tokens; value.contextBand = "short"; value.costMetadataVersion = 2
    return value
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-accuracy-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let archiveURL = root.appendingPathComponent("requests.sqlite")
var archive: RequestArchive? = try RequestArchive(url: archiveURL)
let first = entry("2026-09-07")
try archive!.begin(); try archive!.record(first); try archive!.commit()
var count = try archive!.count
check(count == 0, "Before ledger admission, durable details must remain invisible")
archive = nil; archive = try RequestArchive(url: archiveURL)
try archive!.acknowledge { $0 == first.recordID }
count = try archive!.count; check(count == 1, "Restart acknowledges the already durable ledger ID")
var changed = first; changed.tokens.input = 999
try archive!.record(changed, admitted: true)
var retained: [Entry] = []; try archive!.forEach { retained.append($0) }
check(retained.count == 1 && retained[0].tokens.input == 100, "An admitted ID is immutable and never doubled")
check(retained[0].date == first.date && retained[0].requestInputTokens == 100 && retained[0].turnID == "turn", "Archive preserves exact timestamp and request context")
try archive!.begin(); try archive!.record(entry("2026-09-07", id: "rollback")); archive!.rollback()
try archive!.acknowledge { _ in true }; count = try archive!.count; check(count == 1, "Rolled-back scan cannot leak detail records")
let csvURL = root.appendingPathComponent("requests.csv")
let exported = try RequestExport.write(archive: archive!, destination: csvURL, query: UsageQuery(period: 1), catalog: [:], effort: "All levels", now: date("2026-09-10"))
let csv = try String(contentsOf: csvURL, encoding: .utf8)
check(exported == 1 && csv.contains("2026-09-07T00:02:03.456Z") && csv.contains("single_request") && csv.contains(UsageMetadata.unknownAccount), "Export retains fractional timestamp, explicit granularity and unattributed account face")
let source = try RequestArchive(url: root.appendingPathComponent("source.sqlite"))
try source.record(entry("2026-09-07", id: "different-id"), admitted: true)
let excluded = try archive!.importAccepted(from: source, groups: [CostRecovery.groupKey(first)], accounts: [:])
check(excluded == 1, "Skipped identity-conflicting groups must be observable")
count = try archive!.count; check(count == 1, "Same group totals with changed event identities must not double the archive")
print("PASS: durable pending archive, restart acknowledgment, immutable dedup, rollback, exact timestamp export and conflicting backfill IDs")

do {
    check(UsageMetadata.accountAttribution(nil) == "unknown",
          "Missing account stays unknown, not a guessed person")
    check(UsageMetadata.accountAttribution(Account(id: "a", label: "Ada")) == "inferred from local sign-in observation",
          "An observed account is local sign-in evidence, matching History export")
    let url = root.appendingPathComponent("attribution.csv")
    let store = try RequestArchive(url: root.appendingPathComponent("attribution.sqlite"))
    var row = entry("2026-09-07", id: "attributed")
    row.account = Account(id: "a", label: "Ada")
    try store.record(row, admitted: true)
    _ = try RequestExport.write(archive: store, destination: url, query: UsageQuery(period: 1), catalog: [:], effort: "All levels", now: date("2026-09-10"))
    let text = try String(contentsOf: url, encoding: .utf8)
    check(text.contains(UsageMetadata.inferredAccount),
          "Request CSV uses the History sign-in attribution face")
}
print("PASS: request and History account attribution share one local sign-in face")

do {
    let url = root.appendingPathComponent("count-cache.sqlite")
    let store = try RequestArchive(url: url)
    try store.begin()
    for index in 0..<10_000 { try store.record(entry("2026-09-07", id: "count-\(index)"), admitted: true) }
    try store.commit()
    for _ in 0..<100 {
        let value = try store.count
        check(value == 10_000, "Unchanged refreshes retain the exact archive total")
    }
    check(store.countQueryCount == 1, "One baseline query serves 100 refreshes")
    try store.record(entry("2026-09-07", id: "pending-count"))
    try store.record(entry("2026-09-07", id: "count-0"), admitted: true)
    var value = try store.count
    check(value == 10_000, "Pending rows and admitted duplicate IDs never increase the total")
    try store.acknowledge { _ in true }
    try store.acknowledge { _ in true }
    try store.record(entry("2026-09-07", id: "direct-count"), admitted: true)
    value = try store.count
    check(value == 10_002 && store.countQueryCount == 1, "Acknowledgement and direct admission update the baseline without recounting")
    try store.begin()
    try store.record(entry("2026-09-07", id: "rollback-count"), admitted: true)
    value = try store.count; check(value == 10_003, "Count includes this connection's transactional admissions")
    store.rollback()
    value = try store.count; check(value == 10_002, "Rollback discards the transactional count")
    try store.record(entry("2026-09-07", id: "failure-a"))
    try store.record(entry("2026-09-07", id: "failure-b"))
    do {
        try store.acknowledge { id in
            if id == "failure-b" { throw RequestArchive.failure("Synthetic acknowledgement failure") }
            return true
        }
        preconditionFailure("Acknowledgement must fail after its first mutation")
    } catch {}
    value = try store.count; check(value == 10_002, "Partial acknowledgement failure rolls back rows and count")
    try store.acknowledge { _ in true }
    value = try store.count; check(value == 10_004, "Retry admits exactly once after failure")
    let observer = try RequestArchive(url: url, readOnly: true)
    value = try observer.count; check(value == 10_004, "A reopened archive rebuilds its own exact baseline")
    try store.record(entry("2026-09-07", id: "external-count"), admitted: true)
    value = try observer.count
    check(value == 10_005 && observer.countQueryCount == 2, "Another connection's commit invalidates a read-only cached total")
    do {
        try observer.record(entry("2026-09-07", id: "read-only-count"), admitted: true)
        preconditionFailure("Read-only admission must fail")
    } catch {}
    value = try observer.count; check(value == 10_005, "Failed mutation cannot advance the cached total")
    let recovered = try RequestArchive(url: root.appendingPathComponent("count-import.sqlite"))
    let importedEntry = entry("2026-09-07", id: "import-count")
    try recovered.record(importedEntry, admitted: true)
    try store.importAccepted(from: recovered, groups: [CostRecovery.groupKey(importedEntry)], accounts: [:])
    // Existing identities conflict with this synthetic group's replacement, so it is excluded.
    value = try store.count; check(value == 10_005, "Excluded recovery groups do not alter the cached total")
    let destination = try RequestArchive(url: root.appendingPathComponent("count-import-destination.sqlite"))
    value = try destination.count; check(value == 0, "An empty archive has a measured zero baseline")
    try destination.importAccepted(from: recovered, groups: [CostRecovery.groupKey(importedEntry)], accounts: [:])
    value = try destination.count
    check(value == 1 && destination.countQueryCount == 1, "Accepted recovery maintains the existing count baseline")
    print("PASS: 100 refreshes share one 10000-row count; admission, dedup, rollback, failure, restart, external commits and recovery preserve exact totals")
}

let old = CostRateHistory.estimate(entry("2026-08-20"), service: .standard, sessionBand: "short")
let new = CostRateHistory.estimate(entry("2026-08-22"), service: .standard, sessionBand: "short")
check(old.amounts!.total == Decimal(string: "0.0008")! && new.amounts!.total == Decimal(string: "0.0006")!, "Dated Sol rates must select the correct interval")
check(old.rateCardID != new.rateCardID && old.effectiveUntil == "2026-08-21", "Exportable price provenance identifies effective intervals")
check(CostRateHistory.estimate(entry("2026-08-21"), service: .standard, sessionBand: "short").amounts == nil, "Ambiguous intraday cutovers are unpriced")
check(CostRateHistory.estimate(entry("2026-07-08"), service: .standard, sessionBand: "short").amounts == nil, "Never backdate the earliest verified schedule")
var long = entry("2026-08-22"); long.contextBand = "long"
check(CostRateHistory.estimate(long, service: .standard, sessionBand: "long").amounts == nil, "Current long-context tariff cannot be silently backdated")
var tier = entry("2026-09-08"); tier.requestedService = "priority"
check(CostPricing.estimate(tier, service: .observed).amounts == nil, "Requested tier is not a usage-reported tier")
tier.observedService = "priority"; tier.serviceEvidence = "token_count.info.service_tier"
check(CostPricing.estimate(tier, service: .observed).amounts!.total == CostPricing.estimate(tier, service: .standard).amounts!.total * 2, "Usage-reported tier and explicit comparison remain independent")
print("PASS: dated prices, cutover and prehistory holds, historical context gaps, recorded-tier versus requested-tier separation")

var missing = entry("2026-09-08", id: "missing", effort: nil, tokens: 890)
missing.tokenFields = ["input_tokens", "output_tokens"]; missing.requestInputTokens = nil; missing.contextBand = nil
let coverage = CostCoverage.build([first, missing])
check(coverage.totalTokens == 1010 && coverage.records == 2, "Coverage denominator is all selected processed tokens and records")
check(coverage.dimensions.first { $0.id == "effort" }!.knownTokens == 110, "Token-weighted completeness is not a record percentage")
check(coverage.dimensions.first { $0.id == "cache_write" }!.knownRecords == 1, "An explicit zero is known; missing counter is not")
check(coverage.dimensions.first { $0.id == "service" }!.knownTokens == 0, "Missing tier cannot appear complete")
check(CostPricing.estimate(missing).amounts == nil, "Absent cache fields remain unpriced")
print("PASS: separate completeness dimensions, token and record denominators, zero versus missing fields")

let payload: [String: Any] = ["summary": ["lifetimeTokens": 5000], "dailyUsageBuckets": [["startDate": "2026-09-07", "tokens": 200], ["startDate": "2026-09-09", "tokens": 999]]]
let provider = try ProviderUsage.decode(payload, accountID: "a", afterID: "a", now: date("2026-09-09").addingTimeInterval(500))
var accountEntry = first; accountEntry.account = Account(id: "a", label: "Synthetic", plan: "pro")
let compare = ProviderComparison.build(snapshot: provider, currentID: "a", source: [accountEntry, missing], query: UsageQuery(period: 1), effort: "All levels", now: date("2026-09-09").addingTimeInterval(600))
check(compare.selectedDays == 2 && compare.reportedDays == 1 && compare.providerTokens == 200 && compare.delta == -90, "Only complete matched UTC days compare; absent bucket is not zero")
check(compare.localUnattributedTokens == 0, "Unattributed records outside matched provider days are excluded")
check(ProviderComparison.build(snapshot: provider, currentID: "b", source: [first], query: UsageQuery(period: 1), effort: "All levels").delta == nil, "Account switch invalidates comparison")
check(ProviderComparison.build(snapshot: provider, currentID: "a", source: [first], query: UsageQuery(period: 1, model: "gpt-5.6-sol"), effort: "All levels").delta == nil, "All-model provider totals cannot be compared to a model filter")
check(ProviderComparison.build(snapshot: provider, currentID: "a", source: [first], query: UsageQuery(period: 1, harness: "Codex CLI"), effort: "All levels").delta == nil, "Account-wide provider totals cannot be compared to a Tool filter")
var rejected = false
 do { _ = try ProviderUsage.decode(payload, accountID: "a", afterID: "b") } catch { rejected = true }
check(rejected, "Account switch during read is rejected")
rejected = false
 do { _ = try ProviderUsage.decode(["dailyUsageBuckets": [["startDate": "2026-02-30", "tokens": 2]]], accountID: "a", afterID: "a") } catch { rejected = true }
check(rejected, "Invalid provider day must not silently disappear")
print("PASS: provider day and account validation, matched-day arithmetic, absent-day coverage, partial-day exclusion and filter boundaries")

let home = root.appendingPathComponent("scanner")
let sessions = home.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
func record(_ type: String, _ payload: [String: Any], stamp: String = "2026-09-07T12:00:00.123Z") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": stamp, "payload": payload], options: [.sortedKeys]) + Data([10])
}
let tokens1: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 10, "reasoning_output_tokens": 5]
let tokens2: [String: Any] = ["input_tokens": 200, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 20, "reasoning_output_tokens": 10]
let log = try record("session_meta", ["model_provider": "openai"])
    + record("turn_context", ["model": "gpt-5.6-sol", "effort": "high", "turn_id": "first", "service_tier": "priority"])
    + record("event_msg", ["type": "token_count", "info": ["total_token_usage": tokens1, "last_token_usage": tokens1, "service_tier": "default"]])
    + record("turn_context", ["model": "gpt-5.6-sol", "turn_id": "second"])
    + record("event_msg", ["type": "token_count", "info": ["total_token_usage": tokens2, "last_token_usage": tokens1]], stamp: "2026-09-07T12:00:01.456Z")
try log.write(to: sessions.appendingPathComponent("rollout-00000000-0000-0000-0000-000000000001.jsonl"))
try log.write(to: sessions.appendingPathComponent("rollout-00000000-0000-0000-0000-000000000002.jsonl"))
let ledgerURL = home.appendingPathComponent("ledger.json")
 do {
    let scanner = UsageScanner(home: home, stateURL: ledgerURL); scanner.rebuilding = true; scanner.readAccount = false
    let snapshot = scanner.scan(historical: true)
    check(snapshot.error == nil && snapshot.entries.reduce(0) { $0 + $1.tokens.total } == 220, "Scanner still deduplicates identical fork counters")
    var details: [Entry] = []; try scanner.requestArchive!.forEach { details.append($0) }
    check(details.count == 2 && details[0].date != details[1].date, "Archive retains separate timestamped records before daily aggregation")
    check(details[0].requestedService == "priority" && details[0].observedService == "default", "Requested and observed tier have independent provenance")
    check(details[1].effort == nil && details[1].requestedService == nil && details[1].observedService == nil, "Missing next-turn and next-usage metadata does not inherit")
    check(snapshot.entries.allSatisfy { $0.bucket == "day" && $0.requestInputTokens == nil && $0.pricingDay == "2026-09-07" }, "Daily summaries preserve pricing day without claiming a summed request size")
 }
 do {
    let restarted = UsageScanner(home: home, stateURL: ledgerURL); restarted.readAccount = false
    _ = restarted.scan(historical: true)
    let count = try restarted.requestArchive!.count
    check(count == 2 && restarted.ledger.entries.reduce(0) { $0 + $1.tokens.total } == 220, "Durable scan restart must not inflate archive or ledger")
 }
print("PASS: production scan to daily summary and detail archive, fork dedup, service provenance, missing-turn reset and restart")

let pricedReport = CostReport.build(source: [entry("2026-08-22")], query: UsageQuery(period: 1), catalog: [:], basis: .historical, now: date("2026-09-10"))
let historicalCSV = pricedReport.csv()
let legacyHeader = "timestamp,session,provider,model,reasoning_level,input,cached_input,cache_write_input,output,reasoning_subset,granularity,record_count,context_band,effective_context_band,context_scope,reference_rate_card,reference_service,currency,estimated_usd,input_usd,cached_usd,cache_write_usd,reasoning_usd,answer_usd,unpriced_reason"
check(historicalCSV.hasPrefix(legacyHeader + ",schema_version,"), "Existing CSV columns and order remain intact; provenance is appended")
check(historicalCSV.contains("gpt-5.6-sol-2026-08-21") && historicalCSV.contains("Historical rates"), "Historical export includes the actual dated schedule")
print("PASS: compatible CSV prefix and explicit versioned historical provenance")

// The same ID elsewhere in a reconstructed archive must not authorize adding
// a replacement to its retained day, even when that day's totals still match.
let movedDestination = try RequestArchive(url: root.appendingPathComponent("moved-destination.sqlite"))
let movedSource = try RequestArchive(url: root.appendingPathComponent("moved-source.sqlite"))
let retainedA = entry("2026-09-07", id: "moved-A")
let movedA = entry("2026-09-08", id: "moved-A")
let replacementB = entry("2026-09-07", id: "replacement-B")
try movedDestination.record(retainedA, admitted: true)
try movedSource.record(movedA, admitted: true)
try movedSource.record(replacementB, admitted: true)
let admittedGroups = CostRecovery.reconcile(original: [retainedA], reconstructed: [movedA, replacementB]).acceptedKeys
check(admittedGroups.contains(CostRecovery.groupKey(retainedA)), "Regression must reach an accepted counter-matching group")
let movedExcluded = try movedDestination.importAccepted(from: movedSource, groups: admittedGroups, accounts: [:])
var movedRows: [Entry] = []; try movedDestination.forEach { movedRows.append($0) }
check(movedExcluded == 1 && movedRows.count == 1 && movedRows[0].recordID == "moved-A" && movedRows[0].date == retainedA.date, "Moved ID cannot authorize a duplicate replacement on its original day")
let reverseDestination = try RequestArchive(url: root.appendingPathComponent("reverse-destination.sqlite"))
try reverseDestination.record(retainedA, admitted: true)
let reverseExcluded = try reverseDestination.importAccepted(from: movedSource, groups: [CostRecovery.groupKey(movedA)], accounts: [:])
check(reverseExcluded == 1, "Incoming ID retained on an unaccepted day must also reject its new group")
let changedSource = try RequestArchive(url: root.appendingPathComponent("changed-payload.sqlite"))
var changedA = retainedA; changedA.date = changedA.date.addingTimeInterval(60)
try changedSource.record(changedA, admitted: true)
let changedExcluded = try movedDestination.importAccepted(from: changedSource, groups: [CostRecovery.groupKey(retainedA)], accounts: [:])
check(changedExcluded == 1, "Same ID and day cannot hide a conflicting precise timestamp")
let sameSource = try RequestArchive(url: root.appendingPathComponent("same-payload.sqlite"))
try sameSource.record(retainedA, admitted: true)
let sameExcluded = try movedDestination.importAccepted(from: sameSource, groups: [CostRecovery.groupKey(retainedA)], accounts: [:])
check(sameExcluded == 0, "Compatible same-group payload must still reconcile")
print("PASS: moved-day identity, reverse cross-group conflict, changed payload and compatible retained record")

let exportArchive = try RequestArchive(url: root.appendingPathComponent("missing-export.sqlite"))
var absent = entry("2026-09-07", id: "absent-fields", tokens: 0)
absent.tokens.output = 0; absent.tokens.reasoning = 0
absent.tokenFields = UsageMetadata.fields.filter { $0 != "input_tokens" && $0 != "output_tokens" }
var explicitZero = absent; explicitZero.recordID = "explicit-zero"; explicitZero.tokenFields = UsageMetadata.fields
try exportArchive.record(absent, admitted: true); try exportArchive.record(explicitZero, admitted: true)
let missingCSV = root.appendingPathComponent("missing-fields.csv")
_ = try RequestExport.write(archive: exportArchive, destination: missingCSV, query: UsageQuery(period: 1), catalog: [:], effort: "All levels", now: date("2026-09-10"))
// These controlled fixture cells contain no embedded commas or escaped quotes.
func fixtureCSV(_ text: String) -> [[String: String]] {
    let lines = text.split(separator: "\n").map(String.init)
    let header = lines[0].split(separator: ",").map(String.init)
    return lines.dropFirst().map { line in
        let values = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0.dropFirst().dropLast()) }
        check(values.count == header.count, "Fixture CSV column count")
        return Dictionary(uniqueKeysWithValues: zip(header, values))
    }
}
let requestRows = fixtureCSV(try String(contentsOf: missingCSV, encoding: .utf8))
check(requestRows.first { $0["record_id"] == "absent-fields" }?["input"] == "" && requestRows.first { $0["record_id"] == "absent-fields" }?["output"] == "", "Request CSV keeps absent input/output blank")
check(requestRows.first { $0["record_id"] == "explicit-zero" }?["input"] == "0" && requestRows.first { $0["record_id"] == "explicit-zero" }?["output"] == "0", "Request CSV preserves explicit input/output zero")
let costRows = fixtureCSV(CostReport.build(source: [absent, explicitZero], query: UsageQuery(period: 1), catalog: [:], now: date("2026-09-10")).csv())
check(costRows[0]["input"] == "" && costRows[0]["output"] == "", "Cost CSV keeps absent input/output blank")
check(costRows[1]["input"] == "0" && costRows[1]["output"] == "0", "Cost CSV preserves explicit input/output zero")
print("PASS: both CSV exports distinguish absent input/output from explicit zero")

var undated = entry("2026-09-07")
let beforeTokens = undated.tokens
undated.pricingDay = nil
UsageMetadata.recoverPricingDay(&undated)
check(undated.pricingDay == "2026-09-07" && undated.tokens == beforeTokens, "A timestamped Codex row recovers the UTC pricing day without changing totals")
var already = entry("2026-09-08"); already.pricingDay = "2026-09-08"
UsageMetadata.recoverPricingDay(&already)
check(already.pricingDay == "2026-09-08", "An existing pricing day is left alone")
let recoveryHome = root.appendingPathComponent("pricing-day")
try FileManager.default.createDirectory(at: recoveryHome, withIntermediateDirectories: true)
var stored = entry("2026-09-07"); stored.pricingDay = nil
var storedLedger = Ledger(); storedLedger.entries = [stored]; storedLedger.started = date("2026-09-01")
try JSONEncoder().encode(storedLedger).write(to: recoveryHome.appendingPathComponent("ledger.json"))
let recoveredScanner = UsageScanner(home: recoveryHome, stateURL: recoveryHome.appendingPathComponent("ledger.json"))
recoveredScanner.readAccount = false
check(recoveredScanner.ledger.entries.count == 1, "Recovery load must keep the admitted row")
check(recoveredScanner.ledger.entries[0].pricingDay == "2026-09-07", "Missing recoverable UTC days are filled on already-admitted rows")
check(recoveredScanner.ledger.entries[0].tokens.total == stored.tokens.total, "Date recovery must not change token totals")
print("PASS: missing UTC pricing day recovery on timestamped Codex rows")

var legacyDay = Entry(date: Date(), session: "legacy", model: "unknown", tokens: Tokens())
legacyDay.bucket = "day"; legacyDay.pricingDay = nil
UsageMetadata.recoverPricingDay(&legacyDay)
assert(legacyDay.pricingDay == nil, "A local daily aggregate cannot establish one UTC pricing day")
print("PASS: legacy daily pricing remains unknown without source evidence")

// Storage-phase failures use synthetic state only. The hook throws before the
// real phase; reopening the scanner models each process-crash recovery window.
do {
    func makeScanner(_ name: String) -> UsageScanner {
        let scanner = UsageScanner(home: root, stateURL: root.appendingPathComponent(name + ".json"))
        scanner.readAccount = false
        return scanner
    }
    func admit(_ scanner: UsageScanner, _ name: String) -> String {
        let id = UsageScanner.foreignIdentity(harness: "checkpoint-test", messageID: name)
        var value = entry("2026-09-07", id: id)
        value.session = "checkpoint"
        scanner.persistAdmitted(value, fingerprint: id, date: value.date)
        return id
    }
    let batch = makeScanner("batches")
    for round in 0..<5 {
        for item in 0..<2000 { _ = admit(batch, "batch-\(round)-\(item)") }
        try batch.saveIfNeeded(force: true)
        let disk = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: batch.stateURL))
        check(batch.ledger.eventIDs?.isEmpty == true && disk.eventIDs?.count == 2000,
              "Memory retires IDs and disk retains only the latest batch, not lifetime IDs")
        check(!batch.needsSave && batch.persistenceCount == round + 1, "One encoding per genuine batch")
    }
    let retainedCount = try batch.requestArchive!.count
    check(retainedCount == 10000 && batch.ledger.entries.reduce(0) { $0 + $1.eventCount } == 10000, "All 10000 requests survive retirement")
    for round in 0..<5 {
        for item in 0..<2000 {
            let id = UsageScanner.foreignIdentity(harness: "checkpoint-test", messageID: "batch-\(round)-\(item)")
            check(batch.identityKnown(id) == true, "Retired identity remains known")
        }
    }
    for _ in 0..<5 { try batch.saveIfNeeded(force: true) }
    check(batch.persistenceCount == 5, "Idle and final flush do not rewrite clean JSON")
    let reopened = makeScanner("batches")
    check(!reopened.needsSave, "Restart ID retirement alone does not require a JSON rewrite")
    check(reopened.ledger.entries.reduce(0) { $0 + $1.eventCount } == 10000, "Restart preserves all counters")
    for phase in [CheckpointPhase.ledger, .index, .acknowledge] {
        let name = "failure-\(phase)"
        var failing: UsageScanner? = makeScanner(name)
        try failing!.saveIfNeeded(force: true)
        let id = admit(failing!, name)
        failing!.checkpointWillRun = { step in
            if step == phase { throw RequestArchive.failure("Synthetic phase failure") }
        }
        do { try failing!.saveIfNeeded(force: true); preconditionFailure("Expected phase failure") } catch {}
        let disk = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: failing!.stateURL))
        check(disk.eventIDs?.contains(id) == (phase != .ledger), "Only durable snapshot carries the new ID")
        check(failing!.eventIndex!.contains(id) == (phase == .acknowledge), "Index never leads durable ledger")
        let invisible = try failing!.requestArchive!.count
        check(invisible == 0 && failing!.needsSave, "Failed phase is retriable and details stay pending")
        failing = nil
        let restart = makeScanner(name)
        let visible = try restart.requestArchive!.count
        check(visible == (phase == .ledger ? 0 : 1), "Restart acknowledges only durable totals")
        if phase == .ledger { _ = admit(restart, name); try restart.saveIfNeeded(force: true) }
        check(restart.identityKnown(id) == true, "Restart/retry knows exact original ID")
    }
    let retry = makeScanner("retry")
    try retry.saveIfNeeded(force: true)
    let durableID = admit(retry, "durable")
    retry.checkpointWillRun = { if $0 == .acknowledge { throw RequestArchive.failure("Synthetic ack failure") } }
    do { try retry.saveIfNeeded(force: true); preconditionFailure("Expected ack failure") } catch {}
    let writes = retry.persistenceCount
    let unsavedID = admit(retry, "not-yet-durable")
    retry.checkpointWillRun = nil
    try retry.saveIfNeeded(now: retry.lastSave)
    let visible = try retry.requestArchive!.count
    check(visible == 1 && retry.eventIndex!.contains(durableID) == true && retry.eventIndex!.contains(unsavedID) == false,
          "Retry only acknowledges captured durable IDs, not newer in-memory admissions")
    check(retry.persistenceCount == writes && retry.ledger.eventIDs == [unsavedID], "Ack retry needs no encoding and retires only captured IDs")
    try retry.saveIfNeeded(force: true)
    let finalCount = try retry.requestArchive!.count
    check(finalCount == 2 && !retry.needsSave, "Final flush settles new usage and checkpoint work")
    let indexRetry = makeScanner("index-retry")
    _ = admit(indexRetry, "index-retry")
    indexRetry.checkpointWillRun = { if $0 == .index { throw RequestArchive.failure("Synthetic index failure") } }
    do { try indexRetry.saveIfNeeded(force: true); preconditionFailure("Expected index failure") } catch {}
    indexRetry.checkpointWillRun = nil
    try indexRetry.saveIfNeeded(force: true)
    check(indexRetry.persistenceCount == 1 && !indexRetry.needsSave, "Index retry without input reuses durable snapshot")
}
print("PASS: 10000 IDs in five bounded recovery batches, storage-phase failure/restart, exact retry visibility and no idle rewrites")

// Growing non-usage transcripts must checkpoint their byte position without
// serializing historical entries again. Exercise the real scanner, not a timer.
do {
    let home = root.appendingPathComponent("metadata-checkpoint")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let url = home.appendingPathComponent("ledger.json")
    let log = sessions.appendingPathComponent("synthetic.jsonl")
    let scanner = UsageScanner(home: home, stateURL: url)
    scanner.readAccount = false
    var value = entry("2026-09-13")
    value.date = Date(); value.pricingDay = nil; UsageMetadata.recoverPricingDay(&value)
    scanner.ledger.entries = (0..<10_000).map { index in
        var item = value; item.session = "history-\(index)"; item.recordID = "synthetic-\(index)"; return item
    }
    scanner.markDirty()
    try scanner.saveIfNeeded(force: true)
    let baseline = try Data(contentsOf: url)
    let baselineEntries = scanner.ledger.entries
    let line = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)
    try line.write(to: log)
    _ = scanner.scan(changedPaths: [log])
    try scanner.saveIfNeeded(force: true)
    let metadataURL = UsageScanner.metadataURL(for: url)
    let metadata = try Data(contentsOf: metadataURL)
    check(try! Data(contentsOf: url) == baseline, "Cursor-only scan leaves every full-history byte unchanged")
    check(metadata.count * 100 < baseline.count, "Cursor checkpoint excludes the history-sized payload")
    let reopened = UsageScanner(home: home, stateURL: url)
    reopened.readAccount = false
    check(reopened.loadError == nil && reopened.ledger.entries == baselineEntries, "Restart restores exact original counters and metadata")
    check(reopened.ledger.cursors["sessions/synthetic.jsonl"]?.offset == UInt64(line.count), "Restart uses the durable cursor")
    _ = reopened.scan(changedPaths: [log])
    check(!reopened.needsSave, "Restart does not replay an unchanged non-usage transcript")
    let attrs = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
    check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Metadata remains private")
    // A genuine admission must replace the full baseline before index/ack.
    let id = UsageScanner.foreignIdentity(harness: "metadata-test", messageID: "new")
    value.recordID = id
    reopened.persistAdmitted(value, fingerprint: id, date: value.date)
    reopened.checkpointWillRun = { if $0 == .index { throw RequestArchive.failure("Synthetic index failure") } }
    do { try reopened.saveIfNeeded(force: true); preconditionFailure("Expected index failure") } catch {}
    let next = try Data(contentsOf: url)
    check(next != baseline, "New admitted totals require a full durable save")
    check(try! Data(contentsOf: metadataURL) == metadata, "Old metadata checkpoint is preserved across the full-save crash window")
    let recovered = UsageScanner(home: home, stateURL: url)
    check(recovered.loadError == nil && recovered.ledger.entries.count == baselineEntries.count + 1,
          "Restart ignores stale metadata and recovers the newer full ledger")
    check(recovered.identityKnown(id) == true, "Full save recovers exact dedup identity before exposing detail")
    check(try! recovered.requestArchive!.count == 1, "Only durable admission is acknowledged after restart")
    // A corrupt checkpoint is never silently ignored or overwritten.
    try Data("broken checkpoint".utf8).write(to: metadataURL)
    let broken = UsageScanner(home: home, stateURL: url)
    check(broken.loadError != nil, "Invalid metadata fails closed")
    do { try broken.saveIfNeeded(force: true); preconditionFailure("Expected preserved load failure") } catch {}
    check(try! Data(contentsOf: url) == next, "Load failure preserves full history")
    check(try! Data(contentsOf: metadataURL) == Data("broken checkpoint".utf8), "Load failure preserves corrupt checkpoint evidence")
    print("PASS: real cursor-only scan writes \(metadata.count) metadata bytes instead of \(baseline.count) ledger bytes")
}

do {
    for phase in [CheckpointPhase.ledger, .index, .acknowledge] {
        let url = root.appendingPathComponent("metadata-failure-\(phase).json")
        let scanner = UsageScanner(home: root, stateURL: url)
        try scanner.saveIfNeeded(force: true)
        let baseline = try Data(contentsOf: url)
        scanner.ledger.cursors["synthetic"] = Cursor(offset: 42)
        scanner.markMetadataDirty()
        scanner.checkpointWillRun = { if $0 == phase { throw RequestArchive.failure("Synthetic metadata failure") } }
        do { try scanner.saveIfNeeded(force: true); preconditionFailure("Expected metadata failure") } catch {}
        let restart = UsageScanner(home: root, stateURL: url)
        check(restart.ledger.cursors["synthetic"]?.offset == (phase == .ledger ? nil : 42), "Only durable metadata survives a process restart")
        scanner.checkpointWillRun = nil
        let writes = scanner.persistenceCount
        try scanner.saveIfNeeded(force: true)
        check(scanner.persistenceCount == writes + (phase == .ledger ? 1 : 0), "Index/ack retry never rewrites metadata")
        check(try! Data(contentsOf: url) == baseline, "Metadata failure/retry never rewrites full history")
        check(!scanner.needsSave, "Metadata retry settles the captured generation")
    }
}
print("PASS: metadata checkpoint migration, restart, private permissions, stale/corrupt handling and storage-phase retry")

do {
    let url = root.appendingPathComponent("legacy-checkpoint.json")
    var legacy = Ledger()
    legacy.cursors["legacy"] = Cursor(offset: 7)
    try JSONEncoder().encode(legacy).write(to: url)
    var stale = Ledger(); stale.checkpointID = UUID(); stale.cursors["legacy"] = Cursor(offset: 99)
    try JSONEncoder().encode(LedgerMetadataCheckpoint(baseline: stale.checkpointID!, metadata: stale))
        .write(to: UsageScanner.metadataURL(for: url))
    let scanner = UsageScanner(home: root, stateURL: url)
    check(scanner.loadError == nil && scanner.ledger.cursors["legacy"]?.offset == 7,
          "A legacy writer that drops the UUID cannot reactivate an old metadata checkpoint")
    try scanner.saveIfNeeded(force: true)
    let restored = try UsageScanner.loadLedger(from: url)
    check(restored.checkpointID != nil && restored.cursors["legacy"]?.offset == 7,
          "Legacy migration creates a full baseline before metadata-only writes")
}
print("PASS: legacy ledger migration and stale sidecar after older-writer rollback")

do {
    let recoveryHome = root.appendingPathComponent("checkpoint-recovery")
    try FileManager.default.createDirectory(at: recoveryHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let scanner = UsageScanner(home: recoveryHome, stateURL: recoveryHome.appendingPathComponent("ledger.json"))
    scanner.readAccount = false
    let id = UsageScanner.foreignIdentity(harness: "recovery", messageID: "original")
    let original = entry("2026-09-07", id: id)
    scanner.persistAdmitted(original, fingerprint: id, date: original.date)
    scanner.checkpointWillRun = { if $0 == .acknowledge { throw RequestArchive.failure("Synthetic recovery ack failure") } }
    do { try scanner.saveIfNeeded(force: true); preconditionFailure("Expected ack failure") } catch {}
    let writes = scanner.persistenceCount
    do { _ = try scanner.recoverCostDetails(); preconditionFailure("Recovery must settle pending checkpoint first") } catch {}
    check(scanner.persistenceCount == writes, "Recovery failure retries pending phase without rewriting JSON")
    scanner.checkpointWillRun = nil
    _ = try scanner.recoverCostDetails()
    let count = try scanner.requestArchive!.count
    check(count == 1 && scanner.ledger.entries.reduce(0) { $0 + $1.tokens.total } == original.tokens.total,
          "Cost recovery settles admitted detail and preserves original counters")
    check(!scanner.needsSave && scanner.ledger.eventIDs?.isEmpty == true, "Recovery publishes through checkpoint owner")
    scanner.checkpointWillRun = { if $0 == .index { throw RequestArchive.failure("Synthetic recovery index failure") } }
    do { _ = try scanner.recoverCostDetails(); preconditionFailure("Expected recovered-ledger checkpoint failure") } catch {}
    let recoveryWrites = scanner.persistenceCount
    scanner.checkpointWillRun = nil
    try scanner.saveIfNeeded(force: true)
    check(scanner.persistenceCount == recoveryWrites && !scanner.needsSave, "Recovered durable metadata retries without re-encoding")
}
print("PASS: cost recovery settles pending checkpoint and persists recovered metadata through retryable phases")
