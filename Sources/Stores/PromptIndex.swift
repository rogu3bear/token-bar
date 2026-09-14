import Foundation
import CryptoKit
import Darwin

/// Serial Insights-queue owner. Checkpoints contain derived counters, hashes and
/// byte positions, never prompt/answer text. Only changed chats are tailed.
final class PromptIndex {
    struct Stamp: Codable, Equatable {
        var size: UInt64
        var inode: UInt64
        var modified: Date
        init(_ path: String) throws {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            modified = a[.modificationDate] as? Date ?? .distantPast
        }
    }
    struct Fact: Codable {
        var key: String
        var date: Date
        var modern: Bool
        var offset: UInt64
        var length: Int
        var words: Int
        var polite: Int
        var languages: [PromptFact]
        var typos: [PromptFact]
        var verbs: [PromptFact]
        var repeatKey: String?
    }
    struct Chat: Codable {
        var version = 1
        var path: String
        var stamp: Stamp
        var offset: UInt64 = 0
        var boundary = ""
        var turn = ""
        var facts: [Fact] = []
    }
    private struct SavedSummary: Codable {
        var version = 1
        var home: String
        var result: PromptInsights
    }
    let directory: URL?
    private var chats: [String: Chat] = [:]
    private var pendingWrites = Set<String>()
    private var cacheReadFailures = 0
    private var cacheWriteFailures = 0
    private(set) var bytesRead = 0
    private(set) var promptsAnalyzed = 0
    private(set) var filesReused = 0
    init(directory: URL? = nil) { self.directory = directory }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func url(_ path: String) -> URL? {
        directory?.appendingPathComponent(Self.digest(Data(path.utf8)) + ".json")
    }
    func restoreSummary(home: URL) throws -> PromptInsights? {
        guard let url = directory?.appendingPathComponent("summary.json"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let saved = try JSONDecoder().decode(SavedSummary.self, from: Data(contentsOf: url))
        guard saved.version == 1, saved.home == home.resolvingSymlinksInPath().path else { return nil }
        return saved.result
    }
    func saveSummary(_ result: PromptInsights, home: URL) throws {
        guard let url = directory?.appendingPathComponent("summary.json") else { return }
        var counters = result
        // Repeat labels are source text. Resolve only the few displayed labels
        // on demand; they never cross the durable storage boundary.
        counters.repeats = []
        try PrivateCache.write(SavedSummary(home: home.resolvingSymlinksInPath().path, result: counters), to: url)
    }
    private func boundary(_ handle: FileHandle, offset: UInt64) throws -> String {
        try handle.seek(toOffset: offset - min(offset, 128))
        return Self.digest(try handle.read(upToCount: Int(min(offset, 128))) ?? Data())
    }
    private func save(_ chat: Chat) {
        guard let url = url(chat.path) else { return }
        do {
            try PrivateCache.write(chat, to: url)
            pendingWrites.remove(chat.path)
        } catch {
            pendingWrites.insert(chat.path)
            cacheWriteFailures += 1
        }
    }
    private func tail(path: String, task: String, since: Date) throws -> Chat {
        let stamp = try Stamp(path)
        var saved = chats[path]
        if saved == nil, let url = url(path), FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(Chat.self, from: Data(contentsOf: url))
                guard decoded.version == 1, decoded.path == path else { throw CocoaError(.fileReadCorruptFile) }
                saved = decoded
            } catch { cacheReadFailures += 1 }
        }
        if let saved, saved.stamp == stamp, saved.offset == stamp.size {
            filesReused += 1
            if pendingWrites.contains(path) { save(saved) }
            return saved
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var chat = Chat(path: path, stamp: stamp)
        if let saved, saved.stamp.inode == stamp.inode, stamp.size >= saved.offset,
           !(stamp.size == saved.stamp.size && stamp.modified != saved.stamp.modified),
           try boundary(handle, offset: saved.offset) == saved.boundary {
            chat = saved; chat.stamp = stamp
        }
        guard let file = fopen(path, "r") else { throw POSIXError(.EACCES) }
        defer { fclose(file) }
        guard fseeko(file, off_t(chat.offset), SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        var line: UnsafeMutablePointer<CChar>?, capacity = 0
        defer { free(line) }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        while UInt64(ftello(file)) < stamp.size {
            let offset = UInt64(ftello(file)), length = getline(&line, &capacity, file)
            guard length > 0, let line else { break }
            bytesRead += length
            guard line[length - 1] == 10 else { break }
            chat.offset = UInt64(ftello(file))
            guard strstr(line, "\"user\"") != nil || strstr(line, "\"user_message\"") != nil || strstr(line, "\"task_started\"") != nil else { continue }
            let data = Data(bytes: line, count: length - 1)
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any] else { continue }
            if event["type"] as? String == "event_msg", payload["type"] as? String == "task_started" {
                chat.turn = payload["turn_id"] as? String ?? ""; continue
            }
            guard let stamp = event["timestamp"] as? String, let date = parser.date(from: stamp) ?? plain.date(from: stamp), date >= since,
                  let text = Self.prompt(event), !text.isEmpty else { continue }
            let modern = event["type"] as? String == "response_item"
            let identity = modern ? (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
            let key = Self.digest(Data((identity ?? ((chat.turn.isEmpty ? stamp : chat.turn) + "\n" + text)).utf8))
            var analyzed = InsightAnalysis.Accumulator()
            analyzed.append(PromptRecord(text: text, date: date, task: task))
            let result = analyzed.result
            func facts(_ values: [String: Int]) -> [PromptFact] { values.map { PromptFact(label: $0.key, count: $0.value) } }
            promptsAnalyzed += 1
            let normalized = Self.normalized(text)
            chat.facts.append(Fact(key: key, date: date, modern: modern, offset: offset, length: length,
                                   words: result.words, polite: result.polite, languages: facts(analyzed.languages),
                                   typos: facts(analyzed.typos), verbs: facts(analyzed.verbs),
                                   repeatKey: (3...300).contains(normalized.count) ? Self.digest(Data(normalized.utf8)) : nil))
        }
        guard ferror(file) == 0 else { throw POSIXError(.EIO) }
        chat.boundary = try boundary(handle, offset: chat.offset)
        chat.facts.removeAll { $0.date < since }
        save(chat)
        return chat
    }
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func prompt(_ event: [String: Any]) -> String? {
        guard let payload = event["payload"] as? [String: Any] else { return nil }
        if event["type"] as? String == "response_item", payload["type"] as? String == "message",
           payload["role"] as? String == "user", let parts = payload["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.map {
                $0.replacingOccurrences(of: "(?s)<recommended_plugins>.*?</recommended_plugins>", with: "", options: .regularExpression)
            }.filter(InsightAnalysis.isUserPrompt).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if event["type"] as? String == "event_msg", payload["type"] as? String == "user_message",
           let text = payload["message"] as? String, InsightAnalysis.isUserPrompt(text) { return text }
        return nil
    }
    func read(selected: [(String, String)], since: Date, now: Date, clock: () -> Date,
              progress: ((PromptInsights) -> Void)?) throws -> PromptInsights {
        bytesRead = 0; promptsAnalyzed = 0; filesReused = 0
        cacheReadFailures = 0; cacheWriteFailures = 0
        var analysis = InsightAnalysis.Accumulator(), seen = Set<String>()
        var repeatSources: [String: (String, Fact)] = [:]
        var files = 0, skipped = 0
        chats = chats.filter { item in selected.contains { $0.1 == item.key } }
        var initial = PromptInsights(); initial.filesTotal = selected.count; progress?(initial)
        for (index, pair) in selected.enumerated() {
            let (task, path) = pair
            do {
                let chat = try tail(path: path, task: task, since: since)
                chats[path] = chat; files += 1
                let facts = chat.facts.filter { $0.date >= since && $0.date <= now }
                let modern = facts.contains { $0.modern }
                for fact in facts where fact.modern == modern && seen.insert(fact.key).inserted {
                    guard fact.words > 0 else { continue }
                    analysis.tasks.insert(task)
                    analysis.result.prompts += 1; analysis.result.words += fact.words
                    analysis.result.polite += fact.polite; analysis.lengths.append(fact.words)
                    for value in fact.languages { analysis.languages[value.label, default: 0] += value.count }
                    for value in fact.typos { analysis.typos[value.label, default: 0] += value.count }
                    for value in fact.verbs { analysis.verbs[value.label, default: 0] += value.count }
                    let hour = Calendar.current.component(.hour, from: fact.date)
                    analysis.hours[String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24), default: 0] += 1
                    if let key = fact.repeatKey { analysis.repeats[key, default: 0] += 1; repeatSources[key] = (path, fact) }
                }
                if chat.offset != chat.stamp.size { skipped += 1 }
            } catch { skipped += 1 }
            var partial = analysis.snapshot(now: clock())
            partial.repeats = [] // Hashes are never user-facing labels.
            partial.files = files; partial.skipped = skipped; partial.filesChecked = index + 1; partial.filesTotal = selected.count
            progress?(partial)
        }
        var result = analysis.snapshot(now: clock())
        result.repeats = analysis.repeats.filter { $0.value > 1 }.map { PromptFact(label: $0.key, count: $0.value) }.compactMap { item in
            guard let (path, fact) = repeatSources[item.label], let chat = chats[path],
                  let stamp = try? Stamp(path), stamp == chat.stamp,
                  let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: fact.offset)
                guard let data = try handle.read(upToCount: fact.length),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let prompt = Self.prompt(event) else { return nil }
                let text = Self.normalized(prompt)
                guard Self.digest(Data(text.utf8)) == item.label else { return nil }
                return PromptFact(label: text, count: item.count)
            } catch { return nil }
        }.sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
        result.repeats = Array(result.repeats.prefix(5))
        result.files = files; result.skipped = skipped; result.filesChecked = selected.count; result.filesTotal = selected.count
        var warnings: [String] = []
        if cacheReadFailures > 0 { warnings.append("Some saved prompt checkpoints were unusable. Readable chats were processed again.") }
        if cacheWriteFailures > 0 { warnings.append("Prompt checkpoints could not be saved. Current results remain available; saving will retry on refresh.") }
        result.cacheWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return result
    }
}
