import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-grok-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let grokHome = root.appendingPathComponent("grok")
let secret = "SECRET_PROMPT_TEXT_MUST_NOT_APPEAR"
func writeJSON(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}
func usageCounters(input: Int, output: Int, cached: Int, writes: Int, reasoning: Int, total: Int, ticks: Int, model: String = "grok-4.6-build") -> [String: Any] {
    ["inputTokens": input, "outputTokens": output, "cachedReadTokens": cached, "cacheCreationTokens": writes,
     "reasoningTokens": reasoning, "totalTokens": total, "modelCalls": 1, "costUsdTicks": ticks,
     "turnCount": 1, "primaryModelId": model, "modelUsage": [model: [
        "inputTokens": input, "outputTokens": output, "cachedReadTokens": cached, "cacheCreationTokens": writes,
        "reasoningTokens": reasoning, "totalTokens": total, "modelCalls": 1, "costUsdTicks": ticks
     ]]]
}
func turn(_ number: Int, ended: String, input: Int, output: Int, cached: Int, writes: Int, reasoning: Int, total: Int, ticks: Int) -> [String: Any] {
    var row = usageCounters(input: input, output: output, cached: cached, writes: writes, reasoning: reasoning, total: total, ticks: ticks)
    row["turnNumber"] = number
    row["endedAt"] = ended
    return row
}
func summary(id: String, model: String = "grok-4.6-build", parent: String? = nil, effort: String? = "high", updated: String = "2026-09-07T12:00:10Z", status: String? = nil, kind: String? = nil, lastActive: String? = nil) -> [String: Any] {
    var root: [String: Any] = [
        "info": ["id": id, "cwd": "/synthetic/project"],
        "current_model_id": model,
        "created_at": "2026-09-07T11:00:00.000000Z",
        "updated_at": updated,
        "session_summary": secret,
        "generated_title": secret,
        "reasoning_effort": effort as Any
    ]
    if let parent { root["parent_session_id"] = parent }
    if let status { root["status"] = status }
    if let kind { root["session_kind"] = kind }
    if let lastActive { root["last_active_at"] = lastActive }
    return root
}

let validID = "00000000-0000-0000-0000-0000000000aa"
let parentID = "00000000-0000-0000-0000-0000000000bb"
let childID = "00000000-0000-0000-0000-0000000000cc"
let chatID = "00000000-0000-0000-0000-0000000000dd"
let agentID = "00000000-0000-0000-0000-0000000000ee"
let validDir = grokHome.appendingPathComponent("sessions/synthetic/\(validID)")
try writeJSON(summary(id: validID), to: validDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": validID,
    "updatedAt": "2026-09-07T12:00:10.000000+00:00",
    "session": usageCounters(input: 300, output: 30, cached: 80, writes: 10, reasoning: 15, total: 330, ticks: 1230),
    "turns": [
        turn(1, ended: "2026-09-07T12:00:00.000Z", input: 100, output: 10, cached: 20, writes: 10, reasoning: 5, total: 110, ticks: 400),
        turn(2, ended: "2026-09-07T12:00:10.000Z", input: 200, output: 20, cached: 60, writes: 0, reasoning: 10, total: 220, ticks: 830)
    ]
], to: validDir.appendingPathComponent("usage.json"))
try writeJSON(["primaryModelId": "grok-4.6-build", "contextTokensUsed": 50], to: validDir.appendingPathComponent("signals.json"))

let parentDir = grokHome.appendingPathComponent("sessions/synthetic/\(parentID)")
try writeJSON(summary(id: parentID), to: parentDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": parentID, "updatedAt": "2026-09-07T12:00:00Z",
    "session": usageCounters(input: 1000, output: 100, cached: 400, writes: 0, reasoning: 40, total: 1100, ticks: 5000),
    "turns": [turn(1, ended: "2026-09-07T12:00:00Z", input: 1000, output: 100, cached: 400, writes: 0, reasoning: 40, total: 1100, ticks: 5000)]
], to: parentDir.appendingPathComponent("usage.json"))

let childDir = grokHome.appendingPathComponent("sessions/synthetic/\(childID)")
try writeJSON(summary(id: childID, parent: parentID), to: childDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": childID, "updatedAt": "2026-09-07T12:01:00Z",
    "session": usageCounters(input: 1100, output: 110, cached: 420, writes: 0, reasoning: 45, total: 1210, ticks: 5600),
    "turns": [turn(1, ended: "2026-09-07T12:01:00Z", input: 100, output: 10, cached: 20, writes: 0, reasoning: 5, total: 110, ticks: 600)]
], to: childDir.appendingPathComponent("usage.json"))

let nowISO = ISO8601DateFormatter()
nowISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let liveStart = Date()
let chatDir = grokHome.appendingPathComponent("sessions/synthetic/\(chatID)")
try writeJSON(summary(id: chatID, updated: nowISO.string(from: liveStart), status: "running"), to: chatDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": chatID, "updatedAt": nowISO.string(from: liveStart),
    "session": usageCounters(input: 50, output: 100, cached: 0, writes: 0, reasoning: 10, total: 150, ticks: 10),
    "turns": [turn(1, ended: nowISO.string(from: liveStart), input: 50, output: 100, cached: 0, writes: 0, reasoning: 10, total: 150, ticks: 10)]
], to: chatDir.appendingPathComponent("usage.json"))

let agentDir = grokHome.appendingPathComponent("sessions/synthetic/\(agentID)")
try writeJSON(summary(id: agentID, parent: chatID, updated: nowISO.string(from: liveStart), status: "running"), to: agentDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": agentID, "updatedAt": nowISO.string(from: liveStart),
    "session": usageCounters(input: 20, output: 40, cached: 0, writes: 0, reasoning: 8, total: 60, ticks: 4),
    "turns": [turn(1, ended: nowISO.string(from: liveStart), input: 20, output: 40, cached: 0, writes: 0, reasoning: 8, total: 60, ticks: 4)]
], to: agentDir.appendingPathComponent("usage.json"))
try writeJSON([
    "subagent_id": "sub-1", "parent_session_id": chatID, "child_session_id": agentID,
    "subagent_type": "general-purpose", "prompt": secret, "description": secret, "status": "running"
], to: chatDir.appendingPathComponent("subagents/sub-1/meta.json"))

let scanner = UsageScanner(home: root.appendingPathComponent("codex"), stateURL: root.appendingPathComponent("ledger.json"), grokHome: grokHome)
scanner.readAccount = false
let snapshot = scanner.scan(historical: true)
check(snapshot.error == nil, "Grok ingest must not fail closed on synthetic fixtures")
let grokRows = snapshot.entries.filter { $0.provider == "xai" }
check(!grokRows.isEmpty, "Grok rows must be admitted")
let validRows = grokRows.filter { $0.session == validID }
check(validRows.reduce(0) { $0 + $1.tokens.total } == 330, "Valid Grok turns must sum to session processed tokens")
check(validRows.reduce(0) { $0 + $1.tokens.cached } == 80, "Cached-read stays a distinct counter")
check(validRows.reduce(0) { $0 + $1.tokens.reasoning } == 15, "Reasoning stays a distinct subset")
check(validRows.contains { $0.tokens.cacheWrite == 10 }, "Cache-creation maps onto cache-write")
check(validRows.allSatisfy { $0.model == "grok-4.6-build" }, "Model identity is retained")
check(validRows.allSatisfy { $0.effort == "high" }, "Summary reasoning_effort is retained on admitted rows")
check(validRows.allSatisfy { $0.pricingDay == "2026-09-07" }, "Turn timestamps become UTC pricing days")
check(validRows.allSatisfy { $0.account == nil }, "Grok rows stay unattributed without a local Grok account source")
check(validRows.allSatisfy { $0.projectPath == "/synthetic/project" }, "Grok summary cwd is the project")
check(validRows.reduce(0) { $0 + ($1.costUsdTicks ?? 0) } == 1230, "Dated Grok history keeps summed cost ticks")
var details: [Entry] = []
try scanner.requestArchive?.forEach { details.append($0) }
let validDetails = details.filter { $0.session == validID }
check(validDetails.count == 2, "Archive keeps separate Grok turns before daily aggregation")
check(validDetails.contains { $0.costUsdTicks == 400 } && validDetails.contains { $0.costUsdTicks == 830 }, "Grok cost ticks stay on admitted turns")
check(validDetails.contains { $0.tokens.cached == 20 } && validDetails.contains { $0.tokens.cached == 60 }, "Per-turn cached-read is retained in the archive")
let encoded = String(data: try JSONEncoder().encode(scanner.ledger), encoding: .utf8)!
check(!encoded.contains(secret), "Prompt, title, and summary text must not enter the ledger")
let detailBlob = String(data: try JSONEncoder().encode(validDetails), encoding: .utf8)!
check(!detailBlob.contains(secret), "Archive metadata must not carry prompt text")
print("PASS: Grok fixture ingest, counters, model/session, UTC day, no prompt text")

let childRows = grokRows.filter { $0.session == childID }
check(childRows.reduce(0) { $0 + $1.tokens.total } == 110, "Fork/resume inherited session totals must not be billed")
let parentRows = grokRows.filter { $0.session == parentID }
check(parentRows.reduce(0) { $0 + $1.tokens.total } == 1100, "Parent session still admits its own usage")

let snapParent = "00000000-0000-0000-0000-0000000000f1"
let snapChild = "00000000-0000-0000-0000-0000000000f2"
let snapHome = root.appendingPathComponent("grok-snapshot-fork")
let snapParentDir = snapHome.appendingPathComponent("sessions/synthetic/\(snapParent)")
try writeJSON(summary(id: snapParent), to: snapParentDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": snapParent, "updatedAt": "2026-09-07T12:00:00Z",
    "session": usageCounters(input: 1000, output: 100, cached: 400, writes: 0, reasoning: 40, total: 1100, ticks: 5000),
    "turns": [turn(1, ended: "2026-09-07T12:00:00Z", input: 1000, output: 100, cached: 400, writes: 0, reasoning: 40, total: 1100, ticks: 5000)]
], to: snapParentDir.appendingPathComponent("usage.json"))
let snapChildDir = snapHome.appendingPathComponent("sessions/synthetic/\(snapChild)")
try writeJSON(summary(id: snapChild, parent: snapParent), to: snapChildDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": snapChild, "updatedAt": "2026-09-07T12:01:00Z",
    "session": usageCounters(input: 1100, output: 50, cached: 420, writes: 0, reasoning: 20, total: 1150, ticks: 5600),
    "turns": [turn(1, ended: "2026-09-07T12:01:00Z", input: 1100, output: 50, cached: 420, writes: 0, reasoning: 20, total: 1150, ticks: 5600)]
], to: snapChildDir.appendingPathComponent("usage.json"))
let snapScan = UsageScanner(home: root.appendingPathComponent("codex-snap"), stateURL: root.appendingPathComponent("snap-ledger.json"), grokHome: snapHome)
snapScan.readAccount = false
_ = snapScan.scan(historical: true)
check(snapScan.ledger.entries.filter { $0.session == snapParent }.reduce(0) { $0 + $1.tokens.total } == 1100, "Snapshot-fork parent still admits its own usage")
check(snapScan.ledger.entries.filter { $0.session == snapChild }.isEmpty, "A fork whose last turn equals the session snapshot must not bill inherited totals")
try writeJSON([
    "sessionId": snapChild, "updatedAt": "2026-09-07T12:02:00Z",
    "session": usageCounters(input: 1180, output: 80, cached: 440, writes: 0, reasoning: 25, total: 1260, ticks: 5800),
    "turns": [turn(1, ended: "2026-09-07T12:02:00Z", input: 1180, output: 80, cached: 440, writes: 0, reasoning: 25, total: 1260, ticks: 5800)]
], to: snapChildDir.appendingPathComponent("usage.json"))
_ = snapScan.scan(historical: true)
let snapChildAfter = snapScan.ledger.entries.filter { $0.session == snapChild }
check(snapChildAfter.reduce(0) { $0 + $1.tokens.total } == 110, "Later growth on a snapshot-shaped fork is the child's increment")
check(snapChildAfter.reduce(0) { $0 + ($1.costUsdTicks ?? 0) } == 200, "Snapshot-fork tick growth is the increment past the inherited baseline")
print("PASS: snapshot-shaped Grok fork last-turn is a baseline, not inherited billing")
let again = scanner.scan(historical: true)
check(again.entries.filter { $0.provider == "xai" }.reduce(0) { $0 + $1.tokens.total } == grokRows.reduce(0) { $0 + $1.tokens.total }, "Reimport must not double Grok totals")
print("PASS: Grok fork/resume last-turn admission and idempotent rescan")

check(scanner.ledger.quotas.isEmpty, "Grok usage ingest must not invent quota/reset/exhaustion")
let live = LiveMonitor(home: root.appendingPathComponent("codex"), stateURL: root.appendingPathComponent("live.json"))
check(live.state.accounts.isEmpty && (live.state.quotaHistory ?? []).isEmpty, "Grok session files do not fill the Codex live account store")
print("PASS: Grok usage ingest does not invent quota")
let billedNow = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!
let billed = GrokBilling.reading(from: [
    "subscription_tier": "X Premium+",
    "config": [
        "creditUsagePercent": 49.0,
        "currentPeriod": [
            "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-09-11T05:59:15.855870+00:00",
            "end": "2026-09-18T05:59:15.855870+00:00"
        ]
    ]
], accountID: "grok:test", now: billedNow)
check(billed?.used == 49 && billed?.window == GrokBilling.windowName("USAGE_PERIOD_TYPE_WEEKLY") && billed?.name == "X Premium+", "Grok billing maps used percent, weekly window and plan")
check(billed?.minutes == GrokBilling.windowMinutes("USAGE_PERIOD_TYPE_WEEKLY"), "Weekly start/end become 10080 minutes")
check(GrokBilling.reading(from: [:], accountID: "grok:test", now: billedNow) == nil, "Missing billing fields stay unavailable")
check(GrokBilling.percent(101) == nil && GrokBilling.percent(-1) == nil, "Out-of-range percents are not a remaining figure")
check(GrokInstallation.executable(environment: ["GROK_CLI_PATH": "/missing/grok"], isExecutable: { _ in false }) == nil, "A missing Grok binary is absence, not a guessed path")
print("PASS: Grok billing remaining is measured from the agent payload")

let disjoint = GrokUsage.tokens([
    "input_tokens": 100, "cache_read_input_tokens": 50, "cache_creation_input_tokens": 10,
    "output_tokens": 20, "reasoning_tokens": 4, "total_tokens": 180
])
check(disjoint.0.input == 160 && disjoint.0.cached == 50 && disjoint.0.cacheWrite == 10 && disjoint.0.output == 20, "Disjoint Grok buckets fold cache-read and cache-write into input")
check(disjoint.0.total == 180, "Processed total stays input+output after fold")
check(disjoint.1.contains("cache_write_input_tokens") && disjoint.1.contains("cached_input_tokens"), "Presence tracks Grok cache fields")
let sessionShape = GrokUsage.tokens(["inputTokens": 150, "cachedReadTokens": 50, "outputTokens": 20, "totalTokens": 170, "cacheCreationTokens": 10, "reasoningTokens": 4])
check(sessionShape.0.input == 150 && sessionShape.0.total == 170, "Session-shaped Grok totals already include cache-read")
let absentWrite = GrokUsage.tokens(["inputTokens": 100, "cachedReadTokens": 50, "outputTokens": 20, "totalTokens": 170])
let zeroWrite = GrokUsage.tokens(["inputTokens": 100, "cachedReadTokens": 50, "cacheCreationTokens": 0, "outputTokens": 20, "totalTokens": 170])
check(absentWrite.0.input == 150 && absentWrite.0.cacheWrite == nil && !absentWrite.1.contains("cache_write_input_tokens"),
      "Disjoint Grok counters retain missing cache-write evidence")
check(zeroWrite.0.input == 150 && zeroWrite.0.cacheWrite == 0 && zeroWrite.1.contains("cache_write_input_tokens"),
      "Disjoint Grok counters retain an explicitly recorded cache-write zero")
do {
    let overReasoning = GrokUsage.tokens(["inputTokens": 10, "cachedReadTokens": 5, "outputTokens": 2, "reasoningTokens": 9, "totalTokens": 17]).0
    let negativeCache = GrokUsage.tokens(["inputTokens": 10, "cachedReadTokens": -1, "outputTokens": 2, "totalTokens": 11]).0
    check(overReasoning.input == 15 && overReasoning.reasoning == 9 && overReasoning.cacheWrite == nil,
          "Cache folding must preserve invalid reasoning for observable integrity repair")
    check(negativeCache.input == 9 && negativeCache.cached == -1,
          "Cache folding must preserve a negative component for quarantine")
    let home = root.appendingPathComponent("invalid-fold")
    let scanner = UsageScanner(home: home, stateURL: home.appendingPathComponent("ledger.json"))
    scanner.readAccount = false
    let date = Date()
    for (name, tokens) in [("reasoning", overReasoning), ("negative", negativeCache)] {
        let id = EventIdentity.hash(name)
        var entry = Entry(date: date, session: name, model: "grok", tokens: tokens, account: nil)
        entry.recordID = id; entry.harness = Harness.grok; entry.provider = GrokUsage.provider
        scanner.persistAdmitted(entry, fingerprint: id, date: date)
    }
    check(scanner.ledger.entries.count == 1 && scanner.ledger.entries[0].tokens.reasoning == 2,
          "Only repairable reasoning enters usage; negative counters remain excluded")
    check(scanner.ledger.integrity?.repaired[IntegrityViolation.reasoningExceedsOutput.rawValue] == 1 &&
          scanner.ledger.integrity?.quarantined[IntegrityViolation.negativeCounter.rawValue] == 1,
          "Shared normalization must not erase the integrity evidence")
}
print("PASS: Grok token field mapping without inventing missing counters")

var grokCost = Entry(date: ProviderUsage.dayDate("2026-09-07")!, session: validID, model: "grok-4.6-build",
                     tokens: Tokens(["input_tokens": 100, "cached_input_tokens": 20, "cache_write_input_tokens": 10, "output_tokens": 10, "reasoning_output_tokens": 5]), account: nil)
grokCost.provider = "xai"; grokCost.tokenFields = UsageMetadata.fields; grokCost.pricingDay = "2026-09-07"; grokCost.costUsdTicks = 400; grokCost.costMetadataVersion = 2
check(CostPricing.estimate(grokCost).amounts == nil, "Grok rows do not match OpenAI rate-card estimates")
check(CostRateHistory.estimate(grokCost, service: .standard, sessionBand: "short").amounts == nil, "Historical OpenAI cards do not price xAI usage")
check(grokCost.costUsdTicks == 400, "Persisted Grok ticks remain a distinct figure")
var openai = grokCost; openai.provider = "openai"; openai.model = "gpt-5.6-sol"; openai.costUsdTicks = nil; openai.contextBand = "short"
check(CostRateHistory.estimate(openai, service: .standard, sessionBand: "short").amounts != nil, "Existing OpenAI fixtures still price")
print("PASS: Grok cost ticks stay separate from OpenAI estimates")

check(ActivityKind.grok(parentSessionID: nil, subagentType: nil) == .chat, "Grok sessions without a parent are chats")
check(ActivityKind.grok(parentSessionID: chatID, subagentType: nil) == .agent, "A parent session id marks an agent")
check(ActivityKind.grok(parentSessionID: nil, subagentType: "general-purpose") == .agent, "Subagent type marks an agent")
check(ActivityKind.grok(parentSessionID: nil, subagentType: nil, sessionKind: "subagent") == .agent, "session_kind subagent is an agent without a parent id")
check(ActivityKind.grok(parentSessionID: nil, subagentType: nil, sessionKind: "subagent_fork") == .agent, "session_kind subagent_fork is an agent")
let grokActivities = GrokActivitySources.read(home: grokHome)
check(grokActivities.contains { $0.session == chatID && $0.kind == .chat }, "Chat fixture is classified as chat")
check(grokActivities.contains { $0.session == agentID && $0.kind == .agent }, "Agent fixture is classified as agent")
let meter = Tachometer()
let reader = ActivityReader()
let t0 = Date().addingTimeInterval(-20)
reader.observeGrok(session: chatID, kind: .chat, output: 100, date: t0, running: true, turn: "grok:" + chatID + ":1", model: "grok-4.6-build")
check(reader.snapshot.measurements.isEmpty, "A single Grok snapshot is only a baseline")
reader.observeGrok(session: chatID, kind: .chat, output: 400, date: t0.addingTimeInterval(10), running: true, turn: "grok:" + chatID + ":1", model: "grok-4.6-build")
meter.apply(reader.snapshot); meter.tick(now: t0.addingTimeInterval(11))
check(meter.rawRate == 30 && meter.hasRate, "Successive Grok output snapshots produce a non-invented rate")
reader.observeGrok(session: agentID, kind: .agent, output: 40, date: t0.addingTimeInterval(1), running: true, turn: "grok:" + agentID + ":1", model: "grok-4.6-build")
check(reader.snapshot.chatCount == 1 && reader.snapshot.agentCount == 1, "Chat and agent stay distinct when the fixture marks the split")
print("PASS: Grok rate from snapshot deltas and chat/agent classification")

let liveScan = UsageScanner(home: root.appendingPathComponent("codex-live"), stateURL: root.appendingPathComponent("live-ledger.json"), grokHome: grokHome)
liveScan.readAccount = false
_ = liveScan.scan()
let liveChat = liveScan.ledger.entries.filter { $0.session == chatID }
check(!liveChat.isEmpty && liveChat[0].tokens.output == 100, "Live Grok usage is admitted from usage.json")
try writeJSON([
    "sessionId": chatID, "updatedAt": nowISO.string(from: liveStart.addingTimeInterval(10)),
    "session": usageCounters(input: 80, output: 400, cached: 0, writes: 0, reasoning: 20, total: 480, ticks: 20),
    "turns": [
        turn(1, ended: nowISO.string(from: liveStart), input: 50, output: 100, cached: 0, writes: 0, reasoning: 10, total: 150, ticks: 10),
        turn(2, ended: nowISO.string(from: liveStart.addingTimeInterval(10)), input: 30, output: 300, cached: 0, writes: 0, reasoning: 10, total: 330, ticks: 10)
    ]
], to: chatDir.appendingPathComponent("usage.json"))
_ = liveScan.scan()
let liveAfter = liveScan.ledger.entries.filter { $0.session == chatID }
check(liveAfter.reduce(0) { $0 + $1.tokens.output } == 400, "A later Grok snapshot admits the new turn rather than repeating the first")
check(liveScan.ledger.quotas.isEmpty, "Still no invented Grok quota after a second snapshot")
print("PASS: successive Grok usage.json snapshots")

let growID = "00000000-0000-0000-0000-0000000000ff"
let growDir = grokHome.appendingPathComponent("sessions/synthetic/\(growID)")
let growStart = Date()
try writeJSON(summary(id: growID, effort: "xhigh", updated: nowISO.string(from: growStart)), to: growDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": growID, "updatedAt": nowISO.string(from: growStart),
    "session": usageCounters(input: 50, output: 100, cached: 0, writes: 0, reasoning: 10, total: 150, ticks: 10),
    "turns": [turn(1, ended: nowISO.string(from: growStart), input: 50, output: 100, cached: 0, writes: 0, reasoning: 10, total: 150, ticks: 10)]
], to: growDir.appendingPathComponent("usage.json"))
let growScan = UsageScanner(home: root.appendingPathComponent("codex-grow"), stateURL: root.appendingPathComponent("grow-ledger.json"), grokHome: grokHome)
growScan.readAccount = false
_ = growScan.scan()
let growFirst = growScan.ledger.entries.filter { $0.session == growID }
check(growFirst.reduce(0) { $0 + $1.tokens.output } == 100, "The first in-place Grok snapshot admits the turn")
check(growFirst.allSatisfy { $0.effort == "xhigh" }, "xhigh effort from the Grok summary is retained")
try writeJSON([
    "sessionId": growID, "updatedAt": nowISO.string(from: growStart.addingTimeInterval(10)),
    "session": usageCounters(input: 80, output: 400, cached: 0, writes: 0, reasoning: 20, total: 480, ticks: 25),
    "turns": [turn(1, ended: nowISO.string(from: growStart.addingTimeInterval(10)), input: 80, output: 400, cached: 0, writes: 0, reasoning: 20, total: 480, ticks: 25)]
], to: growDir.appendingPathComponent("usage.json"))
_ = growScan.scan()
let growAfter = growScan.ledger.entries.filter { $0.session == growID }
check(growAfter.reduce(0) { $0 + $1.tokens.output } == 400, "In-place Grok turn growth admits the output delta, not a second full total")
check(growAfter.reduce(0) { $0 + $1.tokens.total } == 480, "In-place Grok turn growth matches session processed tokens")
check(growAfter.compactMap(\.costUsdTicks).reduce(0, +) == 25, "In-place Grok tick growth records the increment, not a second cumulative total")
print("PASS: in-place Grok turn growth, effort, and incremental ticks")

let stampID = "00000000-0000-0000-0000-0000000000a1"
let stampDir = grokHome.appendingPathComponent("sessions/synthetic/\(stampID)")
try writeJSON(summary(id: stampID, updated: "2026-09-06T18:00:00.123456+00:00"), to: stampDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": stampID, "updatedAt": "2026-09-06T18:00:10.123456+00:00",
    "session": usageCounters(input: 10, output: 4, cached: 0, writes: 0, reasoning: 1, total: 14, ticks: 7),
    "turns": [turn(1, ended: "2026-09-06T18:00:00.123456+00:00", input: 10, output: 4, cached: 0, writes: 0, reasoning: 1, total: 14, ticks: 7)]
], to: stampDir.appendingPathComponent("usage.json"))
let stampScan = UsageScanner(home: root.appendingPathComponent("codex-stamp"), stateURL: root.appendingPathComponent("stamp-ledger.json"), grokHome: grokHome)
stampScan.readAccount = false
_ = stampScan.scan(historical: true)
let stampRows = stampScan.ledger.entries.filter { $0.session == stampID }
check(!stampRows.isEmpty && stampRows.allSatisfy { $0.pricingDay == "2026-09-06" }, "Six-digit offset timestamps become the UTC pricing day")
check(GrokUsage.tickDelta(session: 25, previous: 10) == 15, "Tick delta is the increment")
check(GrokUsage.tickDelta(session: 10, previous: nil) == 10, "First tick reading is the session figure")
check(GrokUsage.tickDelta(session: 8, previous: 10) == 8, "A lower session tick total is not subtracted into a negative")
print("PASS: six-digit Grok timestamps and tick-delta mapping")

reader.observeGrok(session: chatID, kind: .chat, output: 400, date: t0.addingTimeInterval(12), running: true, turn: "grok:" + chatID + ":1", model: "grok-4.6-build", outputDate: t0.addingTimeInterval(10))
meter.apply(reader.snapshot)
meter.tick(now: t0.addingTimeInterval(12))
check(meter.rawRate == 30 && meter.hasRate, "A later liveness heartbeat must not recompute the rate from observed time")
reader.observeGrok(session: chatID, kind: .chat, output: 700, date: t0.addingTimeInterval(20), running: true, turn: "grok:" + chatID + ":2", model: "grok-4.6-build")
meter.apply(reader.snapshot)
meter.tick(now: t0.addingTimeInterval(20))
check(meter.rawRate == 30 && meter.hasRate, "Cumulative Grok counters retain their baseline across turn boundaries")
print("PASS: Grok speed survives a new turn")

let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let plain = ISO8601DateFormatter()
check(GrokUsage.date("2026-09-12T02:00:40.553935Z", iso: iso, plain: plain) != nil, "Six-digit Z timestamps must parse")
check(GrokUsage.date("2026-09-12T02:00:40.553935+00:00", iso: iso, plain: plain) != nil, "Six-digit offset timestamps must parse")
let openID = "00000000-0000-0000-0000-0000000000a2"
let openDir = grokHome.appendingPathComponent("sessions/synthetic/\(openID)")
try writeJSON(summary(id: openID, updated: "2026-09-07T12:00:00Z", lastActive: "2026-09-07T12:00:00Z"), to: openDir.appendingPathComponent("summary.json"))
try writeJSON([
    "sessionId": openID, "updatedAt": "2026-09-07T12:00:00Z",
    "session": usageCounters(input: 10, output: 4, cached: 0, writes: 0, reasoning: 1, total: 14, ticks: 1),
    "turns": [turn(1, ended: "2026-09-07T12:00:00Z", input: 10, output: 4, cached: 0, writes: 0, reasoning: 1, total: 14, ticks: 1)]
], to: openDir.appendingPathComponent("usage.json"))
try writeJSON([["session_id": openID, "pid": 1, "cwd": "/synthetic/project", "opened_at": "2026-09-12T02:00:40.553935Z"]],
              to: grokHome.appendingPathComponent("active_sessions.json"))
let subID = "00000000-0000-0000-0000-0000000000a3"
let subDir = grokHome.appendingPathComponent("sessions/synthetic/\(subID)")
try writeJSON(summary(id: subID, updated: nowISO.string(from: Date()), kind: "subagent"), to: subDir.appendingPathComponent("summary.json"))
let liveActivities = GrokActivitySources.read(home: grokHome)
check(liveActivities.contains { $0.session == openID && $0.running }, "An open Grok session is running even when usage.json and status are stale")
check(liveActivities.contains { $0.session == validID && !$0.running }, "A historical Grok session is not running")
check(liveActivities.contains { $0.session == subID && $0.kind == .agent && $0.running }, "A recent session_kind=subagent is a running agent")
check(liveActivities.contains { $0.session == chatID && $0.running && $0.kind == .chat }, "Explicit status=running still marks a chat")
print("PASS: Grok live running uses open sessions and summary recency, not usage.json age")

var captured: ActivitySnapshot?
let feedHome = root.appendingPathComponent("codex-feed")
try FileManager.default.createDirectory(at: feedHome, withIntermediateDirectories: true)
let feed = ActivityFeed(home: feedHome, grokHome: grokHome) { captured = $0 }
feed.refresh(paths: [openDir.appendingPathComponent("summary.json")])
let deadline = Date().addingTimeInterval(2)
while captured == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
check(captured?.filtered(for: .grok).turns.values.contains { $0.session == openID && $0.running } == true,
      "A summary.json change must observe the Grok session, not only usage.json")
print("PASS: Grok live feed matches summary.json updates to the session")

check(GrokBilling.accountID(home: root.appendingPathComponent("missing-auth")) == nil, "Unknown accounts cannot share a synthetic identity")
check(GrokBilling.windowMinutes(nil) == nil && GrokBilling.windowMinutes("MONTHLY") == nil, "Unknown and variable periods do not acquire invented durations")
print("PASS: Grok unknown identity and period boundaries")
check(GrokUsage.date(Double.nan, iso: nowISO, plain: ISO8601DateFormatter()) == nil, "Non-finite time is unavailable")
check(GrokUsage.int(["count": Double(Int.max)], "count") == nil, "Rounded out-of-range counters cannot be converted to Int")

// Parent metadata can be the only evidence that a child is an agent.
do {
    let home = root.appendingPathComponent("meta-order")
    let child = home.appendingPathComponent("sessions/child")
    let summaryURL = child.appendingPathComponent("summary.json")
    let usageURL = child.appendingPathComponent("usage.json")
    let metaURL = home.appendingPathComponent("sessions/parent/subagents/job/meta.json")
    try writeJSON(["child_session_id": "meta-child", "status": "running"], to: metaURL)
    let cache = GrokActivityMetadata()
    let early = GrokActivitySources.read(home: home, paths: [metaURL], metadata: cache)
    check(early.isEmpty, "Metadata alone must not invent a usage-bearing session")
    try writeJSON(summary(id: "meta-child", updated: nowISO.string(from: Date())), to: summaryURL)
    try writeJSON(["session": ["outputTokens": 10]], to: usageURL)
    let discovered = GrokActivitySources.read(home: home, paths: [summaryURL], metadata: cache)
    check(discovered.first?.kind == .agent, "Metadata-before-summary retains agent classification")
    let bootstrapCache = GrokActivityMetadata()
    let bootstrap = GrokActivitySources.read(home: home, metadata: bootstrapCache)
    check(bootstrap.first?.kind == .agent, "Discovery honors metadata-only parent identity")
    try writeJSON(["session": ["outputTokens": 20]], to: usageURL)
    let updated = GrokActivitySources.read(home: home, paths: [usageURL], known: bootstrap, metadata: bootstrapCache)
    check(updated.first?.kind == .agent && updated.first?.output == 20, "Usage update preserves metadata-only agent and new output")
}
print("PASS: Grok metadata-only child classification survives usage events and metadata-before-summary order")
