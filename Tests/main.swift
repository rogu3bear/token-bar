import Foundation
import SQLite3

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let scanner = UsageScanner(home: temp, stateURL: temp.appendingPathComponent("state.json"))
let now = Date(), iso = ISO8601DateFormatter()
func event(_ input: Int, _ output: Int, lastInput: Int, lastOutput: Int, at date: Date = now) -> Data {
    let raw: [String: Any] = ["timestamp": iso.string(from: date), "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": input / 2, "output_tokens": output], "last_token_usage": ["input_tokens": lastInput, "cached_input_tokens": lastInput / 2, "output_tokens": lastOutput]]]]
    return try! JSONSerialization.data(withJSONObject: raw)
}
var cursor = Cursor()
scanner.consume(event(1000, 100, lastInput: 100, lastOutput: 10), session: "fork", cursor: &cursor, account: nil, poll: now)
assert(scanner.ledger.entries.count == 1 && scanner.ledger.entries[0].tokens.total == 110, "Do not bill inherited fork counters")
scanner.consume(event(1000, 100, lastInput: 100, lastOutput: 10), session: "fork", cursor: &cursor, account: nil, poll: now)
assert(scanner.ledger.entries.count == 1, "Repeated snapshots must not count twice")
scanner.consume(event(1200, 120, lastInput: 200, lastOutput: 20), session: "fork", cursor: &cursor, account: nil, poll: now)
assert(scanner.ledger.entries.last!.tokens.total == 220)
assert(scanner.ledger.entries.last!.tokens.cached == 100, "Cache subset should remain separate")
scanner.consume(event(30, 4, lastInput: 30, lastOutput: 4), session: "fork", cursor: &cursor, account: nil, poll: now)
assert(scanner.ledger.entries.last!.tokens.total == 34, "Counter reset must admit only the last request")
let account = Account(id: "test-id", label: "Test")
scanner.ledger.lastPoll = now.addingTimeInterval(-10); scanner.ledger.lastAccount = account
scanner.consume(event(70, 8, lastInput: 40, lastOutput: 4), session: "fork", cursor: &cursor, account: account, poll: now.addingTimeInterval(1))
assert(scanner.ledger.entries.last!.account == account)
scanner.consume(event(90, 10, lastInput: 20, lastOutput: 2), session: "fork", cursor: &cursor, account: Account(id: "other", label: "Other"), poll: now.addingTimeInterval(1))
assert(scanner.ledger.entries.last!.account == nil, "Switching accounts must not assign ambiguous usage")
scanner.ledger.lastPoll = now.addingTimeInterval(-120)
scanner.consume(event(100, 12, lastInput: 10, lastOutput: 2), session: "fork", cursor: &cursor, account: account, poll: now)
assert(scanner.ledger.entries.last!.account == nil, "Downtime is not continuous account observation")
let logs = temp.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
let log = logs.appendingPathComponent("test.jsonl")
let bytes = event(100, 10, lastInput: 100, lastOutput: 10)
try bytes.write(to: log)
let first = scanner.scan().entries.count
try (bytes + Data([10])).write(to: log)
assert(scanner.scan().entries.count == first + 1, "Partial final line is retried once completed")
assert(scanner.scan().entries.count == first + 1, "Incremental scan must not recount")
let resumed = UsageScanner(home: temp, stateURL: temp.appendingPathComponent("state.json"))
assert(resumed.scan().entries.count == first + 1, "Restart must preserve cursors and totals")
print("PASS: fork baseline, duplicate snapshots, deltas, cache subset, reset, account observation, account switch, partial line, incremental scan, restart")

try Data("invalid".utf8).write(to: temp.appendingPathComponent("broken.json"))
let broken = UsageScanner(home: temp, stateURL: temp.appendingPathComponent("broken.json"))
assert(broken.scan().error != nil)
let preserved = try String(contentsOf: temp.appendingPathComponent("broken.json"), encoding: .utf8)
assert(preserved == "invalid")
print("PASS: downtime attribution and corrupt-ledger preservation")

let oldDate = Calendar.current.date(byAdding: .day, value: -3, to: now)!
let oldLog = logs.appendingPathComponent("old.jsonl")
let oldEvent = event(2000, 100, lastInput: 100, lastOutput: 10, at: oldDate)
try (oldEvent + Data([10])).write(to: oldLog)
let beforeHistory = scanner.scan().entries
var importProgress: [(Int, Int)] = []
let imported = scanner.scan(historical: true, progress: { importProgress.append(($0, $1)) })
assert(importProgress.first?.0 == 0)
assert(importProgress.last?.0 == importProgress.last?.1 && importProgress.last!.1 > 0)
assert(importProgress.allSatisfy { $0.0 <= $0.1 })
assert(imported.entries.count == beforeHistory.count + 1, "Import must include records older than tracking start")
assert(imported.entries.last!.tokens.total == 110 && imported.entries.last!.account == nil)
assert(scanner.scan(historical: true).entries.count == imported.entries.count, "Reimport must be idempotent")
let archive = temp.appendingPathComponent("archived_sessions")
try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
try FileManager.default.moveItem(at: oldLog, to: archive.appendingPathComponent("old.jsonl"))
assert(scanner.scan(historical: true).entries.count == imported.entries.count, "Archive moves must not duplicate history")
assert(scanner.scan().entries.count == imported.entries.count, "Live scan must not recount imported records")
assert(scanner.ledger.entries.prefix(beforeHistory.count).map(\.account) == beforeHistory.map(\.account), "Preserve existing account observations")
print("PASS: historical import, repeat import, archive move, history/live boundary, existing observations")

let sample = [Entry(date: oldDate, session: "one", model: "A", tokens: Tokens(["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10]), account: nil),
              Entry(date: now, session: "two", model: "B", tokens: Tokens(["input_tokens": 200, "output_tokens": 20]), account: account)]
let catalog = ["one": TaskInfo(title: "Historical task", directory: "/sample/project")]
let all = UsageReport.build(entries: sample, query: UsageQuery(period: 1), catalog: catalog, now: now)
assert(all.totals.total == 330 && all.totals.cached == 80 && all.days.count == 2)
assert(UsageReport.build(entries: sample, query: UsageQuery(period: 0), catalog: catalog, now: now).totals.total == 220)
assert(UsageReport.build(entries: sample, query: UsageQuery(period: 2), catalog: catalog, now: now).totals.total == 330)
assert(UsageReport.build(entries: sample, query: UsageQuery(period: 4, start: oldDate, end: oldDate), catalog: catalog, now: now).totals.total == 110)
assert(UsageReport.build(entries: sample, query: UsageQuery(period: 1, model: "A", account: "Unattributed", search: "Historical"), catalog: catalog, now: now).totals.total == 110)
assert(UsageReport.build(entries: sample, query: UsageQuery(period: 1, account: account.id), catalog: catalog, now: now).totals.total == 220)
assert(UsageReport.build(entries: sample, query: UsageQuery(period: 4, start: now, end: oldDate), catalog: catalog, now: now).entries.isEmpty)
print("PASS: aggregation, cache subset, today/week/custom dates, combined model/account/task filter, reversed dates")

let dedup = UsageScanner(home: temp, stateURL: temp.appendingPathComponent("dedup.json"))
var originalCursor = Cursor(); originalCursor.turnID = "logical-turn"
var copyCursor = Cursor(); copyCursor.turnID = "logical-turn"
dedup.consume(event(1000, 100, lastInput: 100, lastOutput: 10), session: "original", cursor: &originalCursor, account: nil, poll: now)
dedup.consume(event(1000, 100, lastInput: 0, lastOutput: 0, at: now.addingTimeInterval(10)), session: "copy", cursor: &copyCursor, account: nil, poll: now)
assert(dedup.ledger.entries.count == 1, "Copied turn with shifted timestamp and different last-usage must not count again")
dedup.consume(event(1200, 120, lastInput: 200, lastOutput: 20, at: now.addingTimeInterval(20)), session: "copy", cursor: &copyCursor, account: nil, poll: now)
assert(dedup.ledger.entries.last!.tokens.total == 220, "Copied baseline still advances before fresh usage")
assert(dedup.ledger.duplicateEvents == 1)
print("PASS: shifted fork timestamps, stable turn/counter deduplication, fresh fork delta")

let firstQuota = QuotaReading(accountID: "a", bucket: "codex", name: "Codex", window: "primary", minutes: 10080, used: 10, reset: now.addingTimeInterval(86400), date: now.addingTimeInterval(-120))
var quota = firstQuota; quota.date = now; quota.used = 12
let prediction = Runway.estimate(quota, samples: [firstQuota, quota], now: now)
assert(abs(prediction.percentPerHour! - 60) < 0.001)
assert(abs(prediction.exhaustion!.timeIntervalSince(now) - 5280) < 0.001)
var otherAccount = firstQuota; otherAccount.accountID = "b"
assert(Runway.estimate(quota, samples: [otherAccount, quota], now: now).exhaustion == nil)
var resetSoon = quota; resetSoon.reset = now.addingTimeInterval(3600)
var earlierSameReset = firstQuota; earlierSameReset.reset = resetSoon.reset
assert(Runway.estimate(resetSoon, samples: [earlierSameReset, resetSoon], now: now).message == "Resets before projected exhaustion")
assert(Runway.estimate(quota, samples: [firstQuota, quota], now: now.addingTimeInterval(121)).exhaustion == nil)
var flat = firstQuota; flat.date = now
assert(Runway.estimate(flat, samples: [firstQuota, flat], now: now).exhaustion == nil)
var reset = quota; reset.used = 1
assert(Runway.estimate(reset, samples: [firstQuota, reset], now: now).exhaustion == nil)
let pace = LocalPace.measure(sample, now: now)
assert(abs(pace.tokensPerSecond - 20.0 / 60) < 0.001 && pace.tasks == 1)
assert(LocalPace.measure(sample, now: now.addingTimeInterval(61)).latest == nil)
print("PASS: quota slope, account separation, reset boundary, stale quota, flat quota, manual reset, live output rate and stale activity")

var requiresIndex = Ledger(); requiresIndex.eventIndexReady = true
requiresIndex.entries = [Entry(date: now.addingTimeInterval(-3 * 86400), session: "preserved", model: "unknown", tokens: Tokens(["input_tokens": 1]), account: nil)]
let missingIndexURL = temp.appendingPathComponent("missing-index.json")
let originalState = try JSONEncoder().encode(requiresIndex)
try originalState.write(to: missingIndexURL)
let missingIndex = UsageScanner(home: temp, stateURL: missingIndexURL)
assert(missingIndex.scan().error != nil)
assert(missingIndex.needsSave, "Initialization compaction makes this a genuine dirty final-flush case")
do { try missingIndex.saveIfNeeded(force: true); assertionFailure("Missing index must refuse final flush") } catch {}
let retainedState = try Data(contentsOf: missingIndexURL)
assert(retainedState == originalState, "Missing identity index must preserve the ledger")
print("PASS: missing committed identity index fails closed without rewriting history")

let brokenLiveURL = temp.appendingPathComponent("broken-live.json")
try Data("invalid".utf8).write(to: brokenLiveURL)
let brokenLive = LiveMonitor(home: temp, stateURL: brokenLiveURL)
brokenLive.refresh()
assert(brokenLive.error != nil)
let liveRetained = try String(contentsOf: brokenLiveURL, encoding: .utf8)
assert(liveRetained == "invalid")
print("PASS: corrupt account observation history is preserved without provider calls")

func life(_ type: String, _ turn: String, _ date: Date) -> [String: Any] {
    ["type": "event_msg", "timestamp": iso.string(from: date), "payload": ["type": type, "turn_id": turn]]
}
func liveTokens(_ output: Int, _ date: Date) -> [String: Any] {
    ["type": "event_msg", "timestamp": iso.string(from: date), "payload": ["type": "token_count", "info": ["total_token_usage": ["output_tokens": output]]]]
}
let meter = Tachometer()
let liveReader = ActivityReader()
let start = Date().addingTimeInterval(-60)
liveReader.consume(life("task_started", "live-turn", start), observed: start, kind: .chat, session: "live")
liveReader.consume(liveTokens(100, start), observed: start, session: "live")
assert(liveReader.snapshot.measurements.isEmpty, "A single counter needs an interval baseline")
liveReader.consume(liveTokens(400, start.addingTimeInterval(10)), observed: start.addingTimeInterval(10), session: "live")
meter.apply(liveReader.snapshot); meter.tick(now: start.addingTimeInterval(11))
assert(meter.rawRate == 30 && meter.hasRate)
meter.tick(now: start.addingTimeInterval(20))
assert(meter.rawRate == 30, "A reporting gap must retain its dated measurement")
liveReader.consume(liveTokens(400, start.addingTimeInterval(11)), observed: start.addingTimeInterval(11), session: "live")
liveReader.consume(liveTokens(700, start.addingTimeInterval(20)), observed: start.addingTimeInterval(20), session: "live")
assert(liveReader.snapshot.measurements["live"]?.rate == 30, "Duplicate counters must not shorten the measurement interval")
meter.tick(now: start.addingTimeInterval(41))
assert(!meter.hasRate && meter.rawRate == 0, "Expired measurements must display unavailable")
liveReader.consume(life("task_complete", "live-turn", start.addingTimeInterval(21)), observed: start.addingTimeInterval(21), session: "live")
meter.apply(liveReader.snapshot); meter.tick(now: start.addingTimeInterval(22))
assert(!meter.hasRate && meter.rawRate == 0, "Completed work must stop contributing immediately")
let activity = ActivityReader()
activity.consume(life("task_started", "turn-one", now), observed: now)
activity.consume(life("task_complete", "turn-one", now.addingTimeInterval(10)), observed: now)
activity.consume(life("task_started", "turn-one", now), observed: now)
assert(activity.snapshot.turns["turn-one"]?.running == false, "Copied start must not revive a completed turn")
activity.consume(life("task_started", "turn-two", now), observed: now, session: "same-chat")
activity.consume(life("task_started", "turn-three", now.addingTimeInterval(1)), observed: now, session: "same-chat")
assert(activity.snapshot.turns["turn-two"] == nil, "Only the newest turn in a chat is counted")
activity.consume(life("turn_aborted", "turn-three", now.addingTimeInterval(2)), observed: now, session: "same-chat")
assert(activity.snapshot.turns["turn-three"]?.running == false)
var urgent = quota; urgent.bucket = "urgent"; urgent.used = 98
var urgentFirst = firstQuota; urgentFirst.bucket = "urgent"; urgentFirst.used = 96
assert(Runway.priority([quota, urgent], samples: [firstQuota, quota, urgentFirst, urgent], now: now)?.bucket == "urgent")
assert(Runway.priority([quota], samples: [], now: now.addingTimeInterval(121)) == nil)
let sinceSignIn = UsageQuery(period: 5, start: now.addingTimeInterval(1))
let oldEntry = Entry(date: now, session: "history", model: "test", tokens: Tokens())
assert(!sinceSignIn.includes(oldEntry, catalog: [:], now: now.addingTimeInterval(10)))
let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
assert(Runway.clockLabel(tomorrow, now: now).hasPrefix("Tomorrow ≈ "))
assert(Runway.clockLabel(now.addingTimeInterval(600), now: now).contains("≈ "))
assert(Runway.clockLabel(now, now: now) == "Now")
print("PASS: interval rates, duplicate counters, held/stale measurements, immediate completion, latest-turn count, interruption, quota priority and approximate clock time")

let timelineHome = temp.appendingPathComponent("timeline-home")
try FileManager.default.createDirectory(at: timelineHome, withIntermediateDirectories: true)
let timelineFile = temp.appendingPathComponent("sign-ins.json")
let timeline = SignInTimeline(home: timelineHome, file: timelineFile)
timeline.observe(start: true)
timeline.observe()
assert(timeline.observations.count == 1, "Unchanged credential observation must not duplicate a switch")
let reloadedTimeline = SignInTimeline(home: timelineHome, file: timelineFile)
assert(reloadedTimeline.observations.count == 1)
reloadedTimeline.observe(start: true)
assert(reloadedTimeline.observations.count == 2, "A monitor restart must disclose the observation gap")
print("PASS: sign-in timeline persistence, repeated notification suppression, restart gap")

assert(ActivityKind.classify(["source": "vscode"]) == .chat)
assert(ActivityKind.classify(["source": "cli"]) == .chat)
assert(ActivityKind.classify(["source": ["subagent": ["thread_spawn": ["depth": 2]]]]) == .agent)
assert(ActivityKind.classify(["source": "future-source"]) == .unknown)
let categorized = ActivityReader()
let liveNow = Date()
categorized.consume(life("task_started", "chat", liveNow), observed: liveNow, kind: .chat)
categorized.consume(life("task_started", "agent", liveNow), observed: liveNow, kind: .agent)
categorized.consume(life("task_started", "unknown", liveNow), observed: liveNow)
assert(categorized.snapshot.chatCount == 1 && categorized.snapshot.agentCount == 1 && categorized.snapshot.unknownCount == 1)
categorized.consume(life("task_complete", "agent", liveNow.addingTimeInterval(1)), observed: liveNow)
assert(categorized.snapshot.agentCount == 0 && categorized.snapshot.chatCount == 1)
print("PASS: chat/agent metadata, nested agents, unknown origins, independently completed agent")

let longLog = temp.appendingPathComponent("long-live.jsonl")
func jsonLine(_ root: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) + Data([10]) }
// Use production ordering, where the root type and payload type occur near the start.
func orderedLine(_ root: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: root["payload"]!)
    let stamp = root["timestamp"] as! String
    return Data(("{\"timestamp\":\"" + stamp + "\",\"type\":\"event_msg\",\"payload\":").utf8) + payload + Data("}\n".utf8)
}
var longBytes = try jsonLine(["type": "session_meta", "payload": ["source": ["subagent": "copy"]]])
longBytes += try orderedLine(life("task_started", "long-turn", start))
longBytes += try orderedLine(liveTokens(100, start.addingTimeInterval(10)))
longBytes += Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 1_500_000) + "\"}\n").utf8)
longBytes += try orderedLine(liveTokens(400, start.addingTimeInterval(20)))
try longBytes.write(to: longLog)
let recovered = ActivityReader()
recovered.read(longLog, modified: Date(), size: UInt64(longBytes.count), session: "catalog-chat", kind: .chat)
assert(recovered.bootstrapPeakBuffer <= 262_144, "Backward search window stays bounded beyond 1 MB")
assert(recovered.snapshot.chatCount == 1 && recovered.snapshot.agentCount == 0, "Catalog identity must override inherited header source")
assert(recovered.snapshot.measurements["catalog-chat"]?.rate == 30, "Bootstrap must recover start and baseline beyond 1 MB")
let ending = try orderedLine(life("task_complete", "long-turn", Date()))
let longHandle = try FileHandle(forWritingTo: longLog); try longHandle.seekToEnd(); try longHandle.write(contentsOf: ending); try longHandle.close()
recovered.read(longLog, modified: Date(), size: UInt64(longBytes.count + ending.count), session: "catalog-chat", kind: .chat)
assert(recovered.snapshot.running.isEmpty && recovered.snapshot.freshMeasurements(at: Date()).isEmpty)
let copied = ActivityReader()
var inherited = life("task_started", "inherited", Date())
var inheritedPayload = inherited["payload"] as! [String: Any]; inheritedPayload["started_at"] = start.timeIntervalSince1970; inherited["payload"] = inheritedPayload
copied.consume(inherited, observed: Date(), kind: .agent, session: "new-fork", created: Date().addingTimeInterval(-10))
assert(copied.snapshot.running.isEmpty, "A shifted copied start predating fork creation is not new agent work")
print("PASS: long-turn bootstrap, immediate rate seed, canonical catalog identity, append completion, inherited-turn rejection")

assert(RateUnit.minute.multiplier * 12 == 720)
assert(RateUnit.hour.multiplier * 12 == 43200)
let narrowBounds = RateBounds.fitting([95, 100, 105])
assert(narrowBounds.lower > 0 && narrowBounds.lower < 95 && narrowBounds.upper > 105)
let broadBounds = RateBounds.fitting([2, 5000])
assert(broadBounds.lower == 0 && broadBounds.upper >= 5000)
assert(RateBounds.fitting([]) == RateBounds(lower: 0, upper: 100))
assert(RateBounds.fitting([10]).upper < narrowBounds.upper)
print("PASS: second/minute/hour conversion, adaptive lower and upper bounds, expansion, contraction, idle range")

assert(RateDisplay.compact(128 * RateUnit.minute.multiplier) == "7.7k")
assert(RateDisplay.compact(128 * RateUnit.hour.multiplier) == "460.8k")
assert(RateDisplay.compact(1000) == "1k")
assert(RateDisplay.compact(999_950) == "1M")
print("PASS: compact minute/hour rate labels and million boundary")

do {
    let now = Date()
    let legacy = Data("{\"accounts\":{},\"samples\":[],\"plans\":[]}".utf8)
    let legacyState = try JSONDecoder().decode(LiveState.self, from: legacy)
    assert(legacyState.quotaHistory == nil)
    let first = QuotaReading(accountID: "a", bucket: "codex", name: "Codex", window: "primary", minutes: 10080, used: 10, reset: now.addingTimeInterval(86400), date: now)
    var soon = first; soon.date = now.addingTimeInterval(30); soon.used = 11
    assert(QuotaHistory.recording([soon], in: [first], now: soon.date).count == 1)
    var later = soon; later.date = now.addingTimeInterval(300)
    assert(QuotaHistory.recording([later], in: [first], now: later.date).count == 2)
    var reset = soon; reset.reset = now.addingTimeInterval(172800); reset.used = 0
    assert(QuotaHistory.recording([reset], in: [first], now: reset.date).count == 2)
    var other = soon; other.accountID = "b"
    assert(QuotaHistory.recording([other], in: [first], now: other.date).count == 2)
    var stale = first; stale.date = now.addingTimeInterval(-91 * 86400)
    assert(QuotaHistory.recording([first], in: [stale], now: now).count == 1)
    var gap = later; gap.date = now.addingTimeInterval(1200)
    let plot = QuotaPlotPoint.build([first, first, later, gap, other], for: first.id)
    assert(plot.count == 3 && plot[0].segment == plot[1].segment && plot[2].segment != plot[1].segment)
    assert(QuotaPlotPoint.build([first, reset], for: first.id).last?.segment == 1)
    var state = LiveState(); state.quotaHistory = [first, later]
    let decoded = try JSONDecoder().decode(LiveState.self, from: JSONEncoder().encode(state))
    assert(decoded.quotaHistory?.count == 2)
}
print("PASS: quota-history migration, sampling, resets, account isolation, retention, plot gaps and persistence")

do {
    let now = Date(), calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let recent = Entry(date: today, session: "recent", model: "model-a", tokens: Tokens(["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 30, "reasoning_output_tokens": 10]))
    let previous = Entry(date: calendar.date(byAdding: .day, value: -8, to: today)!, session: "previous", model: "model-b", tokens: Tokens(["input_tokens": 200, "cached_input_tokens": 100, "output_tokens": 50]))
    let future = Entry(date: now.addingTimeInterval(3600), session: "future", model: "model-a", tokens: Tokens(["input_tokens": 9999]))
    let summary = UsageInsightsSummary.build(entries: [recent, previous, future], catalog: [:], now: now)
    assert(summary.recentOutput == 0 && summary.previousOutput == 50 && summary.activeDays == 2, "Today is excluded from complete-week comparisons")
    assert(summary.report.totals.total == 380)
    assert(summary.report.days.reduce(0) { $0 + $1.tokens.total } == 380)
    assert(summary.report.tasks.reduce(0) { $0 + $1.total } == 380)
    assert(summary.report.models.reduce(0) { $0 + $1.total } == 380)
    assert(summary.report.accounts.reduce(0) { $0 + $1.total } == 380)
    assert(summary.cacheShare == nil, "Counters without presence metadata cannot establish a cache ratio")
    var measured = recent; measured.tokenFields = ["input_tokens", "cached_input_tokens"]
    assert(UsageInsightsSummary.build(entries: [measured], catalog: [:], now: now).cacheShare == 0.8)
    var invalid = recent; invalid.tokens.cached = 101
    assert(UsageInsightsSummary.build(entries: [invalid], catalog: [:], now: now).cacheShare == nil)
}
print("PASS: usage insight windows, future exclusion, total reconciliation across every breakdown, cache subset validation")

do {
    let now = Date(), calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    func record(_ days: Int, _ output: Int) -> Entry {
        var entry = Entry(date: calendar.date(byAdding: .day, value: days, to: today)!,
                          session: "comparison", model: "synthetic", tokens: Tokens(["output_tokens": output]))
        entry.tokenFields = ["output_tokens"]
        return entry
    }
    func summary(_ entries: [Entry]) -> UsageInsightsSummary {
        UsageInsightsSummary.build(entries: entries, catalog: [:], now: now)
    }
    let prior = record(-14, 100), recent = record(-7, 150)
    let changed = summary([prior, recent, record(0, 999), record(1, 999), record(-15, 999)])
    assert(changed.outputChangePercent == 50)
    assert(changed.recentRecords == 1 && changed.previousRecords == 1)
    assert(summary([prior, record(-1, 50)]).outputChangePercent == -50)
    assert(summary([prior, record(-1, 100)]).outputChangePercent == 0)
    assert(summary([prior, record(-1, 0)]).outputChangePercent == -100, "Explicit zero differs from missing evidence")
    assert(summary([prior]).outputChangePercent == nil)
    assert(summary([recent]).outputChangePercent == nil)
    assert(summary([]).outputChangePercent == nil)
    assert(summary([record(-8, 0), recent]).outputChangePercent == nil, "No division by zero or invented baseline")
    var missing = recent; missing.tokenFields = ["input_tokens"]
    assert(summary([prior, missing]).comparisonMissingOutput == 1)
    assert(summary([prior, missing]).outputChangePercent == nil)
    assert(summary([prior, recent]).peakContext == nil)
}
print("PASS: insight change direction, calendar boundaries, explicit zero, missing periods and unknown counters")


// Single-day charts retain minute positions, including multiple records within a minute.
let minuteDay = Calendar.current.startOfDay(for: now)
let minuteNow = minuteDay.addingTimeInterval(3600)
var minuteEntries = [
    Entry(date: minuteDay.addingTimeInterval(60), session: "minute", model: "test", tokens: Tokens(["output_tokens": 3])),
    Entry(date: minuteDay.addingTimeInterval(90), session: "minute", model: "test", tokens: Tokens(["output_tokens": 4])),
    Entry(date: minuteDay.addingTimeInterval(180), session: "minute", model: "test", tokens: Tokens(["output_tokens": 5]))
]
let minuteReport = UsageReport.build(entries: minuteEntries, query: UsageQuery(), catalog: [:], now: minuteNow)
assert(minuteReport.timeline.minuteResolution && minuteReport.timeline.points.map(\.tokens.output) == [7, 12])
assert(minuteReport.timeline.points.map(\.date) == [minuteDay.addingTimeInterval(60), minuteDay.addingTimeInterval(180)])
var dailyOnly = minuteEntries[0]; dailyOnly.bucket = "day"; dailyOnly.date = minuteDay
let mixedTimeline = UsageTimeline.build(entries: minuteEntries + [dailyOnly], query: UsageQuery(), now: minuteNow)
assert(mixedTimeline.dailyOnly.output == 3 && mixedTimeline.points.last?.tokens.output == 12)
var grokToday = minuteEntries[0]; grokToday.harness = Harness.grok
var codexToday = minuteEntries[1]; codexToday.harness = "codex-desktop"
let packed = UsageTimeline.compact(entries: [grokToday, codexToday], now: minuteNow)
assert(packed.tools.map(\.tool) == [.codex, .grok])
assert(UsageTimeline.compact(entries: [], now: minuteNow).timeline.points.isEmpty)
// The compact consumer must not aggregate history on its one-second clock.
do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = calendar.startOfDay(for: minuteNow)
    let clock = day.addingTimeInterval(3600)
    var past = grokToday; past.date = day.addingTimeInterval(30)
    var future = codexToday; future.date = clock.addingTimeInterval(60)
    var daily = dailyOnly; daily.date = day
    var history = past; history.date = day.addingTimeInterval(-3600)
    let entries = Array(repeating: history, count: 107_673) + [past, daily, future]
    var cache = CompactUsageCache()
    let initial = cache.update(entries: entries, revision: 1, now: clock, calendar: calendar)!
    assert(initial.timeline.points.last?.tokens.output == past.tokens.output)
    assert(initial.timeline.dailyOnly.output == daily.tokens.output)
    for tick in 1..<60 {
        assert(cache.update(entries: entries, revision: 1, now: clock.addingTimeInterval(Double(tick)), calendar: calendar) == nil)
    }
    assert(cache.rebuildCount == 1, "Unchanged ticks never filter or rebuild 107673 historical entries")
    let reached = cache.update(entries: entries, revision: 1, now: future.date, calendar: calendar)!
    assert(reached.tools.contains { $0.tool == .codex }, "Inclusive future timestamp becomes visible exactly when reached")
    let backwards = cache.update(entries: entries, revision: 1, now: clock, calendar: calendar)!
    assert(!backwards.tools.contains { $0.tool == .codex }, "Clock rollback removes future records")
    let changed = cache.update(entries: [past], revision: 2, now: clock, calendar: calendar)!
    assert(changed.timeline.dailyOnly.total == 0, "Data replacement invalidates the prepared chart")
    let midnight = cache.update(entries: [past], revision: 2, now: day.addingTimeInterval(86400), calendar: calendar)!
    assert(midnight.timeline.points.isEmpty && midnight.tools.isEmpty, "Midnight never carries yesterday into an empty today")
    calendar.timeZone = TimeZone(secondsFromGMT: -3600)!
    assert(cache.update(entries: [past], revision: 2, now: day.addingTimeInterval(86400), calendar: calendar) != nil,
           "Calendar/time-zone changes invalidate even without a clock or revision change")
    let store = UsageStore(scanner: resumed, referenceDate: minuteNow)
    store.snapshot = Snapshot(entries: [grokToday])
    assert(store.compactUsage.tools.first?.tool == .grok)
    store.updateCompactUsage(now: minuteNow.addingTimeInterval(86400))
    assert(store.compactUsage.tools.first?.tool == .grok, "Preview clock remains fixed")
    store.snapshot = Snapshot(entries: [codexToday])
    assert(store.compactUsage.tools.first?.tool == .codex, "Snapshot publication updates the prepared consumer")
}
print("PASS: compact history cache skips clock-only work and handles data, midnight, future, rollback and time-zone boundaries")
var futureMinute = minuteEntries[0]; futureMinute.date = minuteNow.addingTimeInterval(60)
assert(UsageReport.build(entries: minuteEntries + [futureMinute], query: UsageQuery(), catalog: [:], now: minuteNow).totals.output == 12)
let chosenDay = UsageQuery(period: 4, start: minuteDay, end: minuteDay)
assert(UsageReport.build(entries: minuteEntries, query: chosenDay, catalog: [:], now: minuteNow).timeline.minuteResolution)
let minuteArchive = try RequestArchive(url: temp.appendingPathComponent("minute-archive.sqlite"))
for index in minuteEntries.indices {
    minuteEntries[index].recordID = "minute-\(index)"
    try minuteArchive.record(minuteEntries[index], admitted: true)
}
var dayAggregate = minuteEntries[0]
dayAggregate.date = minuteDay; dayAggregate.bucket = "day"; dayAggregate.recordID = nil
dayAggregate.tokens = Tokens(["output_tokens": 12]); dayAggregate.sampleCount = 3
let expandedMinutes = try TimelineDetail.expand([dayAggregate], archive: minuteArchive)
assert(expandedMinutes.count == 3 && expandedMinutes.allSatisfy { $0.bucket == nil })
assert(expandedMinutes.reduce(0) { $0 + $1.tokens.output } == 12)
var unmatchedDay = dayAggregate; unmatchedDay.tokens.output += 1
let unmatchedMinutes = try TimelineDetail.expand([unmatchedDay], archive: minuteArchive)
assert(unmatchedMinutes.first?.bucket == "day")
let restoredSnapshot = resumed.currentSnapshot()
assert(restoredSnapshot.entries.count == resumed.ledger.entries.count && !restoredSnapshot.entries.isEmpty)
var duringAdmission: Snapshot?
resumed.onSnapshot = { duringAdmission = $0 }
var streamedCursor = Cursor()
resumed.consume(event(123, 17, lastInput: 123, lastOutput: 17), session: "streamed", cursor: &streamedCursor, account: nil, poll: now)
assert(duringAdmission?.entries.last?.session == "streamed", "Publish admitted data before the complete scan returns")
print("PASS: minute grouping, cumulative points, future exclusion, daily-only disclosure, exact archive expansion, cached snapshot and progressive admission")

resumed.loadError = "Synthetic unavailable index"
let unavailableScan = resumed.scan()
assert(unavailableScan.entries.count == resumed.ledger.entries.count && unavailableScan.error != nil,
       "A failed refresh must retain readable cached usage rather than publish an empty result")
resumed.loadError = nil
print("PASS: scan failure preserves the saved-data snapshot and exposes its error")

let availabilityTrends = UsageInsightsModel()
availabilityTrends.refresh(entries: [], catalog: [:], sourceAvailable: false)
assert(availabilityTrends.sourceUnavailable && !availabilityTrends.hasResult)
availabilityTrends.refresh(entries: [], catalog: [:])
let trendDeadline = Date().addingTimeInterval(5)
while availabilityTrends.busy && Date() < trendDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
assert(availabilityTrends.hasResult && !availabilityTrends.sourceUnavailable && availabilityTrends.summary.recentOutput == 0)
availabilityTrends.refresh(entries: [], catalog: [:], sourceAvailable: false)
assert(availabilityTrends.hasResult && availabilityTrends.sourceUnavailable)
print("PASS: usage trends distinguish unavailable input from completed zero and preserve prior summary")


var historicalCodex = Entry(date: now.addingTimeInterval(-86400), session: "codex-history", model: "sample", tokens: Tokens(["input_tokens": 200, "output_tokens": 100]))
historicalCodex.harness = "Codex Desktop"
var historicalClaude = Entry(date: now.addingTimeInterval(-172800), session: "claude-history", model: "sample", tokens: Tokens(["input_tokens": 400, "output_tokens": 300]))
historicalClaude.harness = "Claude Code"
var unknownTool = historicalClaude; unknownTool.harness = nil
let historicalTools = UsageReport.build(entries: [historicalCodex, historicalClaude, unknownTool], query: UsageQuery(period: 1), catalog: [:], now: now)
assert(historicalTools.toolTimelines.count == 3)
assert(historicalTools.toolTimelines.reduce(Tokens()) { $0 + $1.totals } == historicalTools.totals)
assert(historicalTools.toolTimelines.allSatisfy { !$0.timeline.minuteResolution }, "Tool subsets must share the whole report's daily resolution")
assert(historicalTools.toolTimelines.first { $0.tool == .claude }?.totals.output == 300)
var claudeOnly = UsageQuery(period: 1); claudeOnly.harness = "Claude Code"
let filteredTools = UsageReport.build(entries: [historicalCodex, historicalClaude, unknownTool], query: claudeOnly, catalog: [:], now: now)
assert(filteredTools.toolTimelines.count == 1 && filteredTools.toolTimelines[0].tool == .claude)
assert(filteredTools.totals == historicalClaude.tokens && filteredTools.entries.count == 1)
assert(filteredTools.toolTimelines[0].timeline.minuteResolution == filteredTools.timeline.minuteResolution)
print("PASS: inactive Claude history is included, tool totals reconcile, unknown identity stays separate and filtered series share report resolution")

let rememberedTrends = UsageInsightsModel()
func finishTrends() {
    let deadline = Date().addingTimeInterval(5)
    while rememberedTrends.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    assert(!rememberedTrends.busy)
}
rememberedTrends.refresh(entries: [], catalog: [:]); finishTrends()
let evaluation = rememberedTrends.evaluatedAt
rememberedTrends.refresh(entries: [], catalog: [:])
assert(!rememberedTrends.busy && rememberedTrends.evaluatedAt == evaluation)
let trendEntry = Entry(date: Date().addingTimeInterval(-86400), session: "remembered", model: "test", tokens: Tokens(["output_tokens": 17]))
rememberedTrends.refresh(entries: [trendEntry], catalog: [:])
rememberedTrends.refresh(entries: [], catalog: [:], sourceAvailable: false)
finishTrends()
assert(rememberedTrends.sourceUnavailable && rememberedTrends.summary.report.entries.isEmpty)
rememberedTrends.refresh(entries: [trendEntry], catalog: [:]); finishTrends()
assert(rememberedTrends.summary.report.totals.output == 17)
rememberedTrends.refresh(entries: [], catalog: [:])
rememberedTrends.refresh(entries: [trendEntry], catalog: [:])
finishTrends()
assert(rememberedTrends.summary.report.totals.output == 17)
print("PASS: insights reuse unchanged input, reject publication after source failure, and coalesce obsolete requests")

do {
    let now = Date()
    var revision = Entry(date: now, session: "revision", model: "model", tokens: Tokens(["input_tokens": 10, "output_tokens": 5]))
    revision.bucket = "revision"; revision.sampleCount = 0; revision.projectPath = "/tmp/foreign-project"
    let timeline = UsageTimeline.build(entries: [revision], query: UsageQuery(), now: now, minuteResolution: true)
    assert(timeline.dailyOnly.total == 0 && timeline.points.last?.tokens.total == 15)
    assert(UsageQuery(search: "foreign-project").includes(revision, catalog: [:], now: now))
    revision.model = "=synthetic-label"
    assert(UsageReport.build(entries: [revision], query: UsageQuery(), catalog: [:], now: now).csv().contains(RequestExport.quote(revision.model)))
}
print("PASS: revision timing, foreign project search and consistent CSV text protection")

// Synthetic evaluation clocks use the same activity freshness boundary.
do {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    var snapshot = ActivitySnapshot(readAt: instant, referenceDate: instant)
    snapshot.turns["sample"] = TaskActivity(turn: "sample", started: instant, observed: instant,
        running: true, kind: .chat, session: "sample")
    assert(snapshot.chatCount == 1 && snapshot.uncertain == 0)
    assert(snapshot.filtered(for: .codex).referenceDate == instant)
    snapshot.referenceDate = instant.addingTimeInterval(300)
    assert(snapshot.running.isEmpty && snapshot.uncertain == 1)
    assert(ActivitySnapshot().referenceDate == nil, "Production snapshots retain the live clock")
}
print("PASS: isolated activity clock preserves fresh/unconfirmed boundary and tool filtering")

// A pending partial Codex line must not create a save on every timer poll.
do {
    let partialHome = temp.appendingPathComponent("idle-partial")
    let partialPath = partialHome.appendingPathComponent("sessions/partial.jsonl")
    try FileManager.default.createDirectory(at: partialPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"type\":\"event_msg\"".utf8).write(to: partialPath)
    let partialScanner = UsageScanner(home: partialHome, stateURL: partialHome.appendingPathComponent("state.json"))
    partialScanner.readAccount = false
    _ = partialScanner.scan()
    try partialScanner.saveIfNeeded(force: true)
    let writes = partialScanner.persistenceCount
    for _ in 0..<3 { _ = partialScanner.scan(); try partialScanner.saveIfNeeded(force: true) }
    assert(partialScanner.persistenceCount == writes && partialScanner.ledger.cursors.isEmpty)
}
print("PASS: incomplete Codex tail retains bytes without dirty persistence")

// The latest lifecycle line straddles the backward block boundary. A partial
// trailing lifecycle is not treated as complete until its newline arrives.
do {
    let splitPath = temp.appendingPathComponent("split-lifecycle.jsonl")
    let lifecycle = try orderedLine(life("task_started", "split-turn", Date()))
    let padding = Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 262_100) + "\"}\n").utf8)
    var split = lifecycle + padding
    let splitReader = ActivityReader()
    try split.write(to: splitPath)
    splitReader.read(splitPath, modified: Date(), size: UInt64(split.count), session: "split")
    assert(splitReader.snapshot.turns["split-turn"] != nil && splitReader.bootstrapPeakBuffer <= 262_144)
    let complete = try orderedLine(life("task_complete", "split-turn", Date()))
    split += complete.dropLast()
    try split.write(to: splitPath)
    let partialReader = ActivityReader()
    partialReader.read(splitPath, modified: Date(), size: UInt64(split.count), session: "split")
    assert(partialReader.snapshot.turns["split-turn"]?.running == true)
    split += Data([10]); try split.write(to: splitPath)
    partialReader.read(splitPath, modified: Date(), size: UInt64(split.count), session: "split")
    assert(partialReader.snapshot.turns["split-turn"]?.running == false)
    try Data("{}\n".utf8).write(to: splitPath)
    partialReader.read(splitPath, modified: Date(), size: 3, session: "split")
    assert(partialReader.snapshot.turns.isEmpty, "Truncation clears stale lifecycle")
}
print("PASS: bounded split-line lifecycle search, incomplete completion and truncation")

do {
    let corruptState = temp.appendingPathComponent("corrupt-index.json")
    try originalState.write(to: corruptState)
    let corruptIndex = corruptState.deletingPathExtension().appendingPathExtension("events.sqlite")
    try Data("not a SQLite database".utf8).write(to: corruptIndex)
    let corruptScanner = UsageScanner(home: temp, stateURL: corruptState)
    assert(corruptScanner.loadError != nil && corruptScanner.needsSave)
    do { try corruptScanner.saveIfNeeded(force: true); assertionFailure("Corrupt index must refuse final flush") } catch {}
    let bytes = try Data(contentsOf: corruptState)
    assert(bytes == originalState, "Corrupt index final flush preserves original ledger bytes")
}
print("PASS: missing/corrupt index final flush preserves dirty-initialization ledger bytes")

do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    let day = calendar.startOfDay(for: minuteNow)
    let end = day.addingTimeInterval(3600)
    let domain = CompactUsage.plotDomain(now: end, calendar: calendar)
    assert(domain.lowerBound == day.addingTimeInterval(60) && domain.upperBound == end)
    for second in [0.0, 30, 60] {
        let early = CompactUsage.plotDomain(now: day.addingTimeInterval(second), calendar: calendar)
        assert(early.lowerBound < early.upperBound && early.lowerBound == day)
    }
    let timeline = UsageTimeline(points: [DailyUsage(date: day.addingTimeInterval(180), tokens: Tokens(["output_tokens": 7]))], minuteResolution: true)
    let plotted = timeline.plotPoints(in: domain)
    assert(plotted.map(\.date) == [domain.lowerBound, day.addingTimeInterval(180), end])
    assert(plotted.map(\.tokens.output) == [0, 7, 7])
    assert(timeline.points.count == 1, "Endpoint extension must not alter recorded history")
    assert(UsageTimeline(minuteResolution: true).plotPoints(in: domain).isEmpty)
    let firstMinute = UsageTimeline(points: [DailyUsage(date: day, tokens: Tokens(["output_tokens": 5]))], minuteResolution: true)
    assert(firstMinute.plotPoints(in: domain).map(\.tokens.output) == [5, 5])
    var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
    assert(CompactUsage.plotDomain(now: end, calendar: utc).lowerBound != domain.lowerBound)
}
print("PASS: Today uses local 00:01-to-now extent, safe midnight bounds, and cumulative-only endpoints")

// Quota history is durable, but settled rows must not be rewritten on every read.
func verifySavedState(_ condition: Bool, _ message: String = "Saved state must match") { precondition(condition, message) }
do {
    let fixture = temp.appendingPathComponent("quota-store")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let legacyURL = fixture.appendingPathComponent("live-accounts.json")
    let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
    let start = now.addingTimeInterval(-30 * 22000)
    var state = LiveState()
    state.quotaHistory = (0..<22000).map { index in
        QuotaReading(accountID: "synthetic", bucket: "quota", name: "Synthetic quota", window: "primary", minutes: 300,
            used: Double(index % 100), reset: now.addingTimeInterval(3600), date: start.addingTimeInterval(Double(index * 30)))
    }
    state.quotaHistory!.append(state.quotaHistory!.last!) // Preserve even identical observations.
    state.samples = [state.quotaHistory!.last!]
    state.accounts["synthetic"] = LiveAccount(id: "synthetic", email: "synthetic@example.invalid", plan: "sample", observed: now, quotas: state.samples)
    state.plans = [LivePlan(id: "sample", accountID: "synthetic", email: "synthetic@example.invalid", plan: "sample", firstSeen: start, lastSeen: now)]
    let original = try canonical.encode(state)
    try original.write(to: legacyURL)
    var store: LiveStateStore? = LiveStateStore(legacyURL: legacyURL)
    let legacy = try store!.load()
    verifySavedState(try canonical.encode(legacy) == original)
    try store!.save(state)
    assert(store!.lastHistoryRowsWritten == 22001)
    let databaseURL = store!.databaseURL
    let permissions = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as! NSNumber
    assert(permissions.intValue == 0o600)
    verifySavedState(try Data(contentsOf: legacyURL) == original, "Migration must preserve the original JSON rollback evidence")
    store = nil
    store = LiveStateStore(legacyURL: legacyURL)
    let restarted = try store!.load()
    verifySavedState(try canonical.encode(restarted) == original, "Restart preserves metadata, order, duplicates and every reading")

    var database: OpaquePointer?
    assert(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    func sql(_ text: String) throws {
        guard sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    func count(_ sql: String) -> Int {
        var query: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK)
        defer { sqlite3_finalize(query) }
        precondition(sqlite3_step(query) == SQLITE_ROW)
        return Int(sqlite3_column_int64(query, 0))
    }
    try sql("CREATE TABLE write_audit(kind TEXT, position INTEGER); CREATE TRIGGER inserted AFTER INSERT ON quota_history BEGIN INSERT INTO write_audit VALUES ('insert',NEW.position); END; CREATE TRIGGER deleted AFTER DELETE ON quota_history BEGIN INSERT INTO write_audit VALUES ('delete',OLD.position); END")
    let newRows = (0..<4).map { index in
        QuotaReading(accountID: "synthetic", bucket: "quota", name: "Synthetic quota", window: "primary", minutes: 300,
            used: Double(index), reset: now.addingTimeInterval(7200), date: now.addingTimeInterval(Double(index)))
    }
    state.quotaHistory! += newRows; state.samples = newRows
    state.accounts["synthetic"]?.observed = now.addingTimeInterval(3)
    try store!.save(state)
    assert(store!.lastHistoryRowsWritten == 4 && store!.lastMetadataBytesWritten < 16000)
    assert(count("SELECT COUNT(*) FROM write_audit WHERE kind='insert'") == 4 && count("SELECT COUNT(*) FROM write_audit WHERE kind='delete'") == 0,
           "Actual SQLite writes append four rows without replacing settled history")
    try sql("DELETE FROM write_audit")
    try store!.save(state)
    assert(store!.lastHistoryRowsWritten == 0 && store!.lastMetadataBytesWritten == 0 && count("SELECT COUNT(*) FROM write_audit") == 0,
           "Identical refreshes perform no data writes")
    state.quotaHistory!.removeFirst(100)
    try store!.save(state)
    assert(store!.lastHistoryRowsWritten == 0 && count("SELECT COUNT(*) FROM write_audit WHERE kind='delete'") == 100 && count("SELECT COUNT(*) FROM write_audit WHERE kind='insert'") == 0,
           "Retention removes only expired rows")
    try sql("DELETE FROM write_audit")
    let accepted = state
    var pending = state
    pending.quotaHistory!.removeFirst(1)
    pending.quotaHistory!.append(newRows.last!)
    pending.accounts["synthetic"]?.plan = "changed"
    try sql("CREATE TRIGGER reject_history BEFORE INSERT ON quota_history BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
    do { try store!.save(pending); assertionFailure("A failed history insertion must refuse the transaction") } catch {}
    assert(count("SELECT COUNT(*) FROM write_audit") == 0, "The earlier retention deletion must roll back with the failed insertion")
    let afterFailure = try LiveStateStore(legacyURL: legacyURL).load()
    verifySavedState(try canonical.encode(afterFailure) == canonical.encode(accepted), "Failure cannot publish newer metadata with older or partial history")
    try sql("DROP TRIGGER reject_history")
    try store!.save(pending)
    let afterRetry = try LiveStateStore(legacyURL: legacyURL).load()
    verifySavedState(try canonical.encode(afterRetry) == canonical.encode(pending), "Retry uses the last committed baseline and preserves exact rows")
    verifySavedState(try Data(contentsOf: legacyURL) == original)
    try sql("DELETE FROM quota_history WHERE position=(SELECT MIN(position) FROM quota_history)")
    do { _ = try LiveStateStore(legacyURL: legacyURL).load(); assertionFailure("Missing committed rows must fail closed") } catch {}
    let failedMonitor = LiveMonitor(home: fixture, stateURL: legacyURL)
    failedMonitor.refresh()
    assert(failedMonitor.error != nil, "A corrupt new store cannot silently restore old legacy data or call the provider")
}
print("PASS: quota-store migration, 22001 retained rows, exact duplicate ordering, four-row appends, no-op saves, retention, transaction rollback/retry and corrupt-store refusal")

do {
    let fixture = temp.appendingPathComponent("quota-migration-failure")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let legacyURL = fixture.appendingPathComponent("live-accounts.json")
    let reading = QuotaReading(accountID: "synthetic", bucket: "quota", name: "Synthetic", window: "primary", minutes: 300, used: 3, reset: now.addingTimeInterval(3600), date: now)
    var legacy = LiveState(); legacy.samples = [reading]
    let original = try JSONEncoder().encode(legacy); try original.write(to: legacyURL)
    let store = LiveStateStore(legacyURL: legacyURL)
    _ = try store.load()
    var invalid = legacy; var bad = reading; bad.used = .nan
    invalid.quotaHistory = [reading, bad]
    do { try store.save(invalid); assertionFailure("Failed migration must not publish an authoritative store") } catch {}
    assert(!FileManager.default.fileExists(atPath: store.databaseURL.path))
    verifySavedState(try Data(contentsOf: legacyURL) == original)
    // A process that ended before publication can leave a private staging file.
    let interrupted = fixture.appendingPathComponent(".live-observations-interrupted.sqlite")
    try Data("incomplete".utf8).write(to: interrupted)
    let resumed = LiveStateStore(legacyURL: legacyURL)
    let recovered = try resumed.load()
    assert(recovered.samples == [reading] && recovered.quotaHistory == nil)
    try resumed.save(recovered)
    let complete = try LiveStateStore(legacyURL: legacyURL).load()
    assert(complete.quotaHistory == [reading] && complete.samples == [reading], "Legacy sample-only data is retained during migration")
    try Data("corrupt".utf8).write(to: store.databaseURL)
    do { _ = try LiveStateStore(legacyURL: legacyURL).load(); assertionFailure("Corrupt authoritative database must not fall back to older JSON") } catch {}
    verifySavedState(try Data(contentsOf: legacyURL) == original)
}
print("PASS: interrupted/failed migration retains legacy data; only a complete database becomes authoritative")

do {
    var clock = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
    let trends = UsageInsightsModel(clock: { clock })
    let rows = [Entry(date: clock.addingTimeInterval(-10), session: "lazy", model: "synthetic", tokens: Tokens(["output_tokens": 7]), account: nil)]
    func finish() {
        let deadline = Date().addingTimeInterval(3)
        while trends.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        assert(!trends.busy)
    }
    trends.refresh(entries: rows, catalog: [:]); finish()
    let first = trends.evaluatedAt
    clock = clock.addingTimeInterval(3600)
    trends.refresh(entries: rows, catalog: [:])
    assert(!trends.busy && trends.evaluatedAt == first, "Returning to Insights after an hour reuses unchanged saved inputs")
    clock = clock.addingTimeInterval(-3601)
    trends.refresh(entries: rows, catalog: [:]); finish()
    assert(trends.evaluatedAt == clock, "A backwards clock invalidates Insights")
    clock = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: clock))!
    trends.refresh(entries: rows, catalog: [:]); finish()
    assert(trends.evaluatedAt == clock, "Local midnight invalidates time-dependent trends")
}
print("PASS: Insights lazily reuses unchanged page results and refreshes at clock/day boundaries")

// Exercise file continuity at the ordinary scan boundary, never by replaying
// consume directly. All fixtures are disposable and contain no user content.
var continuityFailures: [String] = []
func continuityCheck(_ condition: Bool, _ message: String) {
    if !condition { continuityFailures.append(message); print("FAIL: Codex continuity: " + message) }
}
func continuityLine(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
}
func continuityMeta(_ session: String) -> Data {
    continuityLine(["type": "session_meta", "payload": ["id": session, "cwd": "/synthetic/" + session, "originator": "codex_cli_rs", "model_provider": "openai"]])
}
func continuityRecord(_ turn: String, _ total: Int, at date: Date, last: Int = 100) -> Data {
    continuityLine(["type": "turn_context", "payload": ["turn_id": turn, "model": "synthetic-model"]]) +
    continuityLine(["timestamp": iso.string(from: date), "type": "event_msg", "payload": ["type": "token_count", "info": [
        "total_token_usage": ["input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0],
        "last_token_usage": ["input_tokens": last, "cached_input_tokens": 0, "output_tokens": 0]]]])
}
func continuityPadding(_ count: Int) -> Data {
    continuityLine(["type": "response_item", "payload": ["content": String(repeating: "x", count: count)]])
}
for historical in [false, true] {
    for kind in ["smaller", "equal", "larger", "regrow", "partial", "legacy", "new-session"] {
        let fixture = temp.appendingPathComponent("continuity-\(historical)-\(kind)")
        let file = fixture.appendingPathComponent("sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = fixture.appendingPathComponent("ledger.json")
        let date = historical ? oldDate : now
        let a = continuityRecord("continuity-A", 100, at: date)
        let b = continuityRecord("continuity-B", 200, at: date)
        let c = continuityRecord("continuity-C", 300, at: date)
        let original = continuityMeta("original") + a + b + continuityPadding(3000)
        try original.write(to: file)
        var owner: UsageScanner? = UsageScanner(home: fixture, stateURL: state)
        owner!.readAccount = false
        _ = owner!.scan(historical: historical, changedPaths: [file])
        try owner!.saveIfNeeded(force: true)
        continuityCheck(owner!.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 200, "\(kind) valid original \(historical)")
        if kind == "legacy" {
            owner = nil
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
            for field in ["cursors", "historyCursors"] {
                if var cursors = json[field] as? [String: [String: Any]] {
                    for key in cursors.keys { cursors[key]?.removeValue(forKey: "continuity") }
                    json[field] = cursors
                }
            }
            try JSONSerialization.data(withJSONObject: json).write(to: state)
        }
        var replacement = continuityMeta("original") + a + c
        if kind == "new-session" { replacement = continuityMeta("different") + continuityRecord("new-session-C", 1000, at: date) }
        if kind == "equal" { replacement += continuityPadding(original.count - replacement.count - continuityPadding(0).count) }
        if kind == "larger" || kind == "regrow" { replacement += continuityPadding(5000) }
        if kind == "partial" { replacement.removeLast(25) }
        if kind == "regrow" {
            let writer = try FileHandle(forWritingTo: file)
            try writer.truncate(atOffset: 0); try writer.write(contentsOf: replacement); try writer.close()
        } else { try replacement.write(to: file, options: .atomic) }
        if owner == nil { owner = UsageScanner(home: fixture, stateURL: state); owner!.readAccount = false }
        _ = owner!.scan(historical: historical, changedPaths: [file])
        if kind == "partial" {
            continuityCheck(owner!.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 200, "partial waits for complete line \(historical)")
            let complete = continuityMeta("original") + a + c
            let writer = try FileHandle(forWritingTo: file)
            try writer.seekToEnd(); try writer.write(contentsOf: complete.suffix(25)); try writer.close()
            _ = owner!.scan(historical: historical, changedPaths: [file])
        }
        continuityCheck(owner!.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "\(kind) A100/B200 then A100/C300 must total300, not400; historical=\(historical), got \(owner!.ledger.entries.reduce(0) { $0 + $1.tokens.input })")
        try owner!.saveIfNeeded(force: true)
        owner = nil
        owner = UsageScanner(home: fixture, stateURL: state); owner!.readAccount = false
        _ = owner!.scan(historical: historical, changedPaths: [file])
        continuityCheck(owner!.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "\(kind) repeat/restart exactly300 \(historical)")
        owner = nil
    }
}

func continuityFixture(_ name: String, at date: Date = now) throws -> (UsageScanner, URL, URL) {
    let home = temp.appendingPathComponent("continuity-extra-" + name)
    let file = home.appendingPathComponent("sessions/rollout.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (continuityMeta("original") + continuityRecord("A", 100, at: date) + continuityRecord("B", 200, at: date)).write(to: file)
    let state = home.appendingPathComponent("ledger.json")
    let owner = UsageScanner(home: home, stateURL: state); owner.readAccount = false
    _ = owner.scan(historical: date == oldDate, changedPaths: [file]); try owner.saveIfNeeded(force: true)
    return (owner, file, state)
}
for historical in [false, true] {
    let date = historical ? oldDate : now
    let (owner, file, state) = try continuityFixture("overlap-\(historical)", at: date)
    let originalEntries = owner.ledger.entries
    let replacement = continuityMeta("original") + continuityRecord("A", 100, at: date) +
        continuityRecord("unseen-older", 150, at: date.addingTimeInterval(-1)) +
        continuityRecord("overlap", 250, at: date.addingTimeInterval(1))
    try replacement.write(to: file, options: .atomic)
    _ = owner.scan(historical: historical, changedPaths: [file])
    continuityCheck(owner.ledger.entries == originalEntries, "old or overlapping intervals never add100 atop200 \(historical)")
    continuityCheck(owner.currentSnapshot().error != nil || owner.ledger.sourceErrors?.isEmpty == false, "overlap is explicit incomplete evidence")
    let append = try FileHandle(forWritingTo: file); try append.seekToEnd()
    try append.write(contentsOf: continuityRecord("independent", 300, at: date.addingTimeInterval(2))); try append.close()
    _ = owner.scan(historical: historical, changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "independently disjoint interval resumes after overlap")
    owner.eventIndex = nil; owner.requestArchive = nil // Release the prior storage owner before restart.
    let restored = UsageScanner(home: owner.home, stateURL: state); restored.readAccount = false
    continuityCheck(restored.loadError == nil, "restart opens its durable stores")
    _ = restored.scan(historical: historical, changedPaths: [file])
    continuityCheck(restored.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "overlap/gap replay remains300")
    continuityCheck(restored.ledger.sourceErrors?.isEmpty == false, "unrecoverable interval warning survives restart and successful read")
}

// An observed counter filtered out of this cursor's date scope is not an
// admitted boundary. Live and historical readers must both retain their share.
do {
    let home = temp.appendingPathComponent("continuity-mixed-scope")
    let file = home.appendingPathComponent("sessions/mixed.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let owner = UsageScanner(home: home, stateURL: home.appendingPathComponent("ledger.json")); owner.readAccount = false
    try (continuityMeta("mixed") + continuityRecord("historical-A", 100, at: oldDate) + continuityRecord("live-B", 200, at: now)).write(to: file)
    _ = owner.scan(historical: true, changedPaths: [file]); _ = owner.scan(changedPaths: [file])
    try owner.saveIfNeeded(force: true)
    try (continuityMeta("mixed") + continuityRecord("historical-A", 100, at: oldDate) +
        continuityRecord("historical-missing", 150, at: oldDate.addingTimeInterval(1), last: 50) +
        continuityRecord("live-B", 200, at: now) + continuityRecord("live-C", 300, at: now.addingTimeInterval(1))).write(to: file, options: .atomic)
    _ = owner.scan(historical: true, changedPaths: [file]); _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 350, "scope-local historical increment is not hidden by live observed boundary")
    continuityCheck(owner.ledger.entries.filter { $0.date < Calendar.current.startOfDay(for: owner.ledger.started) }.reduce(0) { $0 + $1.tokens.input } == 150, "historical scope retains its own admitted interval")
}

// Legacy migration without replacement and alias/archive moves retain identities.
do {
    var (owner, file, state) = try continuityFixture("legacy-unchanged")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
    var cursors = legacy["cursors"] as! [String: [String: Any]]
    for key in cursors.keys {
        for field in ["continuity", "sourceSession", "lastFingerprint", "admittedBoundary", "lastObservation", "reconciliation", "continuityGap", "aliasWitness"] { cursors[key]?.removeValue(forKey: field) }
    }
    legacy["cursors"] = cursors
    try JSONSerialization.data(withJSONObject: legacy).write(to: state)
    owner.eventIndex = nil; owner.requestArchive = nil // Release the prior storage owner before restart.
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    continuityCheck(owner.loadError == nil, "restart opens its durable stores")
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 200, "legacy unchanged replay does not duplicate")
    let append = try FileHandle(forWritingTo: file); try append.seekToEnd()
    try append.write(contentsOf: continuityRecord("C", 300, at: now)); try append.close()
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "legacy recovered boundary permits ordinary append")
    _ = owner.scan()
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300 && owner.lastWork.codexBytes == 0, "discovery/path alias reuses cursor without replay")
    continuityCheck(owner.lastWork.codexValidationBytes <= 768, "unchanged validation is bounded independently of log size")
    let archived = owner.home.appendingPathComponent("archived_sessions/rollout.jsonl")
    try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: file, to: archived)
    _ = owner.scan(historical: true); _ = owner.scan()
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "archive moves preserve IDs and totals")
}

for (phase, inPlace) in [(CodexReadPhase.opened, false), (.line, false), (.validated, false), (.validated, true)] {
    let (owner, file, state) = try continuityFixture("race-\(phase)-\(inPlace)")
    let before = owner.ledger.cursors
    let append = try FileHandle(forWritingTo: file); try append.seekToEnd()
    try append.write(contentsOf: continuityRecord("C", 300, at: now)); try append.close()
    var fired = false, lines = 0
    owner.codexReadWillRun = { step, path in
        guard step == phase, !fired else { return }
        if step == .line { lines += 1; if lines < 2 { return } }
        fired = true
        if step == .line { throw POSIXError(.EIO) }
        let bytes = continuityMeta("original") + continuityRecord("A", 100, at: now) + continuityRecord("C", 300, at: now)
        if inPlace {
            let writer = try FileHandle(forWritingTo: path); try writer.truncate(atOffset: 0)
            try writer.write(contentsOf: bytes); try writer.close()
        } else { try bytes.write(to: path, options: .atomic) }
    }
    let failed = owner.scan(changedPaths: [file])
    continuityCheck(fired && failed.error != nil && owner.ledger.cursors == before, "\(phase) failure/race retains exact prior cursor")
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 200, "\(phase) failure admits no staged usage")
    let unrelated = owner.home.appendingPathComponent("sessions/unrelated.jsonl")
    try Data().write(to: unrelated); _ = owner.scan(changedPaths: [unrelated])
    continuityCheck(owner.ledger.sourceErrors?.isEmpty == false, "unrelated success retains failed file diagnostic")
    owner.codexReadWillRun = nil
    _ = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    owner.eventIndex = nil; owner.requestArchive = nil // Release the prior storage owner before restart.
    let restored = UsageScanner(home: owner.home, stateURL: state); restored.readAccount = false
    continuityCheck(restored.loadError == nil, "restart opens its durable stores")
    _ = restored.scan(changedPaths: [file])
    continuityCheck(restored.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "\(phase) retry/restart admits C exactly once")
}
for phase in [CheckpointPhase.ledger, .index, .acknowledge] {
    var (owner, file, state) = try continuityFixture("checkpoint-\(phase)")
    let prior = owner.ledger.cursors
    try (continuityMeta("original") + continuityRecord("A", 100, at: now) + continuityRecord("C", 300, at: now)).write(to: file, options: .atomic)
    owner.lastSave = .distantPast
    owner.checkpointWillRun = { if $0 == phase { throw RequestArchive.failure("Synthetic \(phase) failure") } }
    continuityCheck(owner.scan(changedPaths: [file]).error != nil, "\(phase) reports checkpoint failure")
    let durable = try UsageScanner.loadLedger(from: state)
    continuityCheck(durable.entries.reduce(0) { $0 + $1.tokens.input } == (phase == .ledger ? 200 : 300), "\(phase) durable totals match phase")
    if phase == .ledger { continuityCheck(durable.cursors == prior, "undurable usage cannot advance durable cursor") }
    owner.eventIndex = nil; owner.requestArchive = nil // Release the prior storage owner before restart.
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    continuityCheck(owner.loadError == nil, "restart opens its durable stores")
    _ = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    var ids = Set<String>(), archivedTotal = 0
    try owner.requestArchive!.forEach { entry in ids.insert(entry.recordID!); archivedTotal += entry.tokens.input }
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300 && ids.count == 3 && archivedTotal == 300, "\(phase) restart reconciles ledger/index/archive exactly")
    let settled = owner.ledger.cursors
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.cursors == settled && owner.lastWork.codexBytes == 0, "\(phase) settled cursor does not replay")
}

// Old schemas have only cumulative counters. Unknown evidence is not an
// implicit permission to bill a replayed last_request interval.
do {
    var (owner, file, state) = try continuityFixture("legacy-overlap")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
    var cursors = legacy["cursors"] as! [String: [String: Any]]
    for key in cursors.keys {
        for field in ["continuity", "sourceSession", "lastFingerprint", "admittedBoundary", "lastObservation", "reconciliation", "continuityGap", "aliasWitness"] { cursors[key]?.removeValue(forKey: field) }
    }
    legacy["cursors"] = cursors; try JSONSerialization.data(withJSONObject: legacy).write(to: state)
    try (continuityMeta("original") + continuityRecord("A", 100, at: now) +
        continuityRecord("legacy-old", 150, at: now) + continuityRecord("legacy-overlap", 250, at: now) +
        continuityRecord("C", 300, at: now)).write(to: file, options: .atomic)
    owner.eventIndex = nil; owner.requestArchive = nil // Release the prior storage owner before restart.
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    continuityCheck(owner.loadError == nil, "restart opens its durable stores")
    let result = owner.scan(changedPaths: [file])
    continuityCheck(result.entries.reduce(0) { $0 + $1.tokens.input } == 300, "legacy unknown evidence admits only C's disjoint100")
    continuityCheck(result.error != nil, "legacy missing boundary remains explicitly incomplete")
}

do {
    let instant = Date()
    let home = temp.appendingPathComponent("continuity-account")
    let file = home.appendingPathComponent("sessions/fresh.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": "synthetic-account"]]).write(to: home.appendingPathComponent("auth.json"))
    let owner = UsageScanner(home: home, stateURL: home.appendingPathComponent("ledger.json"))
    owner.ledger.lastAccount = Account.read(home: home); owner.ledger.lastPoll = instant.addingTimeInterval(-30)
    try (continuityMeta("fresh") + continuityRecord("fresh-A", 100, at: instant)).write(to: file)
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.last?.account?.id == "synthetic-account", "new chat retains stable-poll inferred account")
    let originalAccount = owner.ledger.entries.first?.account
    owner.ledger.lastPoll = instant.addingTimeInterval(-30)
    try (continuityMeta("fresh") + continuityRecord("fresh-A", 100, at: instant) + continuityRecord("fresh-B", 200, at: instant)).write(to: file, options: .atomic)
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.last?.account == nil && owner.ledger.entries.first?.account == originalAccount, "replacement replay is unattributed and preserves prior account")
    owner.ledger.lastPoll = instant.addingTimeInterval(-30)
    let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
    // Omit turn_context deliberately: the new session cannot inherit its model/turn.
    let record = continuityRecord("unused", 1000, at: instant)
    let tokenOnly = record.suffix(from: record.firstIndex(of: 10)! + 1)
    try writer.write(contentsOf: continuityMeta("different") + tokenOnly); try writer.close()
    _ = owner.scan(changedPaths: [file])
    let last = owner.ledger.entries.last!
    continuityCheck(last.tokens.input == 100 && last.model == "Unknown model" && last.projectPath == "/synthetic/different" && last.account == nil,
                    "session change inside append resets counters/model/turn/project and inferred account")
}

do {
    var (owner, file, state) = try continuityFixture("legacy-no-anchor")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
    var cursors = legacy["cursors"] as! [String: [String: Any]]
    for key in cursors.keys {
        for field in ["continuity", "sourceSession", "lastFingerprint", "admittedBoundary", "lastObservation", "reconciliation", "continuityGap", "aliasWitness"] { cursors[key]?.removeValue(forKey: field) }
    }
    legacy["cursors"] = cursors; try JSONSerialization.data(withJSONObject: legacy).write(to: state)
    owner.eventIndex = nil; owner.requestArchive = nil
    try (continuityMeta("unverified") + continuityRecord("unseen-initial", 100, at: now)).write(to: file, options: .atomic)
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    let first = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(first.entries.reduce(0) { $0 + $1.tokens.input } == 200 && first.error != nil, "no-anchor legacy prefix is withheld with an explicit gap")
    owner.eventIndex = nil; owner.requestArchive = nil
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    continuityCheck(owner.loadError == nil, "no-anchor restart restores verified source boundary")
    // Production accepts fractional timestamps too; this fixture's ISO formatter
    // uses whole seconds, so cross one timestamp tick after the verified scan.
    Thread.sleep(forTimeInterval: 1.1)
    let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
    let bytes = continuityRecord("provably-later", 200, at: Date())
    try writer.write(contentsOf: bytes); try writer.close()
    let next = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(next.entries.reduce(0) { $0 + $1.tokens.input } == 300 && next.error != nil, "verified later append resumes100 while historical gap remains")
    continuityCheck(owner.lastWork.codexBytes == bytes.count, "ordinary append reads only its tail")
    owner.eventIndex = nil; owner.requestArchive = nil
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.loadError == nil && owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "no-anchor recovered append is counted exactly once after restart")
}

for historical in [false, true] {
    let (owner, file, _) = try continuityFixture("opposite-alias-\(historical)", at: historical ? oldDate : now)
    let relative = "sessions/rollout.jsonl", absolute = file.resolvingSymlinksInPath().path
    if historical {
        let prior = owner.ledger.historyCursors?.removeValue(forKey: relative)
        owner.ledger.historyCursors?[absolute] = prior
        owner.ledger.cursors[relative] = Cursor()
    } else {
        let prior = owner.ledger.cursors.removeValue(forKey: relative)
        owner.ledger.cursors[absolute] = prior
        owner.ledger.historyCursors = [relative: Cursor()]
    }
    try (continuityMeta("original") + continuityRecord("A", 100, at: historical ? oldDate : now) +
        continuityRecord("C", 300, at: historical ? oldDate : now)).write(to: file, options: .atomic)
    _ = owner.scan(historical: historical, changedPaths: [file])
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "opposite namespace aliases retain B200 during A/C replay \(historical)")
}
do {
    let home = temp.appendingPathComponent("multiple-aliases")
    let file = home.appendingPathComponent("sessions/rollout.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let owner = UsageScanner(home: home, stateURL: home.appendingPathComponent("ledger.json")); owner.readAccount = false
    try (continuityMeta("original") + continuityRecord("A", 100, at: now)).write(to: file)
    _ = owner.scan(changedPaths: [file])
    let stale = owner.ledger.cursors["sessions/rollout.jsonl"]!
    let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
    try writer.write(contentsOf: continuityRecord("B", 200, at: now)); try writer.close()
    _ = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    let absolute = file.resolvingSymlinksInPath().path
    owner.ledger.cursors[absolute] = owner.ledger.cursors["sessions/rollout.jsonl"]
    owner.ledger.cursors["sessions/rollout.jsonl"] = stale
    try (continuityMeta("original") + continuityRecord("A", 100, at: now) + continuityRecord("C", 300, at: now)).write(to: file, options: .atomic)
    _ = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "multiple aliases cannot silently choose weaker A100 boundary")
    let cursors = owner.ledger.cursors
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.cursors == cursors && owner.lastWork.codexBytes == 0, "resolved alias evidence is stable without repeated replay")
}

do {
    let (owner, file, _) = try continuityFixture("missing-last")
    let c = continuityRecord("C-without-last", 300, at: now)
    let lines = c.split(separator: 10)
    var token = try JSONSerialization.jsonObject(with: Data(lines[1])) as! [String: Any]
    var payload = token["payload"] as! [String: Any], info = (token["payload"] as! [String: Any])["info"] as! [String: Any]
    info.removeValue(forKey: "last_token_usage"); payload["info"] = info; token["payload"] = payload
    try (continuityMeta("original") + continuityRecord("A", 100, at: now) + Data(lines[0]) + Data([10]) + continuityLine(token)).write(to: file, options: .atomic)
    let held = owner.scan(changedPaths: [file])
    continuityCheck(held.entries.reduce(0) { $0 + $1.tokens.input } == 200 && held.error != nil, "missing request counters cannot manufacture recovered usage")
    let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
    try writer.write(contentsOf: continuityRecord("D", 400, at: now)); try writer.close()
    let resumed = owner.scan(changedPaths: [file])
    continuityCheck(resumed.entries.reduce(0) { $0 + $1.tokens.input } == 300 && resumed.error != nil, "later supported request resumes without inventing missing C")
    _ = owner.scan(historical: true, changedPaths: [file])
    continuityCheck(owner.ledger.sourceErrors?.isEmpty == false, "successful opposite date scope cannot clear the missing live interval")
}
do {
    let (owner, file, _) = try continuityFixture("counter-reset")
    let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
    try writer.write(contentsOf: continuityRecord("reset", 100, at: now.addingTimeInterval(1))); try writer.close()
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 300, "ordinary counter reset admits only last request")
    try (continuityMeta("original") + continuityRecord("after-reset", 200, at: now.addingTimeInterval(2))).write(to: file, options: .atomic)
    _ = owner.scan(changedPaths: [file])
    continuityCheck(owner.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 400, "recovery uses the admitted post-reset boundary rather than an older counter epoch")
}

// A verified recovery time is an admission fence, not the time of the latest
// held read. Delayed source timestamps must not chase a moving wall clock.
do {
    let previousOptions = iso.formatOptions
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    defer { iso.formatOptions = previousOptions }
    var (owner, file, state) = try continuityFixture("delayed-no-anchor")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
    var cursors = legacy["cursors"] as! [String: [String: Any]]
    for key in cursors.keys {
        for field in ["continuity", "sourceSession", "lastFingerprint", "admittedBoundary", "lastObservation", "reconciliation", "continuityGap", "aliasWitness"] { cursors[key]?.removeValue(forKey: field) }
    }
    legacy["cursors"] = cursors; try JSONSerialization.data(withJSONObject: legacy).write(to: state)
    owner.eventIndex = nil; owner.requestArchive = nil
    try (continuityMeta("delayed") + continuityRecord("unknown-prefix", 100, at: Date().addingTimeInterval(-60))).write(to: file, options: .atomic)
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    let initial = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(initial.entries.reduce(0) { $0 + $1.tokens.input } == 200 && initial.error != nil, "delayed stream starts with an explicitly held legacy prefix")
    let afterInitialVerification = Date()
    Thread.sleep(forTimeInterval: 0.02) // Cross fractional timestamp precision.
    let laterSourceDate = Date()
    Thread.sleep(forTimeInterval: 0.02)
    func appendDelayed(_ turn: String, _ total: Int, _ date: Date) throws {
        let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
        try writer.write(contentsOf: continuityRecord(turn, total, at: date)); try writer.close()
    }
    // This older record arrives late and must remain held. Its read must not
    // move the initial time fence ahead of a newer, independently dated request.
    try appendDelayed("backdated-held", 200, afterInitialVerification.addingTimeInterval(-1))
    let held = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(held.entries.reduce(0) { $0 + $1.tokens.input } == 200 && held.error != nil, "pre-fence delayed replay remains withheld")
    owner.eventIndex = nil; owner.requestArchive = nil
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    continuityCheck(owner.loadError == nil, "delayed-stream restart opens durable state")
    try appendDelayed("delayed-new-C", 300, laterSourceDate)
    let firstNew = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    continuityCheck(firstNew.entries.reduce(0) { $0 + $1.tokens.input } == 300 && firstNew.error != nil,
                    "post-fence delayed C must reach300 despite intervening held scan; got \(firstNew.entries.reduce(0) { $0 + $1.tokens.input })")
    try appendDelayed("delayed-new-D", 400, laterSourceDate.addingTimeInterval(0.005))
    _ = owner.scan(changedPaths: [file]); try owner.saveIfNeeded(force: true)
    owner.eventIndex = nil; owner.requestArchive = nil
    owner = UsageScanner(home: owner.home, stateURL: state); owner.readAccount = false
    let restarted = owner.scan(changedPaths: [file])
    continuityCheck(owner.loadError == nil && restarted.entries.reduce(0) { $0 + $1.tokens.input } == 400 && restarted.error != nil,
                    "sustained delayed requests advance exactly once across restart while preserving the gap")
}
// A fork's inherited parent metadata is not evidence of replacing the final child session.
for historical in [false, true] {
    for kind in ["exact", "legacy", "missing-boundary", "retained-gap"] {
        let fixture = temp.appendingPathComponent("copied-prefix-\(historical)-\(kind)")
        let file = fixture.appendingPathComponent("sessions/fork.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let date = historical ? oldDate : now
        let prefix = continuityMeta("parent") + continuityRecord("copied-A", 100, at: date) + continuityMeta("child")
        let original = prefix + continuityRecord("child-B", 200, at: date)
        try original.write(to: file)
        let owner = UsageScanner(home: fixture, stateURL: fixture.appendingPathComponent("ledger.json")); owner.readAccount = false
        let first = owner.scan(historical: historical, changedPaths: [file])
        continuityCheck(first.error == nil && first.entries.reduce(0) { $0 + $1.tokens.input } == 200, "copied prefix initial admission")
        try owner.saveIfNeeded(force: true)
        let key = owner.codexCursorKey(file, historical: historical)
        if kind == "legacy" {
            if historical { owner.ledger.historyCursors?[key]?.continuity = nil }
            else { owner.ledger.cursors[key]?.continuity = nil }
        }
        if kind == "retained-gap" {
            let gap = "Source continuity is incomplete; retained prior totals and admitted only independently supported requests."
            if historical { owner.ledger.historyCursors?[key]?.continuityGap = gap }
            else { owner.ledger.cursors[key]?.continuityGap = gap }
        }
        try ((kind == "missing-boundary" ? prefix : original) + continuityRecord("child-C", 300, at: date)).write(to: file, options: .atomic)
        let recovered = owner.scan(historical: historical, changedPaths: [file])
        try owner.saveIfNeeded(force: true)
        continuityCheck(recovered.entries.reduce(0) { $0 + $1.tokens.input } == 300, "copied prefix recovery admits only new request \(kind)")
        let expectsGap = ["missing-boundary", "retained-gap"].contains(kind)
        continuityCheck((recovered.error != nil) == expectsGap, "copied prefix \(kind) preserves only supported gap claims")
        continuityCheck(try owner.requestArchive!.count == 3, "copied prefix archive retains exact request identities")
        let unchanged = owner.scan(historical: historical, changedPaths: [file])
        continuityCheck(unchanged.entries.reduce(0) { $0 + $1.tokens.input } == 300 && (unchanged.error != nil) == expectsGap,
                        "copied prefix unchanged scan neither recounts nor hides a gap")
        try owner.saveIfNeeded(force: true)
        owner.eventIndex = nil; owner.requestArchive = nil
        let reopened = UsageScanner(home: fixture, stateURL: fixture.appendingPathComponent("ledger.json")); reopened.readAccount = false
        let restarted = reopened.scan(historical: historical, changedPaths: [file])
        continuityCheck(reopened.loadError == nil && restarted.entries.reduce(0) { $0 + $1.tokens.input } == 300 &&
                        (restarted.error != nil) == expectsGap, "copied prefix restart preserves counts and qualified gap state")
        continuityCheck(try reopened.requestArchive!.count == 3, "copied prefix restart keeps exactly three archived identities")
    }
}
// Equivalent source errors must publish the same text, preserving an open detail page.
do {
    let root = temp.appendingPathComponent("stable-diagnostic-order")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let owner = UsageScanner(home: root, stateURL: root.appendingPathComponent("ledger.json")); owner.readAccount = false
    let messages = (0..<40).map { "Synthetic source warning \(String(format: "%02d", $0))." }
    let expected = messages.sorted().joined(separator: " ")
    for historical in [true, false] {
        for order in [messages, Array(messages.reversed())] {
            owner.ledger.sourceErrors = [:]
            for message in order { owner.ledger.sourceErrors?[message] = message }
            let result = owner.scan(historical: historical, changedPaths: [])
            continuityCheck(result.error == expected, "diagnostic order is stable across equivalent rescans")
            continuityCheck(owner.ledger.sourceErrors?.count == 40, "stable presentation keeps every source diagnostic")
        }
    }
}
if !continuityFailures.isEmpty { fflush(stdout); exit(1) }
print("PASS: Codex scan continuity live/history matrix, disjoint interval recovery, legacy no-anchor resumption, aliases, races, account boundaries and checkpoint restarts")
