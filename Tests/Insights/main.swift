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

func waitUntil(_ deadline: Date, _ ready: () -> Bool) {
    while !ready() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
func awaitRead(_ model: InsightsModel) {
    waitUntil(Date().addingTimeInterval(5)) { !model.busy }
    assert(!model.busy, "The synthetic reader must complete")
}
let readModel = InsightsModel()
let absentHome = folder.appendingPathComponent("absent")
readModel.refresh(home: absentHome, force: true); awaitRead(readModel)
assert(readModel.state.failed && readModel.state.result == nil)
readModel.refresh(home: folder, force: true); awaitRead(readModel)
assert(readModel.state.completed && !readModel.state.failed)
let retainedPrompts = readModel.state.result!.prompts
let retainedDate = readModel.state.result!.readAt
readModel.refresh(home: absentHome, force: true); awaitRead(readModel)
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
lazyModel.refresh(home: absentHome); awaitRead(lazyModel)
assert(lazyModel.state.failed)
lazyModel.refresh(home: folder)
assert(!lazyModel.busy && lazyModel.state.failed, "Automatic failure retry must wait")
lazyNow = lazyNow.addingTimeInterval(301)
lazyModel.refresh(home: folder); awaitRead(lazyModel)
assert(lazyModel.state.completed && !lazyModel.state.failed)
let lazyDate = lazyModel.state.result!.readAt
assert(lazyDate == lazyNow, "Injected evaluation clock must reach the completed read timestamp")
lazyModel.refresh(home: absentHome)
assert(!lazyModel.busy && lazyModel.state.result?.readAt == lazyDate, "Completed results stay usable without a reread")
lazyNow = lazyNow.addingTimeInterval(301)
lazyModel.refresh(home: absentHome); awaitRead(lazyModel)
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

// Durable processing work: reopening, revisiting and adding one chat tail.
let indexDirectory = folder.appendingPathComponent("prompt-index")
let firstIndex = PromptIndex(directory: indexDirectory)
let indexed = try InsightReader.read(home: folder, now: now, index: firstIndex)
assert(firstIndex.bytesRead > 0 && firstIndex.promptsAnalyzed > 0)
try firstIndex.saveSummary(indexed, home: folder)
let reopenedIndex = PromptIndex(directory: indexDirectory)
let resumedSample = try InsightReader.read(home: folder, now: now, index: reopenedIndex)
assert(reopenedIndex.bytesRead == 0 && reopenedIndex.promptsAnalyzed == 0 && reopenedIndex.filesReused == 3)
assert(resumedSample.prompts == indexed.prompts && resumedSample.words == indexed.words)
let growingPath = folder.appendingPathComponent("log0.jsonl")
let newPrompt = try line("response_item", ["type": "message", "role": "user", "id": "new-message", "content": [["text": "PRIVATE_MARKER_4379 please review Rust"]]])
let append = try FileHandle(forWritingTo: growingPath)
try append.seekToEnd(); try append.write(contentsOf: Data(newPrompt.utf8)); try append.close()
let added = try InsightReader.read(home: folder, now: now, index: reopenedIndex)
assert(added.prompts == indexed.prompts + 1 && reopenedIndex.promptsAnalyzed == 1)
assert(reopenedIndex.bytesRead == newPrompt.utf8.count && reopenedIndex.filesReused == 2)
try reopenedIndex.saveSummary(added, home: folder)
let nextIndex = PromptIndex(directory: indexDirectory)
let stable = try InsightReader.read(home: folder, now: now, index: nextIndex)
assert(nextIndex.bytesRead == 0 && stable.prompts == added.prompts)
let restoredSummary = try nextIndex.restoreSummary(home: folder)
assert(restoredSummary?.words == added.words && restoredSummary?.readAt == added.readAt)
let differentHomeSummary = try nextIndex.restoreSummary(home: absentHome)
assert(differentHomeSummary == nil)
for file in try FileManager.default.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil) {
    let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    assert(!contents.contains("PRIVATE_MARKER_4379") && !contents.contains("please review Rust"), "No prompt text in durable indexes")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
print("PASS: durable chat index, zero-byte repeat/restart, exact appended-byte work, summary restore, home isolation and private prompt-free checkpoints")

// Incomplete lines must not advance their durable offset or admit partial text.
let partialPrompt = try line("response_item", ["type": "message", "role": "user", "id": "partial-message", "content": [["text": "explain Swift please"]]])
let split = partialPrompt.utf8.count / 2
let handle = try FileHandle(forWritingTo: growingPath)
try handle.seekToEnd(); try handle.write(contentsOf: Data(partialPrompt.utf8.prefix(split)))
let unfinished = try InsightReader.read(home: folder, now: now, index: nextIndex)
assert(unfinished.prompts == stable.prompts && unfinished.skipped == 1)
try handle.write(contentsOf: Data(partialPrompt.utf8.dropFirst(split))); try handle.close()
let completedIndex = PromptIndex(directory: indexDirectory)
let completedTail = try InsightReader.read(home: folder, now: now, index: completedIndex)
assert(completedTail.prompts == stable.prompts + 1 && completedTail.skipped == 0)
assert(completedIndex.promptsAnalyzed == 1 && completedIndex.bytesRead == partialPrompt.utf8.count)
// Replacing a source invalidates only that file's counters.
try old.write(to: growingPath, atomically: true, encoding: .utf8)
let replaced = try InsightReader.read(home: folder, now: now, index: completedIndex)
let direct = try InsightReader.read(home: folder, now: now)
assert(replaced.prompts == direct.prompts && replaced.words == direct.words)
assert(completedIndex.bytesRead == old.utf8.count && completedIndex.filesReused == 2)
print("PASS: partial-tail restart, complete-line admission and per-file replacement invalidation")

let warmModel = InsightsModel(storageURL: indexDirectory, home: folder)
let restoreDeadline = Date().addingTimeInterval(3)
waitUntil(restoreDeadline) { warmModel.state.result != nil }
assert(warmModel.state.result?.prompts == added.prompts && !warmModel.busy, "Saved numeric insights appear before source work")
for i in 0..<3 {
    try FileManager.default.moveItem(at: folder.appendingPathComponent("log\(i).jsonl"),
                                    to: folder.appendingPathComponent("log\(i).unavailable"))
}
warmModel.refresh(home: folder, force: true); awaitRead(warmModel)
assert(warmModel.state.failed && warmModel.state.result?.prompts == added.prompts)
let afterUnavailable = try PromptIndex(directory: indexDirectory).restoreSummary(home: folder)
assert(afterUnavailable?.prompts == added.prompts, "An unreadable refresh must not overwrite durable successful results with empty data")
print("PASS: model restores saved results before scanning and retains them durably across unreadable-source refresh")

for i in 0..<3 {
    try FileManager.default.moveItem(at: folder.appendingPathComponent("log\(i).unavailable"),
                                    to: folder.appendingPathComponent("log\(i).jsonl"))
}
let newChatPath = folder.appendingPathComponent("new-chat.jsonl")
let newChat = try line("response_item", ["type": "message", "role": "user", "id": "brand-new-chat-message", "content": [["text": "verify the Swift build please"]]])
try newChat.write(to: newChatPath, atomically: true, encoding: .utf8)
var catalogDB: OpaquePointer?
assert(sqlite3_open(folder.appendingPathComponent("state_5.sqlite").path, &catalogDB) == SQLITE_OK)
assert(sqlite3_exec(catalogDB, "INSERT INTO threads VALUES('new-chat', '\(newChatPath.path)', 'user', \(Int(now.timeIntervalSince1970)))", nil, nil, nil) == SQLITE_OK)
sqlite3_close(catalogDB)
let newChatIndex = PromptIndex(directory: indexDirectory)
let withNewChat = try InsightReader.read(home: folder, now: now, index: newChatIndex)
assert(newChatIndex.filesReused == 3 && newChatIndex.promptsAnalyzed == 1 && newChatIndex.bytesRead == newChat.utf8.count)
assert(withNewChat.prompts == direct.prompts + 1)
let expired = try InsightReader.read(home: folder, now: now.addingTimeInterval(31 * 86400), index: newChatIndex)
assert(expired.prompts == 0 && newChatIndex.bytesRead == 0)
print("PASS: new-chat discovery processes only the unseen chat and the rolling sample expires without transcript replay")

// Derived storage failures must not turn readable transcripts into failed sources.
let readable = try InsightReader.read(home: folder, now: now)
func matchesReadable(_ result: PromptInsights) -> Bool {
    result.prompts == readable.prompts && result.words == readable.words && result.tasks == readable.tasks && result.skipped == 0
}
let damagedURL = indexDirectory.appendingPathComponent(PromptIndex.digest(Data(growingPath.path.utf8)) + ".json")
try Data("broken checkpoint".utf8).write(to: damagedURL)
let damagedIndex = PromptIndex(directory: indexDirectory)
let recovered = try InsightReader.read(home: folder, now: now, index: damagedIndex)
assert(matchesReadable(recovered) && recovered.cacheWarning != nil)
assert(damagedIndex.bytesRead == old.utf8.count && damagedIndex.filesReused == 3)
var incompatible = try JSONSerialization.jsonObject(with: Data(contentsOf: damagedURL)) as! [String: Any]
incompatible["version"] = 999
try JSONSerialization.data(withJSONObject: incompatible).write(to: damagedURL)
let migrated = try InsightReader.read(home: folder, now: now, index: PromptIndex(directory: indexDirectory))
assert(matchesReadable(migrated) && migrated.cacheWarning != nil)
let repairedIndex = PromptIndex(directory: indexDirectory)
let repaired = try InsightReader.read(home: folder, now: now, index: repairedIndex)
assert(matchesReadable(repaired) && repaired.cacheWarning == nil && repairedIndex.bytesRead == 0)

let blockedCache = folder.appendingPathComponent("blocked-cache")
try Data("synthetic obstruction".utf8).write(to: blockedCache)
let unwritableIndex = PromptIndex(directory: blockedCache)
let uncached = try InsightReader.read(home: folder, now: now, index: unwritableIndex)
assert(matchesReadable(uncached) && uncached.cacheWarning != nil)
let retained = try InsightReader.read(home: folder, now: now, index: unwritableIndex)
assert(matchesReadable(retained) && unwritableIndex.bytesRead == 0 && retained.cacheWarning != nil)
try FileManager.default.removeItem(at: blockedCache)
let savedAgain = try InsightReader.read(home: folder, now: now, index: unwritableIndex)
assert(matchesReadable(savedAgain) && savedAgain.cacheWarning == nil && unwritableIndex.bytesRead == 0)
let afterRecovery = PromptIndex(directory: blockedCache)
_ = try InsightReader.read(home: folder, now: now, index: afterRecovery)
assert(afterRecovery.bytesRead == 0, "Write recovery persists retained facts without transcript replay")

let summaryObstruction = blockedCache.appendingPathComponent("summary.json")
try FileManager.default.createDirectory(at: summaryObstruction, withIntermediateDirectories: false)
let summaryFailureModel = InsightsModel(clock: { now }, storageURL: blockedCache, home: folder)
summaryFailureModel.refresh(home: folder, force: true); awaitRead(summaryFailureModel)
assert(!summaryFailureModel.state.failed && matchesReadable(summaryFailureModel.state.result!))
assert(summaryFailureModel.state.result?.cacheWarning?.contains("summary could not be saved") == true)
print("PASS: corrupt/incompatible checkpoints rebuild one chat; failed cache writes retain results and retry without replay; summary write failure stays separate from source availability")

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
assert(InsightAnalysis.hourBucket(Date(timeIntervalSince1970: 0), calendar: utc) == "00:00–01:00")
assert(InsightAnalysis.hourBucket(Date(timeIntervalSince1970: 23 * 3600), calendar: utc) == "23:00–00:00")
assert(InsightAnalysis.hourBucket(Date(timeIntervalSince1970: 12 * 3600), calendar: utc) == "12:00–13:00")
print("PASS: Insights hour buckets pad hours and wrap midnight")
