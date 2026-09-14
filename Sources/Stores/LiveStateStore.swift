import Foundation
import SQLite3

/// Serial provider-queue ownership. Current account metadata and ordered history
/// commit together, without rewriting settled observations on every quota read.
final class LiveStateStore {
    let legacyURL: URL
    let databaseURL: URL
    private var database: OpaquePointer?
    private var loaded = false
    private var history: [QuotaReading] = []
    private var firstPosition: Int64 = 0
    private var metadata: Data?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var lastHistoryRowsWritten = 0
    private(set) var lastMetadataBytesWritten = 0

    init(legacyURL: URL) {
        self.legacyURL = legacyURL
        databaseURL = legacyURL.deletingPathExtension().appendingPathExtension("sqlite")
        encoder.outputFormatting = [.sortedKeys]
    }
    deinit { sqlite3_close(database) }

    func load() throws -> LiveState {
        let state: LiveState
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            state = try loadDatabase()
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            state = try decoder.decode(LiveState.self, from: Data(contentsOf: legacyURL))
        } else {
            state = LiveState()
        }
        loaded = true
        return state
    }

    func save(_ state: LiveState) throws {
        guard loaded else { throw failure("Saved account observations must be read before updating them.") }
        lastHistoryRowsWritten = 0; lastMetadataBytesWritten = 0
        if database == nil {
            if FileManager.default.fileExists(atPath: databaseURL.path) { _ = try loadDatabase() }
            else { try migrate(state); return }
        }
        try write(state)
    }

    private func migrate(_ state: LiveState) throws {
        let files = FileManager.default
        try files.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = databaseURL.deletingLastPathComponent().appendingPathComponent(".live-observations-" + UUID().uuidString + ".sqlite")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw failure("The account observation store could not be created.")
        }
        defer {
            // Only this attempt's unpublished temporary files are disposable.
            try? files.removeItem(at: temporary)
            try? files.removeItem(atPath: temporary.path + "-journal")
        }
        do {
            try open(temporary)
            try execute("CREATE TABLE current_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL, first_position INTEGER NOT NULL, history_count INTEGER NOT NULL)")
            try execute("CREATE TABLE quota_history (position INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
            try execute("PRAGMA user_version=1")
            history = []; metadata = nil; firstPosition = 0
            try write(state)
            sqlite3_close(database); database = nil
            // Publish a fully committed database. Never replace an existing store
            // or mutate the legacy JSON, which remains available for rollback.
            try files.moveItem(at: temporary, to: databaseURL)
            try open(databaseURL)
        } catch {
            sqlite3_close(database); database = nil
            history = []; metadata = nil; firstPosition = 0
            throw error
        }
    }

    private func open(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil
            throw failure("The saved account observation store could not be opened.")
        }
        do {
            sqlite3_busy_timeout(database, 3000)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("PRAGMA synchronous=FULL")
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    private func loadDatabase() throws -> LiveState {
        if database == nil { try open(databaseURL) }
        do {
            try statement("PRAGMA user_version") { query in
                guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) == 1 else {
                    throw failure("The saved account observation format is unsupported.")
                }
            }
            var state = LiveState(), expectedCount = 0, first: Int64 = 0
            var savedMetadata = Data()
            try statement("SELECT payload,first_position,history_count FROM current_state WHERE id=1") { query in
                guard sqlite3_step(query) == SQLITE_ROW else { throw failure("Saved account metadata is missing.") }
                savedMetadata = try data(query, column: 0)
                state = try decoder.decode(LiveState.self, from: savedMetadata)
                first = sqlite3_column_int64(query, 1)
                let count = sqlite3_column_int64(query, 2)
                guard first >= 0, count >= 0, count <= Int.max, first <= Int64.max - count else {
                    throw failure("Saved quota history has invalid bounds.")
                }
                expectedCount = Int(count)
            }
            var readings: [QuotaReading] = []
            try statement("SELECT position,payload FROM quota_history ORDER BY position") { query in
                var status = sqlite3_step(query)
                while status == SQLITE_ROW {
                    guard readings.count < expectedCount, sqlite3_column_int64(query, 0) == first + Int64(readings.count) else {
                        throw failure("Saved quota history is incomplete or out of order.")
                    }
                    readings.append(try decoder.decode(QuotaReading.self, from: data(query, column: 1)))
                    status = sqlite3_step(query)
                }
                guard status == SQLITE_DONE, readings.count == expectedCount else {
                    throw failure("Saved quota history could not be read completely.")
                }
            }
            history = readings; firstPosition = first; metadata = savedMetadata
            state.quotaHistory = readings
            return state
        } catch {
            sqlite3_close(database); database = nil
            throw error // Never silently fall back to an older JSON snapshot.
        }
    }

    private func write(_ state: LiveState) throws {
        var current = state
        let next = state.quotaHistory ?? state.samples
        current.quotaHistory = nil
        let payload = try encoder.encode(current)
        guard payload != metadata || next != history else { return }

        // Preserve a contiguous retained range, including exact duplicate rows.
        // Normal appends insert only the new suffix; 90-day expiry deletes only
        // the retired prefix. An actual correction replaces its affected suffix.
        let offset = next.first.flatMap { history.firstIndex(of: $0) } ?? history.count
        var retained = 0
        while retained < next.count && offset + retained < history.count && next[retained] == history[offset + retained] { retained += 1 }
        let first = retained > 0 ? firstPosition + Int64(offset) : 0
        guard first <= Int64.max - Int64(next.count) else { throw failure("Saved quota history exceeds its storage bounds.") }
        let end = first + Int64(retained)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM quota_history WHERE position < \(first) OR position >= \(end)")
            try statement("INSERT INTO quota_history(position,payload) VALUES (?,?)") { query in
                for index in retained..<next.count {
                    sqlite3_reset(query); sqlite3_clear_bindings(query)
                    sqlite3_bind_int64(query, 1, first + Int64(index))
                    try bind(encoder.encode(next[index]), to: query, column: 2)
                    guard sqlite3_step(query) == SQLITE_DONE else { throw failure("Quota history could not be saved.") }
                }
            }
            try statement("INSERT OR REPLACE INTO current_state(id,payload,first_position,history_count) VALUES (1,?,?,?)") { query in
                try bind(payload, to: query, column: 1)
                sqlite3_bind_int64(query, 2, first)
                sqlite3_bind_int64(query, 3, Int64(next.count))
                guard sqlite3_step(query) == SQLITE_DONE else { throw failure("Account metadata could not be saved.") }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        history = next; firstPosition = first; metadata = payload
        lastHistoryRowsWritten = next.count - retained
        lastMetadataBytesWritten = payload.count
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else {
            sqlite3_finalize(query); throw failure("The account observation store could not be queried.")
        }
        defer { sqlite3_finalize(query) }
        return try body(query)
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure("The account observation transaction could not be completed.") }
    }
    private func bind(_ data: Data, to query: OpaquePointer, column: Int32) throws {
        guard data.count <= Int32.max else { throw failure("An account observation is too large to save.") }
        let status = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(query, column, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK else { throw failure("An account observation could not be encoded for storage.") }
    }
    private func data(_ query: OpaquePointer, column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(query, column) else { throw failure("A saved account observation is missing.") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, column)))
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "TokenBar.LiveStateStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
