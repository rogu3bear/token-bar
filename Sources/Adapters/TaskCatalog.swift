import Foundation
import SQLite3

struct TaskInfo: Equatable {
    var title: String
    var directory: String
}

/// Codex's local catalog. History titles and Now activity both read this file.
enum CodexCatalog {
    static let fileName = "state_5.sqlite"
    static var sidecarNames: [String] { [fileName, fileName + "-wal", fileName + "-shm"] }
    static func database(in home: URL) -> URL { home.appendingPathComponent(fileName) }

    /// Readonly open with the same short busy wait live activity already uses.
    static func openReadOnly(_ url: URL, busyTimeout: Int32 = 100) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, busyTimeout)
        return db
    }
}

struct TaskCatalog {
    private static func failure() -> NSError { NSError(domain: "CodexTokenBar", code: 13, userInfo: [NSLocalizedDescriptionKey: "Task metadata could not be read; retained titles and folders may be stale"]) }
    static func shouldRefresh(home: URL, paths: Set<URL>?, historical: Bool, lastRead: Date, now: Date) -> Bool {
        let databaseEvent = paths?.contains { path in
            path == home || CodexCatalog.sidecarNames.contains { path == home.appendingPathComponent($0) }
        } == true
        return historical || databaseEvent || now.timeIntervalSince(lastRead) >= 60
    }
    static func read(home: URL) throws -> [String: TaskInfo] {
        let url = CodexCatalog.database(in: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let db = CodexCatalog.openReadOnly(url) else { throw failure() }
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
