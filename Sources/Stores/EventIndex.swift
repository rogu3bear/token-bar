import Foundation
import SQLite3

/// Committed logical event identities. New identities stay with their ledger transaction
/// until its JSON snapshot is durable, then move into this index. Counts never depend on an
/// identity that was committed before its matching ledger entry.
final class EventIndex {
    private var db: OpaquePointer?
    private var lookup: OpaquePointer?
    init(url: URL, required: Bool) throws {
        if required && !FileManager.default.fileExists(atPath: url.path) { throw Self.error("The historical event index is missing; usage history has been preserved") }
        var ready = false
        defer { if !ready { sqlite3_finalize(lookup); sqlite3_close(db); lookup = nil; db = nil } }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Self.error("Could not open the historical event index") }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS event_ids (id TEXT PRIMARY KEY) WITHOUT ROWID", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT 1 FROM event_ids WHERE id = ?", -1, &lookup, nil) == SQLITE_OK else { throw Self.error("Could not initialize the historical event index") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        ready = true
    }
    deinit { sqlite3_finalize(lookup); sqlite3_close(db) }
    private static func error(_ text: String) -> NSError { NSError(domain: "CodexTokenBar", code: 2, userInfo: [NSLocalizedDescriptionKey: text]) }
    func contains(_ id: String) -> Bool? {
        sqlite3_reset(lookup)
        return id.withCString { value in
            sqlite3_bind_text(lookup, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            switch sqlite3_step(lookup) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: return nil
            }
        }
    }
    func commit(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw Self.error("The historical event index is busy") }
        var insert: OpaquePointer?
        var committed = false
        defer { sqlite3_finalize(insert); if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO event_ids VALUES (?)", -1, &insert, nil) == SQLITE_OK else { throw Self.error("Could not prepare event identity update") }
        for id in ids {
            sqlite3_reset(insert)
            let result = id.withCString { value -> Int32 in
                sqlite3_bind_text(insert, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                return sqlite3_step(insert)
            }
            guard result == SQLITE_DONE else { throw Self.error("Could not store event identity; original ledger is retained") }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw Self.error("Could not commit event identities") }
        committed = true
    }
}
