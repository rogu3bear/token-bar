import Foundation
import SQLite3

/// An append-only detail store. Pending rows become visible only after their usage ledger is durable.
/// A crash before the ledger save leaves invisible rows that can be retried at the same event ID.
final class RequestArchive {
    private var db: OpaquePointer?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var inTransaction = false
    private var insertion: OpaquePointer?
    private var cachedCount: Int?
    private var countDataVersion: Int64?
    private(set) var countQueryCount = 0
    private(set) var decodedRowCount = 0
    private(set) var readVMSteps = 0
    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); db = nil; throw Self.failure("Request details could not be opened") }
        do {
            sqlite3_busy_timeout(db, 3000)
            if !readOnly {
                try execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, group_key TEXT NOT NULL, date REAL NOT NULL, payload BLOB NOT NULL, admitted INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID")
                try execute("CREATE INDEX IF NOT EXISTS request_dates ON requests(admitted, date)")
                try execute("CREATE INDEX IF NOT EXISTS request_pending ON requests(admitted,id)")
                try execute("CREATE INDEX IF NOT EXISTS request_groups ON requests(group_key)")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_finalize(insertion); if inTransaction { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }; sqlite3_close(db) }
    static func failure(_ message: String) -> NSError { NSError(domain: "TokenBar.RequestArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.failure("Request detail storage failed; existing data is retained") }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.failure("Request detail query failed") }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    /// Exact immutable baseline, including pending rows whose ID the caller verifies.
    func entry(id: String) throws -> Entry? {
        let statement = try prepare("SELECT payload FROM requests WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw Self.failure("Request baseline unavailable") }
        return try decoder.decode(Entry.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    func begin() throws { try execute("BEGIN IMMEDIATE"); inTransaction = true }
    func commit() throws { try execute("COMMIT"); inTransaction = false }
    func rollback() {
        if inTransaction {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil); inTransaction = false
            cachedCount = nil
        }
    }
    func record(_ entry: Entry, admitted: Bool = false) throws {
        guard let id = entry.recordID else { throw Self.failure("Request detail identity is missing") }
        if insertion == nil {
            insertion = try prepare("INSERT INTO requests(id,group_key,date,payload,admitted) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET group_key=excluded.group_key, date=excluded.date, payload=excluded.payload, admitted=excluded.admitted WHERE requests.admitted=0")
        }
        let statement = insertion!
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        defer { sqlite3_reset(statement) }
        bind(id, to: statement, at: 1); bind(CostRecovery.groupKey(entry), to: statement, at: 2)
        sqlite3_bind_double(statement, 3, entry.date.timeIntervalSince1970)
        let payload = try encoder.encode(entry)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_int(statement, 5, admitted ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.failure("Request details could not be retained; usage scan stopped") }
        if admitted, let count = cachedCount { cachedCount = count + Int(sqlite3_changes(db)) }
    }
    func acknowledge(isAdmitted: (String) throws -> Bool) throws {
        // Bounded pages avoid retaining an entire multi-million-record archive in memory.
        let read = try prepare("SELECT id FROM requests WHERE admitted=0 AND id>? ORDER BY id LIMIT 1000")
        let update = try prepare("UPDATE requests SET admitted=1 WHERE id=?")
        defer { sqlite3_finalize(read); sqlite3_finalize(update) }
        try begin(); var completed = false
        defer { if !completed { rollback() } }
        var last = ""
        while true {
            sqlite3_reset(read); bind(last, to: read, at: 1)
            var ids: [String] = []; var status = sqlite3_step(read)
            while status == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(read, 0))); status = sqlite3_step(read)
            }
            guard status == SQLITE_DONE else { throw Self.failure("Pending request details could not be read") }
            guard let next = ids.last else { break }; last = next
            for id in ids where try isAdmitted(id) {
                sqlite3_reset(update); bind(id, to: update, at: 1)
                guard sqlite3_step(update) == SQLITE_DONE else { throw Self.failure("Request details could not be acknowledged") }
                if let count = cachedCount { cachedCount = count + Int(sqlite3_changes(db)) }
            }
        }
        try commit(); completed = true
    }
    func forEach(start: Date = .distantPast, end: Date = .distantFuture, group: String? = nil, _ visit: (Entry) throws -> Void) throws {
        // SQLite otherwise prefers request_dates for this ORDER BY and can scan
        // all admitted dates before applying group_key. Bind group reads to their index.
        let statement = try prepare("SELECT payload FROM requests"
            + (group == nil ? "" : " INDEXED BY request_groups")
            + " WHERE admitted=1 AND date>=? AND date<=?"
            + (group == nil ? "" : " AND group_key=?") + " ORDER BY date,id")
        defer {
            readVMSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
            sqlite3_finalize(statement)
        }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970); sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        if let group { bind(group, to: statement, at: 3) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw Self.failure("A retained request record is unreadable") }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            decodedRowCount += 1
            try visit(decoder.decode(Entry.self, from: data))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw Self.failure("Request detail reading was interrupted") }
    }
    var count: Int {
        get throws {
            // Local admissions maintain the exact baseline. Other connections and
            // rolled-back transactions require a fresh baseline, never a guessed zero.
            let versionQuery = try prepare("PRAGMA data_version")
            defer { sqlite3_finalize(versionQuery) }
            guard sqlite3_step(versionQuery) == SQLITE_ROW else { throw Self.failure("Request detail version is unavailable") }
            let version = sqlite3_column_int64(versionQuery, 0)
            if countDataVersion != version { cachedCount = nil }
            if let cachedCount { return cachedCount }
            let statement = try prepare("SELECT COUNT(*) FROM requests WHERE admitted=1"); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.failure("Request detail count is unavailable") }
            let count = Int(sqlite3_column_int64(statement, 0))
            countQueryCount += 1; cachedCount = count; countDataVersion = version
            return count
        }
    }
    @discardableResult
    func importAccepted(from source: RequestArchive, groups: Set<String>, accounts: [String: Account]) throws -> Int {
        var allowed = groups
        let existing = try prepare("SELECT id,group_key,payload FROM requests WHERE admitted=1")
        let lookup = try source.prepare("SELECT payload FROM requests WHERE id=? AND group_key=? AND admitted=1")
        let destinationLookup = try prepare("SELECT group_key,payload FROM requests WHERE id=? AND admitted=1")
        defer { sqlite3_finalize(existing); sqlite3_finalize(lookup); sqlite3_finalize(destinationLookup) }
        func entry(_ statement: OpaquePointer, column: Int32) throws -> Entry {
            guard let bytes = sqlite3_column_blob(statement, column) else { throw Self.failure("Retained request details are unreadable") }
            return try decoder.decode(Entry.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))))
        }
        func compatible(_ old: Entry, _ fresh: Entry, group: String) throws -> Bool {
            // The reconstructed source has no independent account authority. Preserve the
            // uniformly reconciled account, and require every other retained detail to agree.
            guard old.account == accounts[group] else { return false }
            var normalized = fresh; normalized.account = old.account
            let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
            return try canonical.encode(old) == canonical.encode(normalized)
        }
        var status = sqlite3_step(existing)
        while status == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(existing, 0))
            let group = String(cString: sqlite3_column_text(existing, 1))
            if allowed.contains(group) {
                sqlite3_reset(lookup); source.bind(id, to: lookup, at: 1); source.bind(group, to: lookup, at: 2)
                let found = sqlite3_step(lookup)
                if found == SQLITE_DONE { allowed.remove(group) }
                else if found == SQLITE_ROW {
                    if try !compatible(entry(existing, column: 2), entry(lookup, column: 0), group: group) { allowed.remove(group) }
                } else { throw Self.failure("Recovered request identities could not be compared") }
            }
            status = sqlite3_step(existing)
        }
        guard status == SQLITE_DONE else { throw Self.failure("Existing request identities could not be compared") }
        sqlite3_reset(existing); sqlite3_reset(lookup)
        // Also reject incoming IDs retained under another, possibly unaccepted group.
        try source.forEach { fresh in
            let group = CostRecovery.groupKey(fresh)
            guard allowed.contains(group), let id = fresh.recordID else { return }
            sqlite3_reset(destinationLookup); bind(id, to: destinationLookup, at: 1)
            let found = sqlite3_step(destinationLookup)
            if found == SQLITE_ROW {
                let retainedGroup = String(cString: sqlite3_column_text(destinationLookup, 0))
                if retainedGroup != group { allowed.remove(group) }
                else if try !compatible(entry(destinationLookup, column: 1), fresh, group: group) { allowed.remove(group) }
            } else if found != SQLITE_DONE { throw Self.failure("Incoming request identities could not be compared") }
        }
        sqlite3_reset(destinationLookup)
        try begin(); var completed = false
        defer { if !completed { rollback() } }
        try source.forEach { value in
            let key = CostRecovery.groupKey(value)
            guard allowed.contains(key) else { return }
            var entry = value; entry.account = accounts[key]
            try record(entry, admitted: true)
        }
        try commit(); completed = true
        return groups.count - allowed.count
    }
}
