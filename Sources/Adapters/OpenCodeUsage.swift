import Foundation
import SQLite3

/// Local OpenCode usage, read from its SQLite store.
///
/// OpenCode is the reason harness and provider must be separate dimensions:
/// one tool routes to several providers. A real local store shows `lmstudio`
/// and `opencode` side by side under four models.
///
/// The same database holds a `control_account` table. This reader names the
/// three tables it needs and never selects from that one, and it opens the
/// file read-only so it cannot change OpenCode's stored rows.
enum OpenCodeUsage {
    static let harness = "OpenCode"

    /// Tables this reader is permitted to read. `control_account` is absent by
    /// intent, not by omission.
    static let permittedTables = ["message"]

    static func databaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("opencode.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    struct Turn {
        var messageID: String
        var session: String
        var provider: String
        var model: String
        var tokenFields: [String] = []
        var tokens: Tokens
        var date: Date
        var projectPath: String?
        var mode: String?
        /// Provider-reported cost in USD. Never an API-equivalent estimate, and
        /// never mixed with one. Zero is a real reported zero for a local model.
        var reportedCost: Double?
    }

    /// Decode one `message.data` payload.
    static func turn(id: String, session: String, data: [String: Any]) -> Turn? {
        guard data["role"] as? String == "assistant" else { return nil }
        guard let raw = data["tokens"] as? [String: Any] else { return nil }
        let cache = raw["cache"] as? [String: Any] ?? [:]
        let observed: [(String, Any?)] = [("input_tokens", raw["input"]), ("cached_input_tokens", cache["read"]),
            ("cache_write_input_tokens", cache["write"]), ("output_tokens", raw["output"]), ("reasoning_output_tokens", raw["reasoning"])]
        guard observed.allSatisfy({ _, value in value == nil || (value as? Int).map { $0 >= 0 && $0 <= Int.max / 8 } == true }),
              let date = milliseconds((data["time"] as? [String: Any])?["created"]) else { return nil }
        var fields = observed.compactMap { name, value in value == nil ? nil : name }
        // Canonical input is fully known only when all disjoint components were reported.
        if raw["input"] == nil || cache["read"] == nil || cache["write"] == nil { fields.removeAll { $0 == "input_tokens" } }
        let tokens = Tokens.canonical(
            input: raw["input"] as? Int ?? 0,
            cacheRead: cache["read"] as? Int ?? 0,
            cacheWrite: cache["write"] as? Int,
            output: raw["output"] as? Int ?? 0,
            reasoning: raw["reasoning"] as? Int ?? 0,
            convention: .cacheBesideInput)
        guard tokens.total > 0 else { return nil }
        let path = data["path"] as? [String: Any]
        return Turn(messageID: id,
                    session: session,
                    provider: (data["providerID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                    model: (data["modelID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown model",
                    tokenFields: fields, tokens: tokens,
                    date: date,
                    projectPath: Project.path(path?["cwd"]) ?? Project.path(path?["root"]),
                    mode: data["mode"] as? String,
                    reportedCost: data["cost"] as? Double)
    }

    /// OpenCode stores epoch milliseconds.
    static func milliseconds(_ raw: Any?) -> Date? {
        guard let value = raw as? Double ?? (raw as? Int).map(Double.init), value.isFinite, value > 0, value < 253402300800000 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    struct Watermark: Codable, Equatable {
        var timeCreated: Int64
        var id: String
        var inode: UInt64?
    }
    struct Page {
        var turns: [Turn] = []
        var watermark: Watermark?
        var pending: Set<String> = []
        var rows = 0
    }
    private static func readFailure() -> NSError {
        NSError(domain: "CodexTokenBar", code: 11, userInfo: [NSLocalizedDescriptionKey:
            "OpenCode usage query failed; source data is unavailable"])
    }

    /// Scanner-owned connection avoids rebuilding WAL shared memory on every refresh.
    /// Statements end between pages so a live writer's committed rows stay visible.
    final class Reader {
        private var handle: OpaquePointer?
        var isOpen: Bool { handle != nil }
        init(database url: URL) throws {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(handle); handle = nil; throw OpenCodeUsage.readFailure()
            }
            sqlite3_busy_timeout(handle, 100)
        }
        deinit { sqlite3_close(handle) }
        func page(after: Watermark? = nil, ids: [String]? = nil, limit: Int = 512) throws -> Page {
            guard let handle else { return Page() }
            return try OpenCodeUsage.page(handle: handle, after: after, ids: ids, limit: limit)
        }
    }

    static func page(database url: URL, after: Watermark? = nil, ids: [String]? = nil, limit: Int = 512) throws -> Page {
        try Reader(database: url).page(after: after, ids: ids, limit: limit)
    }

    /// Every query is bounded. The id breaks equal-millisecond ties. Unfinished
    /// assistant rows are reread by primary key even after the watermark passes.
    private static func page(handle: OpaquePointer, after: Watermark?, ids: [String]?, limit: Int) throws -> Page {
        var statement: OpaquePointer?
        let predicate: String
        if let ids {
            guard !ids.isEmpty else { return Page() }
            predicate = "m.id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")"
        } else { predicate = "(m.time_created, m.id) > (?, ?)" }
        let sql = "SELECT m.id, m.session_id, m.data, m.time_created FROM message m WHERE " +
            predicate + " ORDER BY m.time_created, m.id LIMIT ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw readFailure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var binding: Int32 = 1
        if let ids {
            for id in ids { sqlite3_bind_text(statement, binding, id, -1, transient); binding += 1 }
        } else {
            sqlite3_bind_int64(statement, 1, after?.timeCreated ?? Int64.min)
            sqlite3_bind_text(statement, 2, after?.id ?? "", -1, transient)
            binding = 3
        }
        sqlite3_bind_int(statement, binding, Int32(limit))
        var result = Page()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            guard let idText = sqlite3_column_text(statement, 0),
                  let sessionText = sqlite3_column_text(statement, 1),
                  let dataText = sqlite3_column_text(statement, 2) else { throw readFailure() }
            let id = String(cString: idText)
            result.rows += 1
            result.watermark = Watermark(timeCreated: sqlite3_column_int64(statement, 3), id: id)
            let payload = Data(String(cString: dataText).utf8)
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw readFailure() }
            guard object["role"] as? String == "assistant" else { continue }
            if (object["time"] as? [String: Any])?["completed"] == nil { result.pending.insert(id) }
            guard let raw = object["tokens"] as? [String: Any] else { continue }
            guard let turn = turn(id: id, session: String(cString: sessionText), data: object) else {
                if raw.isEmpty { continue }
                if let date = milliseconds((object["time"] as? [String: Any])?["created"]), date.timeIntervalSince1970 > 0,
                   raw.values.allSatisfy({ ($0 as? Int) == 0 || ($0 as? [String: Int])?.values.allSatisfy({ $0 == 0 }) == true }) { continue }
                throw readFailure()
            }
            result.turns.append(turn)
        }
        guard status == SQLITE_DONE else { throw readFailure() }
        return result
    }

    /// Explicit full reads (diagnostics/recovery) still use bounded pages.
    static func read(database url: URL) throws -> [Turn] {
        let reader = try Reader(database: url)
        var result: [Turn] = [], cursor: Watermark?
        while true {
            let next = try reader.page(after: cursor)
            result += next.turns
            if next.rows < 512 { return result }
            cursor = next.watermark
        }
    }
}
