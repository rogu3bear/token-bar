import Foundation
import Darwin
import SQLite3

/// The scanner's serial queue owns the writer. Entries, metadata and event IDs
/// become visible together. The request archive can acknowledge afterward.
final class LedgerStore {
    private let db: OpaquePointer
    private var lookup: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var saved = Ledger()
    private var generation: Int64 = 0
    private static let migrationMarker = Data("{\"tokenBarUsageStore\":1}\n".utf8)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func url(for legacy: URL) -> URL {
        legacy.deletingPathExtension().appendingPathExtension("sqlite")
    }

    static func open(for legacy: URL) throws -> (LedgerStore, Ledger) {
        let destination = url(for: legacy)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try migrate(legacy, to: destination)
        }
        let store = try LedgerStore(destination)
        let ledger = try store.load()
        try PrivateFile.protect(destination)
        try sealLegacy(legacy)
        try store.statement("PRAGMA journal_mode=WAL") { query in
            guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_text(query, 0).map({ String(cString: $0) }) == "wal" else {
                throw store.failure("Could not enable the usage transaction journal")
            }
        }
        try store.execute("PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON")
        return (store, ledger)
    }

    static func read(_ url: URL) throws -> Ledger {
        // The system SQLite may need to recreate WAL sidecars after a clean
        // close, even for a query. Prevent application-level writes.
        let store = try LedgerStore(url)
        try store.execute("PRAGMA query_only=ON")
        return try store.load()
    }

    private init(_ url: URL) throws {
        var handle: OpaquePointer?
        // Resolve macOS directory aliases such as /var; the database itself
        // must still be a direct file rather than a symlink.
        let physical = try Self.physicalParent(of: url)
        guard sqlite3_open_v2(physical.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle else {
            let code = sqlite3_extended_errcode(handle)
            sqlite3_close(handle)
            throw RequestArchive.failure("Could not open the saved usage database (SQLite \(code))")
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit { sqlite3_finalize(lookup); sqlite3_close(db) }

    private static func physicalParent(of url: URL) throws -> URL {
        guard let path = realpath(url.deletingLastPathComponent().path, nil) else {
            throw RequestArchive.failure("Could not resolve the usage database directory")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    private static func unpublished<T>(beside url: URL, _ body: (URL) throws -> T) throws -> T {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pending-usage-" + UUID().uuidString + ".sqlite")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: PrivateFile.mode]) else {
            throw RequestArchive.failure("Could not create a private usage database")
        }
        defer {
            try? files.removeItem(at: temporary)
            try? files.removeItem(atPath: temporary.path + "-journal")
        }
        return try body(temporary)
    }

    static func isMigrationMarker(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: migrationMarker.count + 1) == migrationMarker
    }

    /// Older readers fail closed at their original path. Keep the old bytes
    /// available and publish the marker only after the database is durable.
    private static func sealLegacy(_ legacy: URL) throws {
        let parent = legacy.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: legacy.path) {
            if try isMigrationMarker(legacy) { return }
            let backup = legacy.deletingPathExtension().appendingPathExtension("before-sqlite.json")
            var sourceInfo = stat(), backupInfo = stat()
            guard lstat(legacy.path, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFREG else {
                throw RequestArchive.failure("Could not preserve the legacy usage ledger")
            }
            if link(legacy.path, backup.path) != 0 {
                guard errno == EEXIST, lstat(backup.path, &backupInfo) == 0,
                      sourceInfo.st_dev == backupInfo.st_dev, sourceInfo.st_ino == backupInfo.st_ino else {
                    throw RequestArchive.failure("A different legacy usage backup already exists")
                }
            }
            try PrivateFile.protect(backup)
        }
        try syncDirectory(parent)
        try PrivateCache.write(migrationMarker, to: legacy)
        try syncDirectory(parent)
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw RequestArchive.failure("Could not open the usage directory for synchronization") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RequestArchive.failure("Could not synchronize the usage directory") }
    }

    private static func migrate(_ legacy: URL, to destination: URL) throws {
        let files = FileManager.default
        let hasLedger = files.fileExists(atPath: legacy.path)
        var ledger = hasLedger ? try UsageScanner.loadLegacyLedger(from: legacy) : Ledger()
        if !hasLedger && files.fileExists(atPath: UsageScanner.metadataURL(for: legacy).path) {
            throw RequestArchive.failure("The saved usage ledger is missing; its checkpoint has been preserved")
        }
        let index = legacy.deletingPathExtension().appendingPathExtension("events.sqlite")
        let hasIndex = files.fileExists(atPath: index.path)
        if ledger.eventIndexReady == true && !hasIndex {
            throw RequestArchive.failure("The historical event index is missing; usage history has been preserved")
        }
        ledger.eventIndexReady = true
        ledger.checkpointID = nil
        if ledger.reportRevision == nil { ledger.reportRevision = UUID() }
        try unpublished(beside: destination) { temporary in
            do {
                let store = try LedgerStore(temporary)
                try store.execute("PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON")
                if hasIndex {
                    // Allow SQLite to recover a hot legacy journal. No legacy rows are changed.
                    try store.statement("ATTACH DATABASE ? AS legacy") {
                        let location = try physicalParent(of: index).absoluteString + "?mode=rw&nofollow=1"
                        try store.bind(location, to: $0, at: 1)
                        try store.stepDone($0)
                    }
                }
                try store.transaction {
                    try store.execute("""
                        CREATE TABLE ledger_header (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL,
                            entry_count INTEGER NOT NULL, payload BLOB NOT NULL);
                        CREATE TABLE ledger_entries (position INTEGER PRIMARY KEY, payload BLOB NOT NULL);
                        CREATE TABLE ledger_metadata (section TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL,
                            PRIMARY KEY(section, key)) WITHOUT ROWID;
                        CREATE TABLE event_ids (id TEXT PRIMARY KEY) WITHOUT ROWID;
                        PRAGMA user_version=1;
                        """)
                    if hasIndex {
                        if !hasLedger {
                            try store.statement("SELECT 1 FROM legacy.event_ids LIMIT 1") {
                                guard sqlite3_step($0) == SQLITE_DONE else {
                                    throw RequestArchive.failure("The saved usage ledger is missing; event identities have been preserved")
                                }
                            }
                        }
                        try store.execute("INSERT INTO main.event_ids SELECT id FROM legacy.event_ids")
                    }
                    try store.write(ledger)
                }
            }
            // Publish the fully committed store in the same directory without replacing a peer's store.
            try files.moveItem(at: temporary, to: destination)
        }
    }

    func backup(to destination: URL) throws {
        try Self.unpublished(beside: destination) { temporary in
            do {
                let copy = try LedgerStore(temporary)
                try copy.execute("PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON")
                guard let backup = sqlite3_backup_init(copy.db, "main", db, "main") else {
                    throw copy.failure("Could not start a usage backup")
                }
                let result = sqlite3_backup_step(backup, -1)
                let finish = sqlite3_backup_finish(backup)
                guard result == SQLITE_DONE, finish == SQLITE_OK else {
                    throw copy.failure("Could not complete the usage backup")
                }
                try copy.execute("PRAGMA journal_mode=DELETE")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            try Self.syncDirectory(destination.deletingLastPathComponent())
        }
    }

    func contains(_ id: String) -> Bool? {
        guard let lookup else { return nil }
        defer { sqlite3_reset(lookup) }
        do { try bind(id, to: lookup, at: 1) } catch { return nil }
        switch sqlite3_step(lookup) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: return nil
        }
    }

    private func load() throws -> Ledger {
        try transaction("BEGIN") {
            try statement("PRAGMA user_version") {
                guard sqlite3_step($0) == SQLITE_ROW else { throw failure("Could not read the usage database version") }
                guard sqlite3_column_int($0, 0) == 1 else { throw failure("Unsupported saved usage database format") }
            }
            var ledger = Ledger()
            var count: Int64 = 0
            try statement("SELECT generation,entry_count,payload FROM ledger_header WHERE id=1") { query in
                guard sqlite3_step(query) == SQLITE_ROW else { throw failure("Saved usage metadata is missing") }
                generation = sqlite3_column_int64(query, 0)
                count = sqlite3_column_int64(query, 1)
                let header = try data(query, at: 2)
                ledger = try decoder.decode(Ledger.self, from: header)
                guard generation > 0, count >= 0, ledger.entries.isEmpty, ledger.eventIDs?.isEmpty == true else {
                    throw failure("Saved usage metadata is invalid")
                }
            }
            for map in Self.maps { try map.load(self, &ledger) }
            try statement("SELECT position,payload FROM ledger_entries ORDER BY position") { query in
                try rows(query) {
                    guard sqlite3_column_int64(query, 0) == ledger.entries.count else {
                        throw failure("Saved usage entry order is incomplete")
                    }
                    ledger.entries.append(try decoder.decode(Entry.self, from: data(query, at: 1)))
                }
            }
            guard count == ledger.entries.count else { throw failure("Saved usage entries are incomplete") }
            try checked(sqlite3_prepare_v2(db, "SELECT 1 FROM event_ids WHERE id=?", -1, &lookup, nil))
            saved = ledger
            return ledger
        }
    }

    func commit(_ ledger: Ledger, beforeCommit: () throws -> Void) throws {
        try transaction {
            try write(ledger)
            try beforeCommit()
        }
        saved = ledger
        saved.eventIDs = []
        generation += 1
    }

    private func write(_ ledger: Ledger) throws {
        guard generation < Int64.max else { throw failure("The usage commit count exceeds storage bounds") }
        var header = ledger
        header.entries = []
        header.eventIDs = []
        for map in Self.maps { try map.write(self, &header, saved) }
        let payload = try encoder.encode(header)
        try statement("INSERT OR REPLACE INTO ledger_entries(position,payload) VALUES (?,?)") { query in
            for (position, entry) in ledger.entries.enumerated()
                where position >= saved.entries.count || saved.entries[position] != entry {
                sqlite3_reset(query)
                try checked(sqlite3_bind_int64(query, 1, Int64(position)))
                try bind(encoder.encode(entry), to: query, at: 2)
                try stepDone(query)
            }
        }
        if ledger.entries.count < saved.entries.count {
            try statement("DELETE FROM ledger_entries WHERE position>=?") {
                try checked(sqlite3_bind_int64($0, 1, Int64(ledger.entries.count)))
                try stepDone($0)
            }
        }
        if let ids = ledger.eventIDs, !ids.isEmpty {
            try statement("INSERT OR IGNORE INTO event_ids VALUES (?)") { query in
                for id in ids {
                    sqlite3_reset(query)
                    try bind(id, to: query, at: 1)
                    try stepDone(query)
                }
            }
        }
        let headerSQL = generation == 0
            ? "INSERT INTO ledger_header(generation,entry_count,payload,id) VALUES (?,?,?,1)"
            : "UPDATE ledger_header SET generation=?,entry_count=?,payload=? WHERE id=1 AND generation=?"
        try statement(headerSQL) { query in
            try checked(sqlite3_bind_int64(query, 1, generation + 1))
            try checked(sqlite3_bind_int64(query, 2, Int64(ledger.entries.count)))
            try bind(payload, to: query, at: 3)
            if generation > 0 { try checked(sqlite3_bind_int64(query, 4, generation)) }
            try stepDone(query)
            guard sqlite3_changes(db) == 1 else { throw failure("Saved usage changed in another scanner; reopen before saving") }
        }
    }

    private func transaction<T>(_ begin: String = "BEGIN IMMEDIATE", _ work: () throws -> T) throws -> T {
        try execute(begin)
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            // SQLite can already have rolled back on I/O, disk-full or interruption.
            if sqlite3_get_autocommit(db) == 0 { try? execute("ROLLBACK") }
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try checked(sqlite3_exec(db, sql, nil, nil, nil))
    }
    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        try checked(sqlite3_prepare_v2(db, sql, -1, &query, nil))
        guard let query else { throw failure("Could not prepare the usage statement") }
        return try body(query)
    }
    private func rows(_ query: OpaquePointer, _ body: () throws -> Void) throws {
        while true {
            switch sqlite3_step(query) {
            case SQLITE_ROW: try body()
            case SQLITE_DONE: return
            default: throw failure("Could not read saved usage rows")
            }
        }
    }
    private func bind(_ value: String, to query: OpaquePointer, at column: Int32) throws {
        guard let length = Int32(exactly: value.utf8.count) else { throw failure("A usage key exceeds storage bounds") }
        try checked(value.withCString { sqlite3_bind_text(query, column, $0, length, Self.transient) })
    }
    private func bind(_ value: Data, to query: OpaquePointer, at column: Int32) throws {
        guard let length = Int32(exactly: value.count) else { throw failure("A usage row exceeds storage bounds") }
        try checked(value.withUnsafeBytes { sqlite3_bind_blob(query, column, $0.baseAddress, length, Self.transient) })
    }
    private func data(_ query: OpaquePointer, at column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(query, column) else { throw failure("A saved usage row is missing") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, column)))
    }
    private func checked(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw failure("Usage database operation failed") }
    }
    private func stepDone(_ query: OpaquePointer) throws {
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure("Could not write the usage row") }
    }
    private func failure(_ message: String) -> NSError {
        RequestArchive.failure("\(message) (SQLite \(sqlite3_extended_errcode(db)))")
    }
}

extension LedgerStore {
    /// Separating map rows keeps a changed cursor (or a removed diagnostic) from
    /// rewriting the other sources. The small header preserves nil vs. empty maps.
    private struct Map {
        let write: (LedgerStore, inout Ledger, Ledger) throws -> Void
        let load: (LedgerStore, inout Ledger) throws -> Void

        init<Value: Codable & Equatable>(_ section: String, _ field: WritableKeyPath<Ledger, [String: Value]?>) {
            write = { store, header, prior in
                let current = header[keyPath: field]
                try store.updateMap(section, current ?? [:], from: prior[keyPath: field] ?? [:])
                header[keyPath: field] = current.map { _ in [:] }
            }
            load = { store, header in
                let values: [String: Value] = try store.readMap(section)
                guard header[keyPath: field]?.isEmpty != false, values.isEmpty || header[keyPath: field] != nil else {
                    throw store.failure("Saved usage map does not match its header")
                }
                if header[keyPath: field] != nil { header[keyPath: field] = values }
            }
        }

        init<Value: Codable & Equatable>(_ section: String, _ field: WritableKeyPath<Ledger, [String: Value]>) {
            write = { store, header, prior in
                try store.updateMap(section, header[keyPath: field], from: prior[keyPath: field])
                header[keyPath: field] = [:]
            }
            load = { store, header in
                guard header[keyPath: field].isEmpty else { throw store.failure("Saved usage map appears twice") }
                header[keyPath: field] = try store.readMap(section)
            }
        }
    }

    private static let maps: [Map] = [
        Map("cursors", \Ledger.cursors), Map("historyCursors", \Ledger.historyCursors),
        Map("quotas", \Ledger.quotas), Map("plans", \Ledger.plans), Map("accounts", \Ledger.accounts),
        Map("claudeCounters", \Ledger.claudeCounters), Map("usageCoverage", \Ledger.usageCoverage),
        Map("claudeFileChecks", \Ledger.claudeFileChecks), Map("claudeCursors", \Ledger.claudeCursors),
        Map("openCodeCursors", \Ledger.openCodeCursors), Map("openCodePending", \Ledger.openCodePending),
        Map("sourceErrors", \Ledger.sourceErrors), Map("sourceErrorPaths", \Ledger.sourceErrorPaths),
        Map("diagnosticObservations", \Ledger.diagnosticObservations),
    ]

    private func updateMap<Value: Codable & Equatable>(_ section: String, _ next: [String: Value],
                                                        from previous: [String: Value]) throws {
        guard next != previous else { return }
        try statement("INSERT OR REPLACE INTO ledger_metadata(section,key,payload) VALUES (?,?,?)") { query in
            try bind(section, to: query, at: 1)
            for (key, value) in next where previous[key] != value {
                sqlite3_reset(query)
                try bind(key, to: query, at: 2)
                try bind(encoder.encode(value), to: query, at: 3)
                try stepDone(query)
            }
        }
        try statement("DELETE FROM ledger_metadata WHERE section=? AND key=?") { query in
            try bind(section, to: query, at: 1)
            for key in previous.keys where next[key] == nil {
                sqlite3_reset(query)
                try bind(key, to: query, at: 2)
                try stepDone(query)
            }
        }
    }

    private func readMap<Value: Codable>(_ section: String) throws -> [String: Value] {
        var values: [String: Value] = [:]
        try statement("SELECT key,payload FROM ledger_metadata WHERE section=?") { query in
            try bind(section, to: query, at: 1)
            try rows(query) {
                guard let bytes = sqlite3_column_text(query, 0) else { throw failure("A saved usage key is missing") }
                let key = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(query, 0))), as: UTF8.self)
                values[key] = try decoder.decode(Value.self, from: data(query, at: 1))
            }
        }
        return values
    }
}
