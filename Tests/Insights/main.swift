import Foundation
import SQLite3
let now = Date()
let sample = [
    PromptRecord(text: "Please fix teh Rust build", date: now, task: "one"),
    PromptRecord(text: "please  fix teh rust build", date: now, task: "two"),
    PromptRecord(text: "Review Swift\n```\npython teh\n```\n> python teh", date: now, task: "one"),
    PromptRecord(text: "# AGENTS.md instructions\npython teh", date: now, task: "three")
]
assert(!InsightAnalysis.isUserPrompt("<codex_internal_context source=\"goal\">test Rust"))
assert(!InsightAnalysis.isUserPrompt("<skill>test Rust"))
assert(!InsightAnalysis.isUserPrompt("<codex_delegation>test Rust"))
assert(!InsightAnalysis.isUserPrompt("<heartbeat>test Rust"))
let r = InsightAnalysis.build(sample)
assert(r.prompts == 3 && r.polite == 2)
assert(r.languages.first?.label == "Rust" && r.languages.first?.count == 2)
assert(!r.languages.contains { $0.label == "Python" })
assert(r.repeats.first?.count == 2)
assert(r.typos.first?.count == 2)
assert(r.verbs.contains { $0.label == "fix" && $0.count == 2 })
assert(InsightAnalysis.build([]).prompts == 0)
print("PASS: prompt-only filtering, code/quote exclusion, language counts, repeated prompts, typo counts, action words, empty sample")

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
var db: OpaquePointer?
assert(sqlite3_open(folder.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
assert(sqlite3_exec(db, "CREATE TABLE threads(id TEXT, rollout_path TEXT, thread_source TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK)
let formatter = ISO8601DateFormatter()
func line(_ type: String, _ payload: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: now.addingTimeInterval(-10)), "payload": payload])
    return String(decoding: data, as: UTF8.self) + "\n"
}
let start = try line("event_msg", ["type": "task_started", "turn_id": "turn-one"])
let prompt = try line("response_item", ["type": "message", "role": "user", "id": "message-one", "content": [["type": "input_text", "text": "# AGENTS.md instructions Rust"], ["type": "input_text", "text": "Please fix teh Python build"]]])
let mirror = try line("event_msg", ["type": "user_message", "message": "Please fix teh Python build"])
let old = try line("event_msg", ["type": "user_message", "message": "Review Swift"])
for (index, content) in [start + prompt + mirror, start + prompt, old].enumerated() {
    let path = folder.appendingPathComponent("log\(index).jsonl")
    try content.write(to: path, atomically: true, encoding: .utf8)
    let sql = "INSERT INTO threads VALUES('task\(index)', '\(path.path)', 'user', \(Int(now.timeIntervalSince1970)))"
    assert(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
}
sqlite3_close(db)
let read = try InsightReader.read(home: folder, now: now)
assert(read.files == 3 && read.prompts == 2 && read.skipped == 0)
assert(read.languages.contains { $0.label == "Python" && $0.count == 1 })
assert(!read.languages.contains { $0.label == "Rust" })
assert(read.typos.first?.count == 1)
print("PASS: current message schema, legacy schema, context exclusion, copied message-ID deduplication, mirrored event exclusion")
var partialPrompts: [Int] = []
var checkedFiles: [Int] = []
var expectedFiles: [Int?] = []
let streamed = try InsightReader.read(home: folder, now: now, progress: { partialPrompts.append($0.prompts); checkedFiles.append($0.filesChecked); expectedFiles.append($0.filesTotal) })
assert(partialPrompts.count == 4 && partialPrompts.last == streamed.prompts)
assert(partialPrompts.first! == 0 && partialPrompts == partialPrompts.sorted())
print("PASS: prompt results arrive progressively without recounting copied messages")

var readState = PromptReadState()
assert(readState.result == nil && !readState.loading)
readState.begin()
assert(readState.loading && readState.result == nil)
readState.fail()
assert(readState.failed && readState.result == nil && !readState.message.contains("retained"))
var emptyRead = InsightAnalysis.build([])
emptyRead.readAt = now.addingTimeInterval(-600)
readState.begin(); readState.succeed(emptyRead)
assert(readState.completed && readState.result?.prompts == 0 && readState.message.contains("No human prompts"))
readState.begin()
assert(readState.result?.readAt == emptyRead.readAt && readState.loading)
readState.fail()
assert(readState.result?.readAt == emptyRead.readAt && readState.message.contains("Previous results"))
var partialRead = r
partialRead.files = 1; partialRead.skipped = 1
var partialState = PromptReadState()
partialState.begin(); partialState.receivePartial(partialRead)
assert(partialState.isPartial && !partialState.completed)
partialState.fail()
assert(partialState.result?.prompts == r.prompts && partialState.message.contains("partial sample"))
partialState.begin(); partialState.succeed(partialRead)
assert(partialState.completed && partialState.isPartial && partialState.message.contains("Partial results"))
var unreadable = PromptInsights(); unreadable.skipped = 2
var missingState = PromptReadState(); missingState.begin(); missingState.succeed(unreadable)
assert(missingState.failed && missingState.result == nil)
readState.begin(); readState.receivePartial(partialRead)
assert(readState.result?.prompts == 0, "A refresh cannot replace completed data with an interim sample")
readState.succeed(r)
assert(!readState.failed && readState.result?.prompts == r.prompts)
print("PASS: unavailable, loading, first failure, successful zero, partial sample, retained age, failed refresh and recovery")

@MainActor func awaitRead(_ model: InsightsModel) async {
    let deadline = Date().addingTimeInterval(5)
    while model.busy && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    assert(!model.busy, "The synthetic reader must complete")
}
let readModel = InsightsModel()
let absentHome = folder.appendingPathComponent("absent")
readModel.refresh(home: absentHome, force: true); await awaitRead(readModel)
assert(readModel.state.failed && readModel.state.result == nil)
readModel.refresh(home: folder, force: true); await awaitRead(readModel)
assert(readModel.state.completed && !readModel.state.failed)
let retainedPrompts = readModel.state.result!.prompts
let retainedDate = readModel.state.result!.readAt
readModel.refresh(home: absentHome, force: true); await awaitRead(readModel)
assert(readModel.state.failed && readModel.state.result?.prompts == retainedPrompts && readModel.state.result?.readAt == retainedDate)
print("PASS: asynchronous model first-read failure, successful reader recovery and stale retained result")

assert(checkedFiles == [0, 1, 2, 3] && expectedFiles.allSatisfy { $0 == 3 })
assert(streamed.filesChecked == 3 && streamed.filesTotal == 3)
var progressState = PromptReadState()
progressState.succeed(streamed)
progressState.begin()
var inFlight = PromptInsights(); inFlight.filesChecked = 1; inFlight.filesTotal = 3
progressState.receivePartial(inFlight)
assert(progressState.filesChecked == 1 && progressState.filesTotal == 3)
assert(progressState.result?.prompts == streamed.prompts)
progressState.fail()
assert(progressState.result?.readAt == streamed.readAt)
print("PASS: exact sampled-file progress includes unreadable files and advances while retaining successful results")

// Automatic retries share the success cooldown; a failed catalog never loops on every update.
var lazyNow = Date()
let lazyModel = InsightsModel(clock: { lazyNow })
lazyModel.refresh(home: absentHome); await awaitRead(lazyModel)
assert(lazyModel.state.failed)
lazyModel.refresh(home: folder)
assert(!lazyModel.busy && lazyModel.state.failed, "Automatic failure retry must wait")
lazyNow = lazyNow.addingTimeInterval(301)
lazyModel.refresh(home: folder); await awaitRead(lazyModel)
assert(lazyModel.state.completed && !lazyModel.state.failed)
let lazyDate = lazyModel.state.result!.readAt
assert(lazyDate == lazyNow, "Injected evaluation clock must reach the completed read timestamp")
lazyModel.refresh(home: absentHome)
assert(!lazyModel.busy && lazyModel.state.result?.readAt == lazyDate, "Completed results stay usable without a reread")
lazyNow = lazyNow.addingTimeInterval(301)
lazyModel.refresh(home: absentHome); await awaitRead(lazyModel)
assert(lazyModel.state.failed && lazyModel.state.result?.readAt == lazyDate)
print("PASS: quiet automatic refresh, failure cooldown, eventual retry and retained-result age")

var accumulated = InsightAnalysis.Accumulator()
for (index, record) in sample.enumerated() {
    accumulated.append(record)
    let partial = accumulated.snapshot()
    let batch = InsightAnalysis.build(Array(sample.prefix(index + 1)))
    assert(partial.prompts == batch.prompts && partial.words == batch.words && partial.medianWords == batch.medianWords)
    assert(partial.repeats.map(\.label) == batch.repeats.map(\.label))
    assert(partial.hours.map(\.count) == batch.hours.map(\.count))
}
assert(accumulated.snapshot().prompts == 3 && accumulated.snapshot().words == r.words)
print("PASS: incremental analysis preserves sampled results without reprocessing previous prompts")
