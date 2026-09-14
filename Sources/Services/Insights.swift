import Foundation
import SQLite3
import Darwin

struct PromptFact: Identifiable, Codable {
    var label: String
    var count: Int
    var id: String { label }
}
struct PromptInsights: Codable {
    var prompts = 0
    var tasks = 0
    var files = 0
    var filesChecked = 0
    var filesTotal: Int?
    var skipped = 0
    var words = 0
    var medianWords = 0
    var languages: [PromptFact] = []
    var repeats: [PromptFact] = []
    var typos: [PromptFact] = []
    var verbs: [PromptFact] = []
    var hours: [PromptFact] = []
    var polite = 0
    var readAt: Date?
    var error: String?
}
struct PromptRecord {
    var text: String
    var date: Date
    var task: String
}
enum InsightAnalysis {
    static let typoMap = ["teh": "the", "thier": "their", "seperate": "separate", "definately": "definitely", "definitly": "definitely", "recieve": "receive", "warrented": "warranted", "accomodate": "accommodate", "consistant": "consistent", "impliment": "implement", "enviroment": "environment", "occurence": "occurrence", "responsiblity": "responsibility", "relevent": "relevant"]
    static func prose(_ text: String) -> String {
        var code = false
        return text.components(separatedBy: .newlines).filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.toggle(); return false }
            return !code && !line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        }.joined(separator: " ")
    }
    static func isUserPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !["<environment_context>", "<INSTRUCTIONS>", "# AGENTS.md instructions", "<permissions instructions>", "<subagent_notification>", "<turn_aborted>", "<codex_internal_context", "<codex_delegation>", "<skill>", "<heartbeat>"].contains(where: t.hasPrefix)
    }
    static func build(_ records: [PromptRecord]) -> PromptInsights {
        var analysis = Accumulator()
        for record in records { analysis.append(record) }
        return analysis.snapshot()
    }

    /// Each admitted prompt is analyzed once, even when file progress is published.
    struct Accumulator {
        var result = PromptInsights()
        var languages: [String: Int] = [:], repeats: [String: Int] = [:], typos: [String: Int] = [:], verbs: [String: Int] = [:], hours: [String: Int] = [:]
        var lengths: [Int] = []
        var tasks = Set<String>()
        private let languageWords = ["rust": "Rust", "python": "Python", "swift": "Swift", "typescript": "TypeScript", "javascript": "JavaScript", "sql": "SQL", "golang": "Go", "kotlin": "Kotlin", "ruby": "Ruby", "java": "Java", "lean": "Lean", "latex": "LaTeX"]
        mutating func append(_ record: PromptRecord) {
            guard isUserPrompt(record.text) else { return }
            let text = prose(record.text).lowercased()
            let words = text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            guard !words.isEmpty else { return }
            tasks.insert(record.task)
            result.prompts += 1; result.words += words.count; lengths.append(words.count)
            let unique = Set(words)
            for (word, label) in languageWords where unique.contains(word) { languages[label, default: 0] += 1 }
            for word in words { if let correction = typoMap[word] { typos[word + " → " + correction, default: 0] += 1 } }
            for verb in ["fix", "review", "build", "deploy", "verify", "explain", "refactor", "test", "simplify", "continue", "resume"] where unique.contains(verb) { verbs[verb, default: 0] += 1 }
            if unique.contains("please") || unique.contains("thanks") { result.polite += 1 }
            let normalized = record.text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if normalized.count >= 3 && normalized.count <= 300 { repeats[normalized, default: 0] += 1 }
            let hour = Calendar.current.component(.hour, from: record.date)
            hours[String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24), default: 0] += 1
        }
        func snapshot(now: Date = Date()) -> PromptInsights {
            func ranked(_ values: [String: Int]) -> [PromptFact] {
                let facts: [PromptFact] = values.map { PromptFact(label: $0.key, count: $0.value) }
                let sorted = facts.sorted { a, b in
                    if a.count == b.count { return a.label < b.label }
                    return a.count > b.count
                }
                return Array(sorted.prefix(5))
            }
            var result = result
            result.tasks = tasks.count
            let sortedLengths = lengths.sorted(); result.medianWords = sortedLengths.isEmpty ? 0 : sortedLengths[sortedLengths.count / 2]
            result.languages = ranked(languages); result.repeats = ranked(repeats.filter { $0.value > 1 })
            result.typos = ranked(typos); result.verbs = ranked(verbs); result.hours = ranked(hours)
            result.readAt = now
            return result
        }
    }

}

enum InsightReader {
    // Read only catalogued human chats. Cap the sample explicitly; stream logs without loading tool output into memory.
    static func read(home: URL, now: Date = Date(), clock: () -> Date = Date.init, index: PromptIndex? = nil, progress: ((PromptInsights) -> Void)? = nil) throws -> PromptInsights {
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        var statement: OpaquePointer?
        let query = "SELECT id, rollout_path FROM threads WHERE thread_source='user' AND updated_at >= ? ORDER BY updated_at DESC LIMIT 120"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        let since = now.addingTimeInterval(-30 * 86400)
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970))
        var status = sqlite3_step(statement)
        var selected: [(String, String)] = []
        while status == SQLITE_ROW {
            selected.append((sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                             sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        return try (index ?? PromptIndex()).read(selected: selected, since: since, now: now, clock: clock, progress: progress)
    }
}
