import Foundation
import SQLite3

struct TaskInfo: Equatable {
    var title: String
    var directory: String
}
struct TaskCatalog {
    private static func failure() -> NSError { NSError(domain: "CodexTokenBar", code: 13, userInfo: [NSLocalizedDescriptionKey: "Task metadata could not be read; retained titles and folders may be stale"]) }
    static func shouldRefresh(home: URL, paths: Set<URL>?, historical: Bool, lastRead: Date, now: Date) -> Bool {
        let databaseEvent = paths?.contains { path in
            path == home || ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"].contains {
                path == home.appendingPathComponent($0)
            }
        } == true
        return historical || databaseEvent || now.timeIntervalSince(lastRead) >= 60
    }
    static func read(home: URL) throws -> [String: TaskInfo] {
        let url = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw failure()
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, substr(title, 1, 500), cwd FROM threads", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var result: [String: TaskInfo] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            result[text(0)] = TaskInfo(title: text(1), directory: text(2))
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }
}
