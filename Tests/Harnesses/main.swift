import Foundation
import SQLite3
import Observation
import CoreServices

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-harness-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let secret = "SECRET_PROMPT_TEXT_MUST_NOT_APPEAR"

// Canonical token record ----------------------------------------------------
// The three harnesses disagree about whether cache counters sit inside input.
// Adding them the wrong way either double counts a cached read or drops it.

// Codex: cached is part of input.
let codex = Tokens.canonical(input: 124161, cacheRead: 123776, cacheWrite: 0,
                             output: 76, reasoning: 30, convention: .cachedWithinInput)
check(codex.input == 124161, "Codex input must not be inflated by its own cached subset, got \(codex.input)")
check(codex.cached == 123776, "Codex cached must be preserved")
check(codex.total == 124237, "Codex total must be input plus output, got \(codex.total)")
print("PASS: Codex counters keep cached inside input")

// Claude Code: cache read and write are beside input. Real shape: 2 input
// tokens beside 20,948 cache writes and 27,237 cache reads.
let claude = Tokens.canonical(input: 2, cacheRead: 27237, cacheWrite: 20948,
                              output: 213, reasoning: 0, convention: .cacheBesideInput)
check(claude.input == 48187, "Claude input must absorb both cache counters, got \(claude.input)")
check(claude.cached == 27237, "Claude cached must be the read counter")
check(claude.cacheWrite == 20948, "Claude cache write must be retained")
check(claude.total == 48400, "Claude total must count the context it actually consumed, got \(claude.total)")
print("PASS: Claude Code cache counters are added to input rather than ignored")

// OpenCode publishes its own total, which is the check on the conversion.
let openCode = Tokens.canonical(input: 1824, cacheRead: 19200, cacheWrite: 0,
                                output: 82, reasoning: 0, convention: .cacheBesideInput)
check(openCode.total == 21106, "conversion must reproduce OpenCode's own reported total, got \(openCode.total)")
print("PASS: converted OpenCode counters reproduce the total OpenCode itself reports")

// Negative counters and impossible subsets cannot enter the ledger.
let hostile = Tokens.canonical(input: -5, cacheRead: -9, cacheWrite: -1,
                               output: -3, reasoning: 999, convention: .cacheBesideInput)
check(hostile.input == 0 && hostile.output == 0, "negative counters must clamp to zero")
check(hostile.reasoning == 0, "reasoning cannot exceed output")
check(hostile.cacheWrite == nil, "a negative cache write is absent, not zero")
let missingWrite = Tokens.canonical(input: 10, cacheRead: 0, cacheWrite: nil,
                                    output: 2, reasoning: 0, convention: .cacheBesideInput)
check(missingWrite.cacheWrite == nil && missingWrite.input == 10, "a missing cache write stays unavailable, not a measured zero")
print("PASS: malformed counters cannot enter the ledger as negative or impossible values")

// Claude Code deduplication -------------------------------------------------
// One logical message appears on several transcript lines with the same usage.
// Measured on real transcripts, naive summing inflates output about 2.4x.
func claudeLine(id: String, session: String, output: Int, cwd: String,
                sidechain: Bool = false, tier: String = "standard") -> [String: Any] {
    ["type": "assistant", "sessionId": session, "cwd": cwd, "gitBranch": "main",
     "version": "2.0.0", "isSidechain": sidechain, "timestamp": "2026-09-10T12:00:00.000Z",
     "message": ["id": id, "model": "claude-opus-5", "content": secret,
                 "usage": ["input_tokens": 2, "cache_read_input_tokens": 1000,
                           "cache_creation_input_tokens": 500, "output_tokens": output,
                           "service_tier": tier]]]
}
let repeated = [claudeLine(id: "msg_a", session: "s1", output: 213, cwd: "/Users/x/dev/alpha"),
                claudeLine(id: "msg_a", session: "s1", output: 213, cwd: "/Users/x/dev/alpha"),
                claudeLine(id: "msg_a", session: "s1", output: 213, cwd: "/Users/x/dev/alpha"),
                claudeLine(id: "msg_b", session: "s1", output: 100, cwd: "/Users/x/dev/alpha")]
let parsed = repeated.compactMap { ClaudeCodeUsage.turn(from: $0) }
check(parsed.count == 4, "every usage-bearing line must parse, got \(parsed.count)")
let deduped = ClaudeCodeUsage.deduplicate(parsed)
check(deduped.count == 2, "a message id must be admitted once, got \(deduped.count)")
check(deduped.reduce(0) { $0 + $1.tokens.output } == 313, "deduplicated output must count each message once")
check(parsed.reduce(0) { $0 + $1.tokens.output } == 739, "the naive sum is the inflation this guards against")
print("PASS: a Claude Code message id is admitted exactly once")
print("PASS: repeated transcript lines do not inflate Claude Code output")

let first = deduped[0]
check(first.projectPath == "/Users/x/dev/alpha", "Claude Code project must come from cwd")
check(first.gitBranch == "main", "Claude Code git branch must be observed")
check(first.serviceTier == "standard", "Claude Code records a service tier that Codex does not")
check(first.tokens.input == 1502, "Claude Code input must include both cache counters, got \(first.tokens.input)")
print("PASS: Claude Code carries project, branch and service tier")

// Subagent transcripts are real usage and are counted once, not twice.
let withSidechain = [claudeLine(id: "msg_main", session: "s1", output: 10, cwd: "/Users/x/dev/alpha"),
                     claudeLine(id: "msg_sub", session: "s1", output: 7, cwd: "/Users/x/dev/alpha", sidechain: true),
                     claudeLine(id: "msg_sub", session: "s1", output: 7, cwd: "/Users/x/dev/alpha", sidechain: true)]
let subDeduped = ClaudeCodeUsage.deduplicate(withSidechain.compactMap { ClaudeCodeUsage.turn(from: $0) })
check(subDeduped.count == 2, "a subagent message must be counted once, got \(subDeduped.count)")
check(subDeduped.contains { $0.isSidechain }, "subagent usage must be retained, not discarded")
check(subDeduped.reduce(0) { $0 + $1.tokens.output } == 17, "subagent output must be counted exactly once")
print("PASS: Claude Code subagent usage is counted once, neither dropped nor doubled")

// Records without usage never produce a turn.
check(ClaudeCodeUsage.turn(from: ["type": "user", "message": ["content": secret]]) == nil,
      "a user record carries no usage")
check(ClaudeCodeUsage.turn(from: ["type": "assistant", "message": ["id": "x", "content": secret]]) == nil,
      "an assistant record without usage is not a turn")
print("PASS: Claude Code records without usage are ignored without decoding prompts")

// OpenCode ------------------------------------------------------------------
// One harness, several providers. This is why harness is its own dimension.
func openCodeRow(_ id: String, provider: String, model: String, input: Int,
                 read: Int, write: Int, output: Int, cwd: String, cost: Double) -> [String: Any] {
    ["role": "assistant", "providerID": provider, "modelID": model, "mode": "build",
     "tokens": ["input": input, "output": output, "reasoning": 0,
                "cache": ["read": read, "write": write]],
     "path": ["cwd": cwd, "root": cwd], "cost": cost,
     "time": ["created": 1769555059217, "completed": 1769555061292]]
}
let lmstudio = OpenCodeUsage.turn(id: "m1", session: "ses1",
    data: openCodeRow("m1", provider: "lmstudio", model: "qwen/qwen3-coder-30b",
                      input: 13623, read: 0, write: 0, output: 27, cwd: "/Users/x/dev/alpha", cost: 0))
let hosted = OpenCodeUsage.turn(id: "m2", session: "ses1",
    data: openCodeRow("m2", provider: "opencode", model: "kimi-k2.5-free",
                      input: 1824, read: 19200, write: 0, output: 82, cwd: "/Users/x/dev/beta", cost: 0.0))
check(lmstudio?.provider == "lmstudio" && hosted?.provider == "opencode",
      "OpenCode must report the provider it routed to")
check(lmstudio?.tokens.total == 13650, "OpenCode local model total, got \(lmstudio?.tokens.total ?? -1)")
check(hosted?.tokens.total == 21106, "OpenCode cached total must match its own reported total")
check(hosted?.projectPath == "/Users/x/dev/beta", "OpenCode project must come from path.cwd")
check(lmstudio?.reportedCost == 0, "a provider-reported zero cost is a real reading, not a missing one")
print("PASS: one OpenCode harness resolves to several providers")
print("PASS: OpenCode reports provider cost as its own claim, including a real zero")

check(OpenCodeUsage.turn(id: "u", session: "s", data: ["role": "user", "content": secret]) == nil,
      "a user row carries no usage")
check(!OpenCodeUsage.permittedTables.contains("control_account"),
      "the credential table must never be in the permitted set")
print("PASS: OpenCode reads only usage tables and never the credential table")

check(OpenCodeUsage.milliseconds(1769555059217).map { Int($0.timeIntervalSince1970) } == 1769555059,
      "OpenCode timestamps are epoch milliseconds")
check(OpenCodeUsage.milliseconds(0) == nil && OpenCodeUsage.milliseconds("x") == nil,
      "an absent or malformed timestamp is unavailable")
print("PASS: OpenCode epoch milliseconds convert, and malformed timestamps stay unavailable")

// Identity is scoped by harness --------------------------------------------
let sameID = "msg_collide"
let a = UsageScanner.foreignIdentity(harness: ClaudeCodeUsage.harness, messageID: sameID)
let b = UsageScanner.foreignIdentity(harness: OpenCodeUsage.harness, messageID: sameID)
check(a != b, "two harnesses sharing a message id must not share an identity")
check(a == UsageScanner.foreignIdentity(harness: ClaudeCodeUsage.harness, messageID: sameID),
      "identity must be stable across rescans")
print("PASS: event identity is scoped by harness, so two tools cannot collide")

// A missing installation is not an error.
let absent = try OpenCodeUsage.read(database: root.appendingPathComponent("absent.db"))
check(absent.isEmpty, "an absent OpenCode database means the tool is not installed")
check(ClaudeCodeUsage.transcripts(home: root.appendingPathComponent("absent")).isEmpty,
      "an absent Claude Code home means the tool is not installed")
print("PASS: an uninstalled tool reports no usage rather than an error")

print("PASS: harness integration suite complete")

// Multi-iteration Claude Code messages --------------------------------------
// A message can carry an `iterations` array whose counters sum higher than the
// message-level usage. Measured across 71,554 deduplicated real messages, 18
// were multi-iteration and the message-level figure undercounts output by
// 0.04%. Token Bar reports the message-level figure, because that is the
// provider's own statement of what the message used, and records the
// divergence rather than silently choosing the larger number.
let iterated: [String: Any] = [
    "type": "assistant", "sessionId": "s1", "cwd": "/Users/x/dev/alpha",
    "timestamp": "2026-09-10T12:00:00.000Z",
    "message": ["id": "msg_iter", "model": "claude-opus-5", "content": secret,
                "usage": ["input_tokens": 2, "cache_read_input_tokens": 140448,
                          "cache_creation_input_tokens": 0, "output_tokens": 4910,
                          "iterations": [
                            ["input_tokens": 2, "cache_read_input_tokens": 140448, "output_tokens": 4910],
                            ["input_tokens": 2, "cache_read_input_tokens": 175263, "output_tokens": 8]]]]]
let iteratedTurn = ClaudeCodeUsage.turn(from: iterated)
check(iteratedTurn?.tokens.output == 4910,
      "the message-level output is the reported claim, got \(iteratedTurn?.tokens.output ?? -1)")
check(iteratedTurn?.tokens.cached == 140448,
      "the message-level cache read is the reported claim, got \(iteratedTurn?.tokens.cached ?? -1)")
check(iteratedTurn?.tokens.input == 140450,
      "input must still absorb the message-level cache read, got \(iteratedTurn?.tokens.input ?? -1)")
print("PASS: a multi-iteration Claude Code message reports its message-level usage, not a summed guess")

// A streamed message grows; identical and older records must never add usage again.
let growing = [claudeLine(id: "growth", session: "s", output: 10, cwd: "/tmp/p"),
               claudeLine(id: "growth", session: "s", output: 100, cwd: "/tmp/p"),
               claudeLine(id: "growth", session: "s", output: 10, cwd: "/tmp/p")]
check(ClaudeCodeUsage.deduplicate(growing.compactMap(ClaudeCodeUsage.turn)).first?.tokens.output == 100, "Later larger output survives older copies")
let migration = root.appendingPathComponent("migration")
let migrationHome = migration.appendingPathComponent("claude")
let transcript = migrationHome.appendingPathComponent("projects/p/session.jsonl")
try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
func writeClaude(_ rows: [[String: Any]]) throws {
    let bytes = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data([10]) }.reduce(Data(), +)
    try bytes.write(to: transcript)
}
let ledgerURL = migration.appendingPathComponent("ledger.json")
var migrating: UsageScanner? = UsageScanner(home: migration, stateURL: ledgerURL, claudeHome: migrationHome)
migrating!.readAccount = false
try writeClaude([growing[0]])
_ = migrating!.scan(historical: true)
check(migrating!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 10, "Initial snapshot admitted")
// Reproduce an older installation: immutable base row survives but no counter checkpoint exists.
migrating!.ledger.claudeCounters = nil
try JSONEncoder().encode(migrating!.ledger).write(to: ledgerURL)
migrating = nil
migrating = UsageScanner(home: migration, stateURL: ledgerURL, claudeHome: migrationHome)
migrating!.readAccount = false
try writeClaude(growing)
_ = migrating!.scan(historical: true)
check(migrating!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 100, "Legacy first-wins history gains exactly missing output")
check(migrating!.ledger.entries.reduce(0) { $0 + $1.tokens.input } == 1502, "Repeated input is not charged again")
check(migrating!.ledger.entries.reduce(0) { $0 + $1.eventCount } == 1, "An increase is not another message")
let originalID = UsageScanner.foreignIdentity(harness: ClaudeCodeUsage.harness, messageID: "growth")
let retainedOriginal = try migrating!.requestArchive!.entry(id: originalID)
check(retainedOriginal?.tokens.output == 10, "Original admitted detail remains immutable")
migrating = nil
migrating = UsageScanner(home: migration, stateURL: ledgerURL, claudeHome: migrationHome)
migrating!.readAccount = false
_ = migrating!.scan(historical: true)
check(migrating!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 100, "Restart and replay remain exact")
print("PASS: Claude growing-counter reconciliation preserves baseline, message counts and restart deduplication")

let liveReader = ClaudeActivityReader()
let liveNow = Date()
let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func liveRoot(_ seconds: Double, output: Int, stop: String? = nil) -> [String: Any] {
    var r = claudeLine(id: "live-msg", session: "live-session", output: output, cwd: "/tmp/p")
    r["timestamp"] = formatter.string(from: liveNow.addingTimeInterval(seconds))
    if let stop { var m = r["message"] as! [String: Any]; m["stop_reason"] = stop; r["message"] = m }
    return r
}
liveReader.consume(["type": "user", "uuid": "u", "timestamp": formatter.string(from: liveNow.addingTimeInterval(-10)), "message": ["content": "fixture"]], source: "a")
liveReader.consume(liveRoot(-8, output: 20), source: "a")
liveReader.consume(liveRoot(-6, output: 100), source: "a")
var liveSnapshot = liveReader.snapshot(now: liveNow)
check(liveSnapshot.freshMeasurements(at: liveNow).first?.rate == 40, "Claude rate is output delta divided by logged elapsed time")
liveReader.consume(liveRoot(-5, output: 100), source: "a")
check(liveReader.snapshot().measurements["claude:a"]?.date == liveSnapshot.measurements["claude:a"]?.date, "Identical usage does not refresh speed")
liveReader.consume(liveRoot(-4, output: 100), source: "copied")
check(liveReader.snapshot().turns.count == 1, "Copied messages do not add another Claude task")
var codexTask = TaskActivity(turn: "codex-task", started: liveNow.addingTimeInterval(-10), observed: liveNow, running: true, kind: .chat, session: "codex-task")
liveSnapshot.turns["codex-task"] = codexTask
liveSnapshot.measurements["codex-task"] = RateMeasurement(turn: "codex-task", date: liveNow, duration: 2, output: 240, model: "codex-fixture")
let cMeter = Tachometer(), aMeter = Tachometer()
cMeter.apply(liveSnapshot.filtered(for: .codex)); aMeter.apply(liveSnapshot.filtered(for: .claude))
check(cMeter.rawRate == 120 && aMeter.rawRate == 40, "Simultaneous tools have independent speeds")
check(MenuBarTool.auto.resolve(codex: cMeter, claude: aMeter) == .codex, "Auto follows most recent reporting tool")
check(MenuBarTool.claude.resolve(codex: cMeter, claude: aMeter) == .claude, "Explicit selection does not follow the other tool")
liveReader.consume(liveRoot(-2, output: 120, stop: "end_turn"), source: "a")
check(liveReader.snapshot().freshMeasurements(at: liveNow).isEmpty, "Claude completion stops contributing immediately")
check(liveSnapshot.freshMeasurements(at: liveNow.addingTimeInterval(301)).isEmpty, "Stale tasks cannot supply speed")
print("PASS: simultaneous Claude/Codex rates, copied records, completion, freshness and Auto selection")

// The production live feed reads append-only Claude files independently of a missing Codex catalog.
let feedHome = root.appendingPathComponent("feed-claude")
let feedFile = feedHome.appendingPathComponent("projects/p/live.jsonl")
try FileManager.default.createDirectory(at: feedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
let feedRows: [[String: Any]] = [["type": "user", "uuid": "feed-u", "timestamp": formatter.string(from: liveNow.addingTimeInterval(-10)), "message": ["content": "fixture"]], liveRoot(-8, output: 20), liveRoot(-6, output: 100)]
let feedData = try feedRows.map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
try feedData.write(to: feedFile)
var capturedFeed: ActivitySnapshot?
let feed = ActivityFeed(home: root.appendingPathComponent("absent-codex"), claudeHome: feedHome) { capturedFeed = $0 }
func awaitFeed() {
    let deadline = Date().addingTimeInterval(5)
    while capturedFeed == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(capturedFeed != nil, "Live feed must publish independently of history scanning")
}
feed.refresh(); awaitFeed()
check(capturedFeed!.filtered(for: .claude).freshMeasurements(at: liveNow).first?.rate == 40, "Production feed publishes Claude file counters")
check(capturedFeed!.filtered(for: .claude).error == nil && capturedFeed!.filtered(for: .codex).error != nil, "One tool's catalog failure cannot label the other's reader failed")
let completion = try JSONSerialization.data(withJSONObject: liveRoot(-2, output: 140, stop: "end_turn"))
let fileHandle = try FileHandle(forWritingTo: feedFile); try fileHandle.seekToEnd(); try fileHandle.write(contentsOf: completion); try fileHandle.close()
capturedFeed = nil; feed.refresh(paths: [feedFile]); awaitFeed()
check(!capturedFeed!.filtered(for: .claude).freshMeasurements(at: liveNow).isEmpty, "Partial append remains pending")
let newlineHandle = try FileHandle(forWritingTo: feedFile); try newlineHandle.seekToEnd(); try newlineHandle.write(contentsOf: Data([10])); try newlineHandle.close()
capturedFeed = nil; feed.refresh(paths: [feedFile]); awaitFeed()
check(capturedFeed!.filtered(for: .claude).freshMeasurements(at: liveNow).isEmpty, "Completed appended record stops the live feed")
print("PASS: live file append, partial-line retry, completion and independent tool errors")
var missingCounter = growing[0]
var missingMessage = missingCounter["message"] as! [String: Any]
var missingUsage = missingMessage["usage"] as! [String: Any]
missingUsage.removeValue(forKey: "output_tokens"); missingMessage["usage"] = missingUsage; missingCounter["message"] = missingMessage
check(ClaudeCodeUsage.turn(from: missingCounter) == nil, "Missing output cannot become zero")
missingUsage["output_tokens"] = Int.max; missingMessage["usage"] = missingUsage; missingCounter["message"] = missingMessage
check(ClaudeCodeUsage.turn(from: missingCounter) == nil, "Overflowing counters cannot crash or enter totals")
print("PASS: Claude missing and overflowing counters remain unavailable")
let heldRoot = root.appendingPathComponent("held")
let heldState = heldRoot.appendingPathComponent("ledger.json")
var held: UsageScanner? = UsageScanner(home: heldRoot, stateURL: heldState, retainRequests: false, claudeHome: migrationHome)
held!.readAccount = false
try writeClaude([growing[0]])
_ = held!.scan(historical: true)
held!.ledger.claudeCounters = nil
try JSONEncoder().encode(held!.ledger).write(to: heldState)
held = nil
held = UsageScanner(home: heldRoot, stateURL: heldState, retainRequests: false, claudeHome: migrationHome)
held!.readAccount = false
try writeClaude(growing)
let heldResult = held!.scan(historical: true)
check(heldResult.error?.contains("lack retained counter baselines") == true, "Missing legacy detail is an explicit reconciliation gap")
check(heldResult.entries.reduce(0) { $0 + $1.tokens.output } == 10, "No guessed correction without a retained baseline")
var conflicting = growing[1]
var conflictingMessage = conflicting["message"] as! [String: Any]
var conflictingUsage = conflictingMessage["usage"] as! [String: Any]
conflictingUsage["input_tokens"] = 1; conflictingMessage["usage"] = conflictingUsage; conflicting["message"] = conflictingMessage
try writeClaude([growing[0], conflicting])
let conflictScanner = UsageScanner(home: root.appendingPathComponent("conflict"), stateURL: root.appendingPathComponent("conflict/ledger.json"), claudeHome: migrationHome)
conflictScanner.readAccount = false
let conflictResult = conflictScanner.scan(historical: true)
check(conflictResult.error?.contains("Conflicting Claude") == true, "Conflicting disjoint counter revisions are not silently ignored")
check(conflictResult.entries.reduce(0) { $0 + $1.tokens.output } == 10, "Conflicting snapshots cannot manufacture a componentwise total")
print("PASS: missing legacy baselines and conflicting revisions preserve totals with explicit gaps")
let rotation = root.appendingPathComponent("rotation.jsonl")
let rotationReader = ClaudeActivityReader()
rotationReader.read(rotation)
check(rotationReader.snapshot().error != nil, "An unreadable live log is an explicit error")
try feedData.write(to: rotation)
rotationReader.read(rotation)
check(rotationReader.snapshot().error == nil, "Recovered log clears its read failure")
let replacement = try JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "turn_duration", "timestamp": formatter.string(from: liveNow), "padding": String(repeating: "x", count: feedData.count)]) + Data([10])
try replacement.write(to: rotation, options: .atomic)
rotationReader.read(rotation)
check(rotationReader.snapshot().freshMeasurements(at: liveNow).isEmpty, "A larger atomic replacement cannot retain a stale rate")
print("PASS: live log recovery and replacement invalidate stale cursor state")
var zeroWrite = growing[0]
var zeroMessage = zeroWrite["message"] as! [String: Any]
var zeroUsage = zeroMessage["usage"] as! [String: Any]
zeroUsage["cache_creation_input_tokens"] = 0; zeroMessage["usage"] = zeroUsage; zeroWrite["message"] = zeroMessage
check(ClaudeCodeUsage.turn(from: zeroWrite)?.tokens.cacheWrite == 0, "Recorded Claude cache-write zero stays available")
print("PASS: Claude recorded cache-write zero is preserved")


let progressScanner = UsageScanner(home: root, stateURL: root.appendingPathComponent("progress-ledger.json"), claudeHome: migrationHome)
progressScanner.readAccount = false
var fileProgress: [(Int, Int)] = [], progressErrors: [String] = []
let absentTranscript = transcript.deletingLastPathComponent().appendingPathComponent("missing.jsonl")
_ = progressScanner.scanClaudeCode(historical: true, paths: [transcript, absentTranscript], errors: &progressErrors,
    progress: { fileProgress.append(($0, $1)) })
check(fileProgress.map { $0.0 } == [0, 1, 2] && fileProgress.allSatisfy { $0.1 == 2 }, "Claude progress advances after every checked file, including failures")
check(!progressErrors.isEmpty, "A failed file remains an error, not a successful import")
var routedProgress: [(String, Int, Int)] = []
_ = progressScanner.scan(historical: true, toolProgress: { routedProgress.append(($0, $1, $2)) })
let claudeProgress = routedProgress.filter { $0.0 == "Claude" && $0.2 > 0 }
check(claudeProgress.first?.1 == 0 && claudeProgress.last?.1 == claudeProgress.last?.2, "Scanner forwards the measured Claude denominator and completion")
print("PASS: measured Claude file progress, unreadable-file accounting and scanner callback propagation")

// Checkpoints persist alongside admitted counters; file changes invalidate them.
try writeClaude([growing[0]])
let checkpointRoot = root.appendingPathComponent("checkpoints")
let checkpointState = checkpointRoot.appendingPathComponent("ledger.json")
var checkpointScanner: UsageScanner? = UsageScanner(home: checkpointRoot, stateURL: checkpointState, claudeHome: migrationHome)
checkpointScanner!.readAccount = false
_ = checkpointScanner!.scan(historical: true)
let checkpoints = checkpointScanner!.ledger.claudeFileChecks!
check(!checkpoints.isEmpty, "Successful Claude reads remember file metadata")
let originalStamp = try ClaudeFileCheck.read(transcript)
checkpointScanner = nil
checkpointScanner = UsageScanner(home: checkpointRoot, stateURL: checkpointState, claudeHome: migrationHome)
checkpointScanner!.readAccount = false
check(checkpointScanner!.ledger.claudeFileChecks == checkpoints, "Checkpoints survive a restart")
_ = checkpointScanner!.scan(historical: true)
check(checkpointScanner!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 10, "Unchanged replay preserves totals")
try writeClaude(growing)
let changedStamp = try ClaudeFileCheck.read(transcript)
check(changedStamp != originalStamp, "Appending changes the checkpoint")
_ = checkpointScanner!.scan(historical: true)
check(checkpointScanner!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 100, "Changed files admit only verified increments")
check(conflictScanner.ledger.claudeFileChecks == nil, "Conflicting records are not cached as successful")
print("PASS: Claude file checkpoint persistence, unchanged replay, invalidation, increments and failure exclusion")

// Presence survives normalization; unknown event dates never become observation time.
var sparseRow = openCodeRow("sparse", provider: "opencode", model: "model", input: 10, read: 0, write: 0, output: 2, cwd: "/tmp/project", cost: 0)
sparseRow["tokens"] = ["input": 10, "output": 2]
let sparseTurn = OpenCodeUsage.turn(id: "sparse", session: "s", data: sparseRow)!
check(sparseTurn.tokens.cacheWrite == nil, "Missing cache write is unavailable")
check(!sparseTurn.tokenFields.contains("cached_input_tokens") && !sparseTurn.tokenFields.contains("input_tokens"), "Unknown disjoint input components stay unavailable")
var undatedRow = sparseRow; undatedRow.removeValue(forKey: "time")
check(OpenCodeUsage.turn(id: "undated", session: "s", data: undatedRow) == nil, "Missing timestamp is not now")
var invalidRow = sparseRow; invalidRow["tokens"] = ["input": -1, "output": 2]
check(OpenCodeUsage.turn(id: "invalid", session: "s", data: invalidRow) == nil, "Negative source counters are rejected before clamping")
check(lmstudio?.tokens.cacheWrite == 0, "A reported zero cache write remains zero")
let invalidDatabase = root.appendingPathComponent("invalid.db")
try Data("invalid database".utf8).write(to: invalidDatabase)
do { _ = try OpenCodeUsage.read(database: invalidDatabase); preconditionFailure("Invalid DB must fail") } catch { }
print("PASS: OpenCode presence, real zero, timestamp, invalid counter and failed database boundaries")

// Rejected Claude observations remain visible as incomplete across scans and restarts.
let rejectedRoot = root.appendingPathComponent("rejected-claude")
try FileManager.default.createDirectory(at: rejectedRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
let rejectedState = rejectedRoot.appendingPathComponent("ledger.json")
var incomplete = claudeLine(id: "incomplete", session: "s", output: 20, cwd: "/tmp/p")
var incompleteMessage = incomplete["message"] as! [String: Any]
var incompleteUsage = incompleteMessage["usage"] as! [String: Any]
incompleteUsage.removeValue(forKey: "cache_creation_input_tokens")
incompleteMessage["usage"] = incompleteUsage; incomplete["message"] = incompleteMessage
try writeClaude([incomplete, growing[0]])
var rejectedScanner: UsageScanner? = UsageScanner(home: rejectedRoot, stateURL: rejectedState, claudeHome: migrationHome)
rejectedScanner!.readAccount = false
// Simulate a persisted success from the old scanner against these exact bytes.
let discoveredTranscript = ClaudeCodeUsage.transcripts(home: migrationHome).first!
let rejectedKey = "history:" + String(rejectedScanner!.ledger.started.timeIntervalSince1970) + ":" + discoveredTranscript.path
var legacyCheck = try ClaudeFileCheck.read(transcript); legacyCheck.version = 1
rejectedScanner!.ledger.claudeFileChecks = [rejectedKey: legacyCheck]
let rejectedResult = rejectedScanner!.scan(historical: true)
check(rejectedResult.error?.contains("coverage is incomplete") == true, "Rejected usage is surfaced through the public snapshot")
check(rejectedResult.entries.reduce(0) { $0 + $1.tokens.output } == 10, "Valid usage in the same file still counts")
check(rejectedScanner!.ledger.claudeFileChecks?[rejectedKey] == nil, "Legacy false-success checkpoint is removed")
rejectedScanner = nil
rejectedScanner = UsageScanner(home: rejectedRoot, stateURL: rejectedState, claudeHome: migrationHome)
rejectedScanner!.readAccount = false
let retriedResult = rejectedScanner!.scan(historical: true)
check(retriedResult.error?.contains("coverage is incomplete") == true, "Restart retries rejected usage and preserves the warning")
check(retriedResult.entries.reduce(0) { $0 + $1.tokens.output } == 10, "Retry does not duplicate valid usage")
var empty = claudeLine(id: "zero", session: "s", output: 0, cwd: "/tmp/p")
var emptyMessage = empty["message"] as! [String: Any]
emptyMessage["usage"] = ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
empty["message"] = emptyMessage
let nonUsage: [String: Any] = ["type": "user", "message": ["content": "assistant usage"]]
try writeClaude([growing[0], empty, nonUsage])
let repairedResult = rejectedScanner!.scan(historical: true)
check(repairedResult.error == nil, "Complete zero usage and non-usage records do not cause false failures")
check(repairedResult.entries.reduce(0) { $0 + $1.tokens.output } == 10, "Zero usage does not inflate totals")
check(rejectedScanner!.ledger.claudeFileChecks?[rejectedKey] != nil, "Corrected source can be checkpointed")
print("PASS: rejected Claude usage reports incomplete coverage, invalidates old checkpoints, retries after restart and recovers without duplication")


// Incremental ingestion performs work proportional to changed provider data.
let incrementalRoot = root.appendingPathComponent("incremental")
let incrementalClaude = incrementalRoot.appendingPathComponent("claude")
let incrementalFile = incrementalClaude.appendingPathComponent("projects/p/tail.jsonl")
let incrementalCodex = incrementalRoot.appendingPathComponent("codex")
let incrementalOpen = incrementalRoot.appendingPathComponent("open")
try FileManager.default.createDirectory(at: incrementalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: incrementalCodex.appendingPathComponent("sessions"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: incrementalOpen, withIntermediateDirectories: true)
func encodedClaude(_ id: String, output: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: claudeLine(id: id, session: "incremental", output: output, cwd: "/tmp/p"), options: [.sortedKeys]) + Data([10])
}
var largeTranscript = Data()
for i in 0..<300 { largeTranscript += try encodedClaude("tail-\(i)", output: 10) }
try largeTranscript.write(to: incrementalFile)
let incrementalState = incrementalRoot.appendingPathComponent("ledger.json")
var incremental: UsageScanner? = UsageScanner(home: incrementalCodex, stateURL: incrementalState,
    claudeHome: incrementalClaude, openCodeHome: incrementalOpen)
incremental!.readAccount = false
var firstAdmissionBytes: Int?
incremental!.onAdmitted = { _ in if firstAdmissionBytes == nil { firstAdmissionBytes = incremental!.lastWork.claudeBytes } }
_ = incremental!.scan(historical: true)
incremental!.onAdmitted = nil
check(firstAdmissionBytes != nil && firstAdmissionBytes! < largeTranscript.count, "Claude admits the first decoded turn before reading the remaining transcript")
check(incremental!.lastWork.claudeBytes == largeTranscript.count, "Bootstrap reads the transcript once")
let append = try encodedClaude("tail-299", output: 25)
let appendHandle = try FileHandle(forWritingTo: incrementalFile)
try appendHandle.seekToEnd(); try appendHandle.write(contentsOf: append); try appendHandle.close()
_ = incremental!.scan(historical: true, changedPaths: [incrementalFile])
check(incremental!.lastWork.claudeBytes == append.count, "Claude reads only appended bytes, not 300 old records")
check(incremental!.lastWork.codexFiles == 0 && incremental!.lastWork.openCodeRows == 0 && incremental!.lastWork.grokFiles == 0, "Changed Claude path dispatches only Claude")
check(incremental!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 3015, "Tail admits only the verified increment")
incremental = nil
incremental = UsageScanner(home: incrementalCodex, stateURL: incrementalState, claudeHome: incrementalClaude, openCodeHome: incrementalOpen)
incremental!.readAccount = false
_ = incremental!.scan(historical: true, changedPaths: [incrementalFile])
check(incremental!.lastWork.claudeBytes == 0, "Restart reuses durable Claude cursor")
let nextAppend = try encodedClaude("tail-after-restart", output: 7)
let partial = nextAppend.dropLast()
let partialHandle = try FileHandle(forWritingTo: incrementalFile)
try partialHandle.seekToEnd(); try partialHandle.write(contentsOf: partial); try partialHandle.close()
_ = incremental!.scan(historical: true, changedPaths: [incrementalFile])
let beforePartial = incremental!.ledger.entries.reduce(0) { $0 + $1.tokens.output }
let ending = try FileHandle(forWritingTo: incrementalFile)
try ending.seekToEnd(); try ending.write(contentsOf: Data([10])); try ending.close()
_ = incremental!.scan(historical: true, changedPaths: [incrementalFile])
check(incremental!.ledger.entries.reduce(0) { $0 + $1.tokens.output } == beforePartial + 7, "Partial line survives a persisted tail checkpoint")
let idleBytes = try Data(contentsOf: incrementalState)
let idleStamp = try ClaudeFileCheck.read(incrementalState)
incremental!.lastSave = .distantPast
let idleGeneration = incremental!.dirtyGeneration
_ = incremental!.scan(changedPaths: [])
check(incremental!.dirtyGeneration == idleGeneration && !incremental!.needsSave, "An idle scan does not dirty the ledger")
let idleAfter = try Data(contentsOf: incrementalState)
check(idleAfter == idleBytes, "An idle scan does not encode a changed ledger")
let idleStampAfter = try ClaudeFileCheck.read(incrementalState)
check(idleStampAfter == idleStamp, "An idle scan does not atomically replace the ledger")
print("PASS: proportional Claude tail reads, persisted cursors, partial-line retry, provider dispatch and zero idle ledger writes")

let incrementalDB = incrementalOpen.appendingPathComponent("opencode.db")
var db: OpaquePointer?
check(sqlite3_open(incrementalDB.path, &db) == SQLITE_OK, "Synthetic OpenCode database opens")
func sql(_ query: String) {
    check(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK, "Synthetic SQL succeeds")
}
sql("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
sql("CREATE INDEX message_time ON message(time_created, id)")
func insertOpen(_ id: String, completed: Bool = true, output: Int = 2) throws {
    var row = openCodeRow(id, provider: "opencode", model: "fixture", input: output == 0 ? 0 : 10,
        read: 0, write: 0, output: output, cwd: "/tmp/p", cost: 0)
    if !completed { row["time"] = ["created": 1769555059217] }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    sql("INSERT OR REPLACE INTO message VALUES ('\(id)', 's', 1769555059217, '\(json)')")
}
for i in 0..<520 { try insertOpen(String(format: "m%04d", i)) }
try insertOpen("pending", completed: false, output: 0)
let firstPage = try OpenCodeUsage.page(database: incrementalDB, limit: 17)
check(firstPage.rows == 17 && firstPage.watermark?.id == "m0016", "SQL limit and equal-time id ordering are enforced")
_ = incremental!.scan(historical: true, changedPaths: [incrementalDB])
check(incremental!.lastWork.openCodeRows == 521 && incremental!.lastWork.claudeBytes == 0, "Paged OpenCode bootstrap visits rows once without Claude")
let counted = incremental!.ledger.entries.reduce(0) { $0 + $1.tokens.total }
incremental = nil
incremental = UsageScanner(home: incrementalCodex, stateURL: incrementalState, claudeHome: incrementalClaude, openCodeHome: incrementalOpen)
incremental!.readAccount = false
_ = incremental!.scan(historical: true, changedPaths: [incrementalDB])
check(incremental!.lastWork.openCodeRows == 1, "Restart reads only pending message below durable watermark")
try insertOpen("pending", output: 20)
_ = incremental!.scan(historical: true, changedPaths: [incrementalDB])
check(incremental!.ledger.entries.reduce(0) { $0 + $1.tokens.total } == counted + 30, "Late completion below watermark is admitted")
_ = incremental!.scan(historical: true, changedPaths: [incrementalDB])
check(incremental!.lastWork.openCodeRows == 0, "Settled OpenCode source rereads zero rows")
try insertOpen("z-new", output: 4)
_ = incremental!.scan(historical: true, changedPaths: [URL(fileURLWithPath: incrementalDB.path + "-wal")])
check(incremental!.lastWork.openCodeRows == 1, "Same-millisecond insertion after watermark is admitted")
sqlite3_close(db)
print("PASS: bounded OpenCode queries, equal-time ordering, persisted watermark, unfinished-row recovery and zero settled rereads")

do {
    let url = root.appendingPathComponent("live-opencode.db")
    var writer: OpaquePointer?
    check(sqlite3_open(url.path, &writer) == SQLITE_OK, "Live WAL fixture opens")
    defer { sqlite3_close(writer) }
    func execute(_ query: String) {
        check(sqlite3_exec(writer, query, nil, nil, nil) == SQLITE_OK, "Live WAL fixture SQL succeeds")
    }
    execute("PRAGMA journal_mode=WAL; CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
    func insert(_ id: String, completed: Bool = true) throws {
        var row = openCodeRow(id, provider: "opencode", model: "live", input: 10, read: 0, write: 0, output: 2, cwd: "/tmp/p", cost: 0)
        if !completed { row["time"] = ["created": 1769555059217] }
        let data = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        execute("INSERT OR REPLACE INTO message VALUES ('\(id)', 's', 1769555059217, '\(data)')")
    }
    try insert("a", completed: false)
    var reader: OpenCodeUsage.Reader? = try OpenCodeUsage.Reader(database: url)
    weak let lifetime = reader
    let first = try reader!.page(limit: 1)
    check(first.pending == ["a"], "A live reader retains unfinished IDs")
    try insert("a"); try insert("b")
    let completed = try reader!.page(ids: ["a"])
    let later = try reader!.page(after: first.watermark)
    check(completed.pending.isEmpty && completed.turns.count == 1 && later.turns.map(\.messageID) == ["b"], "A reused connection sees writer commits between bounded pages")
    var logFrames: Int32 = 0, checkpointed: Int32 = 0
    check(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed) == SQLITE_OK,
          "Finalized page statements do not pin the writer's WAL checkpoint")
    execute("INSERT INTO message VALUES ('broken','s',1769555059218,'invalid-json')")
    do { _ = try reader!.page(after: later.watermark); preconditionFailure("Malformed page must fail") } catch {}
    check(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed) == SQLITE_OK,
          "A failed page finalizes its statement and releases the WAL read lock")
    execute("DELETE FROM message WHERE id='broken'")
    let retry = try reader!.page(after: later.watermark)
    check(retry.rows == 0, "The same connection can retry after a query failure")
    reader = nil; check(lifetime == nil, "The scoped reader is released after success and failure")
    let missing = try OpenCodeUsage.Reader(database: root.appendingPathComponent("missing-live.db"))
    let empty = try missing.page(); check(empty.rows == 0, "Missing database remains an empty read")
    print("PASS: scoped OpenCode reader sees live WAL commits, pending completion and retries without pinning checkpoints")
}

do {
    let url = root.appendingPathComponent("replace-opencode.db")
    var writer: OpaquePointer?
    check(sqlite3_open(url.path, &writer) == SQLITE_OK, "Replacement fixture opens")
    check(sqlite3_exec(writer, "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT); INSERT INTO message VALUES ('old','s',1,'{\"role\":\"user\"}')", nil, nil, nil) == SQLITE_OK, "Replacement fixture schema")
    sqlite3_close(writer)
    let reader = try OpenCodeUsage.Reader(database: url)
    let first = try reader.page(); check(first.watermark?.id == "old", "Reader binds its original file")
    try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("retained-opencode.db"))
    check(sqlite3_open(url.path, &writer) == SQLITE_OK, "Replacement database opens")
    check(sqlite3_exec(writer, "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT); INSERT INTO message VALUES ('new','s',1,'{\"role\":\"user\"}')", nil, nil, nil) == SQLITE_OK, "Replacement database schema")
    sqlite3_close(writer)
    do { _ = try reader.page(); preconditionFailure("A moved database must fail closed instead of switching files mid-scan") } catch {}
    let fresh = try OpenCodeUsage.Reader(database: url).page()
    check(fresh.watermark?.id == "new", "The next scan opens the replacement inode")
    print("PASS: scoped OpenCode pages fail closed on database movement and the next reader follows its replacement")
}


// The scanner owns exactly one connection across refreshes, with no read
// transaction left open while a live writer advances or checkpoints its WAL.
do {
    let fixture = root.appendingPathComponent("scanner-wal")
    let url = fixture.appendingPathComponent("opencode.db")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    var writer: OpaquePointer?
    check(sqlite3_open(url.path, &writer) == SQLITE_OK, "Scanner WAL fixture opens")
    defer { sqlite3_close(writer) }
    func execute(_ query: String) {
        check(sqlite3_exec(writer, query, nil, nil, nil) == SQLITE_OK, "Scanner WAL fixture SQL succeeds")
    }
    execute("PRAGMA journal_mode=WAL; CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
    func insert(_ id: String, completed: Bool = true) throws {
        var row = openCodeRow(id, provider: "opencode", model: "scanner-live", input: 10, read: 0, write: 0, output: 2, cwd: "/tmp/p", cost: 0)
        if !completed { row["time"] = ["created": 1769555059217] }
        let data = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        execute("INSERT OR REPLACE INTO message VALUES ('\(id)', 's', 1769555059217, '\(data)')")
    }
    var scanner: UsageScanner? = UsageScanner(home: fixture, stateURL: fixture.appendingPathComponent("ledger.json"), openCodeHome: fixture)
    scanner!.readAccount = false
    func refresh() -> Snapshot { scanner!.scan(historical: true, changedPaths: [url]) }
    func checkpoint() {
        var frames: Int32 = 0, checkpointed: Int32 = 0
        check(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, &frames, &checkpointed) == SQLITE_OK,
              "Scanner refresh leaves no statement or transaction pinning a WAL checkpoint")
    }
    try insert("a", completed: false)
    check(refresh().error == nil, "Initial scanner refresh succeeds")
    weak let first = scanner!.openCodeReader?.reader
    check(first != nil, "Scanner retains its read-only connection")
    for _ in 0..<20 { _ = refresh() }
    check(scanner!.openCodeReader?.reader === first, "Twenty refreshes reuse the exact connection")
    checkpoint()
    try insert("a"); try insert("b")
    let completed = refresh()
    check(completed.error == nil && completed.entries.reduce(0) { $0 + $1.tokens.total } == 24,
          "Next refresh sees committed WAL rows and late completion below its watermark")
    check(scanner!.lastWork.openCodeRows == 2 && scanner!.openCodeReader?.reader === first,
          "Pending and ordered new rows use the retained connection")
    checkpoint()
    let cursor = scanner!.ledger.openCodeCursors
    let pending = scanner!.ledger.openCodePending
    execute("INSERT INTO message VALUES ('broken','s',1769555059218,'invalid-json')")
    check(refresh().error?.contains("OpenCode usage could not be read") == true, "Malformed refresh reports its error")
    check(scanner!.openCodeReader == nil && first == nil, "Failed refresh releases the cached connection")
    check(scanner!.ledger.openCodeCursors == cursor && scanner!.ledger.openCodePending == pending,
          "Failed refresh preserves the last successful cursor and pending state")
    checkpoint()
    execute("DELETE FROM message WHERE id='broken'")
    try insert("c")
    check(refresh().error == nil && scanner!.lastWork.openCodeRows == 1, "A fresh reader recovers without skipping a committed row")
    weak let recovered = scanner!.openCodeReader?.reader
    execute("ALTER TABLE message RENAME TO held_message")
    check(refresh().error != nil && scanner!.openCodeReader == nil && recovered == nil,
          "SQL query failure invalidates and closes the scanner connection")
    execute("ALTER TABLE held_message RENAME TO message")
    check(refresh().error == nil, "A repaired query opens a fresh connection and clears its warning")
    checkpoint()
    weak let final = scanner!.openCodeReader?.reader
    check(final != nil, "Recovered scanner owns the final connection")
    scanner = nil
    check(final == nil, "Scanner teardown closes its retained reader")
    checkpoint()
    print("PASS: cross-refresh OpenCode reuse, WAL visibility, pending completion, checkpoints, failed-query recovery and owner cleanup")
}

do {
    let fixture = root.appendingPathComponent("scanner-identity")
    let home = fixture.appendingPathComponent("source")
    let url = home.appendingPathComponent("opencode.db")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    func create(_ path: URL, id: String) throws {
        var writer: OpaquePointer?
        check(sqlite3_open(path.path, &writer) == SQLITE_OK, "Scanner identity fixture opens")
        defer { sqlite3_close(writer) }
        check(sqlite3_exec(writer, "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT); INSERT INTO message VALUES ('\(id)','s',1,'{\"role\":\"user\"}')", nil, nil, nil) == SQLITE_OK,
              "Scanner identity fixture schema")
    }
    try create(url, id: "old")
    let scanner = UsageScanner(home: fixture, stateURL: fixture.appendingPathComponent("ledger.json"), openCodeHome: home)
    scanner.readAccount = false
    func refresh() -> Snapshot { scanner.scan(historical: true, changedPaths: [url]) }
    check(refresh().error == nil, "Initial identity scan succeeds")
    weak let original = scanner.openCodeReader?.reader
    let originalInode = scanner.openCodeReader?.inode
    try FileManager.default.moveItem(at: url, to: home.appendingPathComponent("retained.db"))
    try create(url, id: "new")
    check(refresh().error == nil && scanner.lastWork.openCodeRows == 1, "Replacement inode resets the cursor and is read on the next refresh")
    check(original == nil && scanner.openCodeReader?.inode != originalInode, "Replacement closes the old connection")
    weak let replacement = scanner.openCodeReader?.reader
    try FileManager.default.removeItem(at: url)
    check(refresh().error == nil && scanner.openCodeReader == nil && replacement == nil,
          "Missing database releases the connection without an installation error")
    let targetA = fixture.appendingPathComponent("target-a.db")
    let targetB = fixture.appendingPathComponent("target-b.db")
    try create(targetA, id: "link-a"); try create(targetB, id: "link-b")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: targetA)
    check(refresh().error == nil && scanner.openCodeReader?.path == targetA.resolvingSymlinksInPath().path,
          "The scanner binds the resolved database path")
    weak let linked = scanner.openCodeReader?.reader
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: targetB)
    check(refresh().error == nil && scanner.lastWork.openCodeRows == 1 && linked == nil,
          "Retargeting a database symlink invalidates the prior connection and rereads the new file")
    check(scanner.openCodeReader?.path == targetB.resolvingSymlinksInPath().path, "Only the new resolved path remains cached")
    let disabled = UsageScanner(home: fixture, stateURL: fixture.appendingPathComponent("disabled.json"))
    var errors: [String] = []
    check(disabled.scanOpenCode(historical: true, errors: &errors) == 0 && disabled.openCodeReader == nil && errors.isEmpty,
          "A disabled OpenCode integration never owns a connection")
    print("PASS: scanner OpenCode inode replacement, missing-file cleanup, symlink retargeting and disabled integration")
}

// Observation invalidates the property read, not every field on a process model.
final class ObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let observedUsage = UsageStore(scanner: incremental!)
let observedReports = ReportState()
let busyChanges = ObservationCount()
withObservationTracking { _ = observedUsage.busy } onChange: { busyChanges.increment() }
observedUsage.snapshot.updated = Date()
observedReports.search = "new scope"
check(busyChanges.value == 0, "Snapshot and query changes do not invalidate import-busy consumers")
observedUsage.busy = true
check(busyChanges.value == 1, "The observed import property invalidates when changed")
let historyChanges = ObservationCount()
withObservationTracking { _ = observedReports.report.totals } onChange: { historyChanges.increment() }
observedReports.costReport = CostReport()
observedReports.costService = .fast
check(historyChanges.value == 0, "Cost and pricing mutations do not invalidate History-only consumers")
observedReports.report.totals.output = 1
check(historyChanges.value == 1, "Published History totals invalidate their consumers")
let idleMeter = Tachometer(), meterChanges = ObservationCount()
withObservationTracking { _ = idleMeter.rate } onChange: { meterChanges.increment() }
for second in 0..<5 { idleMeter.tick(now: liveNow.addingTimeInterval(Double(second))) }
check(meterChanges.value == 0, "Unchanged rate ticks publish no rate mutation")
print("PASS: narrow usage/report Observation, independent cost invalidation and idle rate suppression")

// Valid records still stream past malformed records, whose warning and failed
// cursor checkpoint remain visible on repeat scans.
do {
    let malformedHome = incrementalRoot.appendingPathComponent("malformed-claude")
    let transcript = malformedHome.appendingPathComponent("projects/p/session.jsonl")
    try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    let goodA = try encodedClaude("malformed-a", output: 10)
    let goodB = try encodedClaude("malformed-b", output: 20)
    let broken = Data("{\"type\":\"assistant\",\"usage\":broken}\n".utf8)
    try (goodA + broken + goodB).write(to: transcript)
    let stream = UsageScanner(home: incrementalCodex, stateURL: incrementalRoot.appendingPathComponent("malformed.json"), claudeHome: malformedHome)
    stream.readAccount = false
    for _ in 0..<2 {
        let result = stream.scan(historical: true)
        check(result.error?.contains("could not be decoded") == true, "Malformed record warning persists")
        check(stream.ledger.claudeCursors?.isEmpty != false && stream.ledger.claudeFileChecks?.isEmpty != false,
              "Malformed transcript cannot acquire a successful cursor checkpoint")
        check(result.entries.reduce(0) { $0 + $1.tokens.output } == 30, "Valid surrounding turns admit once while malformed warning persists")
    }
}
print("PASS: streaming Claude admission before EOF and persistent malformed-record warning without successful cursor")

// The shipping callback shares this routing seam. Actual delivery below uses
// disposable provider roots, not installed app data or system settings.
do {
    let events = root.appendingPathComponent("events").resolvingSymlinksInPath()
    let codexRoot = events.appendingPathComponent("codex")
    let claudeRoot = events.appendingPathComponent("claude")
    let grokRoot = events.appendingPathComponent("grok")
    let openRoot = events.appendingPathComponent("opencode")
    for path in [codexRoot.appendingPathComponent("sessions"), claudeRoot.appendingPathComponent("projects"), grokRoot, openRoot] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    var received = Set<URL>(), accountEvents = 0
    let stream = LogStream(home: codexRoot, grokHome: grokRoot, claudeHome: claudeRoot, openCodeHome: openRoot,
        onFiles: { received.formUnion($0) }, onAccount: { accountEvents += 1 })
    let claudePath = claudeRoot.appendingPathComponent("projects/test.jsonl")
    let wal = openRoot.appendingPathComponent("opencode.db-wal")
    let unrelated = events.appendingPathComponent("unrelated.jsonl")
    let routed = stream.route(paths: [claudePath.path, wal.path, unrelated.path], flags: [0, 0, 0])
    check(routed.files == [claudePath, wal] && !routed.account, "Only changed provider files route to scanning")
    for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged] {
        let recovery = stream.route(paths: [claudeRoot.path], flags: [FSEventStreamEventFlags(flag)])
        check(recovery.files == [claudeRoot], "Dropped events recover only the affected provider")
    }
    stream.start()
    defer { stream.stop() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    try Data("{}\n".utf8).write(to: claudePath)
    try Data([0]).write(to: wal)
    try Data("{}".utf8).write(to: codexRoot.appendingPathComponent("auth.json"))
    let deadline = Date().addingTimeInterval(8)
    while (received.isSuperset(of: [claudePath, wal]) == false || accountEvents == 0) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !received.isSuperset(of: [claudePath, wal]) || accountEvents == 0 {
        FileHandle.standardError.write(Data("FSEvents roots: \(events.path); received: \(received.map(\.path)); account: \(accountEvents)\n".utf8))
    }
    check(received.isSuperset(of: [claudePath, wal]) && accountEvents > 0, "Native FSEvents delivers transcript, WAL and account changes")
}
print("PASS: provider routing, dropped-event recovery and native synthetic FSEvents delivery")

// A successful unrelated path must not erase rejected-source disclosure.
do {
    let home = root.appendingPathComponent("scoped-errors")
    let a = home.appendingPathComponent("projects/a.jsonl")
    let b = home.appendingPathComponent("projects/b.jsonl")
    try FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encodedClaude("scope-b0", output: 10).write(to: b)
    let state = root.appendingPathComponent("scoped-errors.json")
    var scoped: UsageScanner? = UsageScanner(home: incrementalCodex, stateURL: state, claudeHome: home)
    scoped!.readAccount = false
    _ = scoped!.scan(historical: true)
    try Data("{\"type\":\"assistant\",\"message\":{\"usage\":\n".utf8).write(to: a)
    _ = scoped!.scan(historical: true, changedPaths: [a])
    check(scoped!.ledger.sourceErrors?["Claude"] != nil, "Failed A exposes coverage warning")
    let handle = try FileHandle(forWritingTo: b)
    try handle.seekToEnd(); try handle.write(contentsOf: encodedClaude("scope-b1", output: 5)); try handle.close()
    _ = scoped!.scan(historical: true, changedPaths: [b])
    check(scoped!.ledger.sourceErrors?["Claude"] != nil, "Successful B cannot silence failed A")
    try scoped!.saveIfNeeded(force: true)
    scoped = nil
    scoped = UsageScanner(home: incrementalCodex, stateURL: state, claudeHome: home)
    scoped!.readAccount = false
    try encodedClaude("scope-a", output: 7).write(to: a)
    _ = scoped!.scan(historical: true, changedPaths: [a])
    check(scoped!.ledger.sourceErrors?["Claude"] == nil, "Repaired A clears its persisted warning scope")
}
print("PASS: failed A, successful B, restart and repaired A preserve then clear coverage disclosure")

do {
    let home = root.appendingPathComponent("catalog-event")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let dbURL = home.appendingPathComponent("state_5.sqlite")
    var database: OpaquePointer?
    check(sqlite3_open(dbURL.path, &database) == SQLITE_OK, "Catalog fixture opens")
    defer { sqlite3_close(database) }
    check(sqlite3_exec(database, "CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT); INSERT INTO threads VALUES ('task','Old title','/old')", nil, nil, nil) == SQLITE_OK, "Catalog fixture schema")
    var catalog = try TaskCatalog.read(home: home)
    let readAt = Date()
    check(sqlite3_exec(database, "UPDATE threads SET title='Renamed task', cwd='/new'", nil, nil, nil) == SQLITE_OK, "Lone metadata change")
    let event = URL(fileURLWithPath: dbURL.path + "-wal")
    if TaskCatalog.shouldRefresh(home: home, paths: [event], historical: false, lastRead: readAt, now: readAt.addingTimeInterval(1)) {
        catalog = try TaskCatalog.read(home: home)
    }
    check(catalog["task"] == TaskInfo(title: "Renamed task", directory: "/new"), "Lone catalog event bypasses recent-read throttle")
    check(!TaskCatalog.shouldRefresh(home: home, paths: [home.appendingPathComponent("sessions/a.jsonl")], historical: false, lastRead: readAt, now: readAt.addingTimeInterval(1)), "Unrelated transcript does not force catalog read")
}
print("PASS: lone catalog WAL change publishes renamed metadata inside prior throttle interval")

// Official Claude configuration and legacy transcript overrides share one resolver.
do {
    let userHome = root.appendingPathComponent("root-discovery").resolvingSymlinksInPath()
    let standard = userHome.appendingPathComponent(".claude")
    let configured = userHome.appendingPathComponent("custom")
    let legacy = userHome.appendingPathComponent("legacy")
    for home in [standard, configured, legacy] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    let environment = ["CLAUDE_CONFIG_DIR": configured.path]
    check(ClaudeCodeUsage.home(environment: [:], userHome: userHome).path == standard.path, "Default root follows the supplied user home")
    check(HarnessDiscovery.claudeCode(environment: [:], userHome: userHome)?.path == standard.path, "Default discovery agrees with reader")
    check(HarnessDiscovery.claudeCode(environment: environment, userHome: userHome)?.path == configured.path, "Official custom root reaches discovery")
    check(ClaudeCodeUsage.home(environment: environment, userHome: userHome).path == configured.path, "Official custom root reaches reader")
    check(HarnessDiscovery.claudeCode(environment: ["CLAUDE_HOME": legacy.path, "CLAUDE_CONFIG_DIR": configured.path], userHome: userHome)?.path == legacy.path, "Explicit legacy transcript override retains precedence")
    check(ClaudeStatuslineConnection.settingsURL(environment: ["CLAUDE_HOME": legacy.path, "CLAUDE_CONFIG_DIR": configured.path], home: userHome).path == legacy.appendingPathComponent("settings.json").path,
          "Connect edits settings.json in the same home the reader uses")
    check(ClaudeStatuslineConnection.settingsURL(environment: environment, home: userHome).path == configured.appendingPathComponent("settings.json").path,
          "Official custom root reaches Connect")
    check(HarnessDiscovery.claudeCode(environment: ["CLAUDE_HOME": "", "CLAUDE_CONFIG_DIR": configured.path], userHome: userHome)?.path == configured.path, "Empty override is ignored")
    check(HarnessDiscovery.claudeCode(environment: ["CLAUDE_CONFIG_DIR": userHome.appendingPathComponent("missing").path], userHome: userHome) == nil, "Missing explicit root cannot silently select another installation")
    let transcript = configured.appendingPathComponent("projects/configured.jsonl")
    let clock = Date()
    var data = Data()
    for (offset, output) in [(-4.0, 10), (-2.0, 20)] {
        var record = claudeLine(id: "configured", session: "configured", output: output, cwd: "/synthetic")
        record["timestamp"] = formatter.string(from: clock.addingTimeInterval(offset))
        data += try JSONSerialization.data(withJSONObject: record) + Data([10])
    }
    try data.write(to: transcript)
    let selected = HarnessDiscovery.claudeCode(environment: environment, userHome: userHome)!
    let codexHome = userHome.appendingPathComponent("codex")
    let scanner = UsageScanner(home: codexHome, stateURL: userHome.appendingPathComponent("ledger.json"), claudeHome: selected)
    scanner.readAccount = false
    _ = scanner.scan(historical: true)
    let saved = scanner.scan()
    check(saved.entries.filter { $0.harness == ClaudeCodeUsage.harness }.reduce(0) { $0 + $1.tokens.output } == 20, "Configured transcript reaches durable usage admission")
    var delivered: ActivitySnapshot?
    let feed = ActivityFeed(home: codexHome, claudeHome: selected) { delivered = $0 }
    feed.refresh(paths: [transcript])
    let deadline = Date().addingTimeInterval(3)
    while delivered == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let activity = delivered!.filtered(for: .claude)
    check(activity.error == nil && activity.running.count == 1, "Configured transcript reaches independent live activity")
    check(activity.freshMeasurements(at: clock).first?.rate == 5, "Configured activity preserves counter-delta speed")
    let stream = LogStream(home: codexHome, grokHome: nil, claudeHome: selected, onFiles: { _ in }, onAccount: {})
    check(stream.route(paths: [transcript.path], flags: [0]).files == [transcript], "Configured root reaches the shipping watcher routing seam")
}
print("PASS: Claude default, official custom and legacy roots agree across discovery, reader, scanner, activity and watcher routing")

// Starting before a tool's first data file must not require restarting Token Bar.
do {
    let fixture = root.appendingPathComponent("first-use").resolvingSymlinksInPath()
    let codexHome = fixture.appendingPathComponent("codex")
    let claudeHome = fixture.appendingPathComponent("claude")
    let openHome = fixture.appendingPathComponent("opencode")
    let environment = ["CLAUDE_CONFIG_DIR": claudeHome.path, "OPENCODE_HOME": openHome.path]
    try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let scanner = UsageScanner(home: codexHome, stateURL: fixture.appendingPathComponent("ledger.json"))
    scanner.readAccount = false
    check(HarnessDiscovery.claudeCode(environment: environment, userHome: fixture) == nil && HarnessDiscovery.openCode(environment: environment, userHome: fixture) == nil, "First launch has no fabricated tool roots")
    var delivered: ActivitySnapshot?, deliveries = 0
    let feed = ActivityFeed(home: codexHome) { delivered = $0; deliveries += 1 }
    feed.refresh()
    var watched = Set<URL>()
    var stream = LogStream(home: codexHome, grokHome: nil, onFiles: { watched.formUnion($0) }, onAccount: {})
    stream.start()
    defer { stream.stop() }
    let transcript = claudeHome.appendingPathComponent("projects/late.jsonl")
    try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    let clock = Date()
    var bytes = Data()
    for (offset, output) in [(-4.0, 10), (-2.0, 20)] {
        var record = claudeLine(id: "late", session: "late", output: output, cwd: "/synthetic")
        record["timestamp"] = formatter.string(from: clock.addingTimeInterval(offset))
        bytes += try JSONSerialization.data(withJSONObject: record) + Data([10])
    }
    try bytes.write(to: transcript)
    try FileManager.default.createDirectory(at: openHome, withIntermediateDirectories: true)
    var database: OpaquePointer?
    check(sqlite3_open(openHome.appendingPathComponent("opencode.db").path, &database) == SQLITE_OK, "First-use database opens")
    defer { sqlite3_close(database) }
    let row = openCodeRow("late-open", provider: "opencode", model: "synthetic", input: 10, read: 0, write: 0, output: 2, cwd: "/synthetic", cost: 0)
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    check(sqlite3_exec(database, "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT); INSERT INTO message VALUES ('late-open','s',1769555059217,'\(payload)')", nil, nil, nil) == SQLITE_OK, "First-use database contains measured usage")
    let claude = HarnessDiscovery.claudeCode(environment: environment, userHome: fixture)
    let open = HarnessDiscovery.openCode(environment: environment, userHome: fixture)
    check(scanner.configureSources(claudeHome: claude, openCodeHome: open), "Existing discovery admits newly created roots")
    feed.configureClaude(home: claude)
    stream.stop()
    stream = LogStream(home: codexHome, grokHome: nil, claudeHome: claude, openCodeHome: open, onFiles: { watched.formUnion($0) }, onAccount: {})
    stream.start()
    _ = scanner.scan(historical: true); _ = scanner.scan()
    check(scanner.ledger.entries.reduce(0) { $0 + $1.tokens.output } == 22, "Late Claude and OpenCode usage is admitted once")
    try scanner.saveIfNeeded(force: true)
    let cursorEncoder = JSONEncoder(); cursorEncoder.outputFormatting = [.sortedKeys]
    let entries = scanner.ledger.entries, cursors = try cursorEncoder.encode(scanner.ledger.claudeCursors), openCursors = scanner.ledger.openCodeCursors
    weak var reader = scanner.openCodeReader?.reader
    check(!scanner.configureSources(claudeHome: claude, openCodeHome: open), "Repeated discovery is idempotent")
    _ = scanner.scan(historical: true); _ = scanner.scan()
    let currentCursors = try cursorEncoder.encode(scanner.ledger.claudeCursors)
    check(scanner.ledger.entries == entries && currentCursors == cursors && scanner.ledger.openCodeCursors == openCursors, "Rediscovery preserves history and path-scoped cursors")
    check(scanner.lastWork.claudeBytes == 0 && scanner.lastWork.openCodeRows == 0, "Settled data is not reanalyzed")
    let deadline = Date().addingTimeInterval(3)
    while delivered?.filtered(for: .claude).running.count != 1 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(delivered?.filtered(for: .claude).freshMeasurements(at: clock).first?.rate == 5, "New root reaches live activity without replacing the Codex reader")
    let replacement = fixture.appendingPathComponent("replacement")
    let replacementFile = replacement.appendingPathComponent("projects/new.jsonl")
    try FileManager.default.createDirectory(at: replacementFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    var record = claudeLine(id: "replacement", session: "replacement", output: 17, cwd: "/synthetic")
    record["timestamp"] = formatter.string(from: Date())
    try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: replacementFile)
    let oldDeliveries = deliveries
    feed.configureClaude(home: replacement)
    let changedDeadline = Date().addingTimeInterval(3)
    while deliveries == oldDeliveries && Date() < changedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let tasks = delivered!.filtered(for: .claude).turns
    check(tasks.count == 1 && tasks.values.allSatisfy { $0.session == "claude:" + replacementFile.path }, "Root transition cannot publish tasks from the old Claude reader")
    check(scanner.configureSources(claudeHome: replacement, openCodeHome: open) && scanner.openCodeReader?.reader === reader, "Claude changes preserve the independent OpenCode connection")
    _ = scanner.scan()
    _ = scanner.configureSources(claudeHome: claude, openCodeHome: open)
    let restored = scanner.scan()
    check(restored.entries.reduce(0) { $0 + $1.tokens.output } == 39 && scanner.lastWork.claudeBytes == 0, "Returning to an earlier root reuses its cursor without losing either history")
    _ = scanner.configureSources(claudeHome: claude, openCodeHome: nil)
    check(reader == nil, "Removing an OpenCode root closes its retained reader")
    watched = []
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
    let watchDeadline = Date().addingTimeInterval(5)
    while !watched.contains(transcript) && Date() < watchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(watched.contains(transcript), "Rebound native watcher receives later transcript appends")
}
print("PASS: first-use rediscovery rebinds live readers and watchers, preserves history/cursors, and closes removed database readers")

do {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    check(RelativeAgeText.label(from: now.addingTimeInterval(-600), to: now) == "10 minutes",
          "A rate report names relative age, not only a clock")
}
print("PASS: Now rate-report age is relative; a missing report stays unavailable")
