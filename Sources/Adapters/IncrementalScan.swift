import Foundation
import CryptoKit
import Darwin

/// Durable byte position; the boundary digest detects replacement/truncation
/// without rereading an unchanged transcript prefix.
struct ClaudeCursor: Codable {
    var offset: UInt64
    var stamp: ClaudeFileCheck
    var boundary: String
}

struct ScanWork {
    var codexFiles = 0
    var codexBytes = 0
    var codexValidationBytes = 0
    var claudeBytes = 0
    var grokFiles = 0
    var openCodeRows = 0
}

enum CheckpointPhase: Equatable { case ledger, index, acknowledge }

struct UsageCheckpoint {
    let generation: UInt64
    let contentGeneration: UInt64
    let ids: Set<String>
    let url: URL
    var indexed = false
}

/// Contains cursor/provider metadata only, bound to one full ledger snapshot.
/// A new full save invalidates the prior checkpoint atomically by changing its ID.
struct LedgerMetadataCheckpoint: Codable {
    var version = 1
    let baseline: UUID
    let metadata: Ledger
}

extension UsageScanner {
    static func metadataURL(for stateURL: URL) -> URL {
        stateURL.deletingPathExtension().appendingPathExtension("checkpoint.json")
    }
    static func loadLedger(from url: URL) throws -> Ledger {
        var ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        let metadataURL = metadataURL(for: url)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let checkpoint = try JSONDecoder().decode(LedgerMetadataCheckpoint.self, from: Data(contentsOf: metadataURL))
            guard checkpoint.version == 1, checkpoint.metadata.entries.isEmpty,
                  checkpoint.metadata.checkpointID == checkpoint.baseline else {
                throw RequestArchive.failure("Saved usage checkpoint is invalid; it has been preserved")
            }
            if checkpoint.baseline == ledger.checkpointID {
                var restored = checkpoint.metadata
                restored.entries = ledger.entries
                // The full ledger's recovery batch may still need indexing.
                restored.eventIDs = (restored.eventIDs ?? []).union(ledger.eventIDs ?? [])
                ledger = restored
            }
        }
        return ledger
    }
    func retainErrors(_ errors: [String], for provider: String, paths: Set<URL>? = nil) {
        let scope = paths.map { Set($0.map { $0.resolvingSymlinksInPath().path }) }
        let previous = ledger.sourceErrors?[provider]
        let failed = ledger.sourceErrorPaths?[provider]
        // A successful partial scan proves recovery only for its own failed
        // paths. Legacy/provider-wide errors require a full provider scan.
        if errors.isEmpty, previous != nil, let scope,
           failed == nil || failed!.isEmpty || !failed!.isSubset(of: scope) { return }
        var messages = Set(errors)
        if !errors.isEmpty, scope != nil, let previous { messages.formUnion(previous.components(separatedBy: "\n")) }
        let message = messages.isEmpty ? nil : messages.sorted().joined(separator: "\n")
        let unresolved: Set<String>?
        if message == nil || scope == nil { unresolved = nil }
        else if previous != nil && failed == nil { unresolved = nil }
        else { unresolved = (failed ?? []).union(scope!) }
        guard previous != message || failed != unresolved else { return }
        if ledger.sourceErrors == nil { ledger.sourceErrors = [:] }
        if ledger.sourceErrorPaths == nil { ledger.sourceErrorPaths = [:] }
        ledger.sourceErrors?[provider] = message
        ledger.sourceErrorPaths?[provider] = unresolved
        markMetadataDirty()
    }

    static func contains(_ paths: Set<URL>?, root: URL?) -> Bool {
        guard let paths else { return root != nil }
        guard let root else { return false }
        return paths.contains { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
    }

    /// Serial scanner queue only. Cursor/metadata mutations count as durable work;
    /// a polling timestamp alone does not.
    func markDirty() { dirtyGeneration &+= 1; contentGeneration &+= 1; ledger.reportRevision = UUID() }
    func markMetadataDirty() { dirtyGeneration &+= 1 }
    var needsSave: Bool { pendingCheckpoint != nil || dirtyGeneration != savedGeneration }
    func saveIfNeeded(now: Date = Date(), force: Bool = false) throws {
        if let loadError { throw RequestArchive.failure(loadError) }
        // Finish the already durable snapshot before capturing newer admissions.
        // Retrying SQLite phases never re-encodes an identical JSON snapshot.
        try finishCheckpoint()
        guard dirtyGeneration != savedGeneration,
              force || now.timeIntervalSince(lastSave) >= 15 else { return }
        let metadataOnly = ledger.checkpointID != nil && contentGeneration == savedContentGeneration &&
            (ledger.eventIDs ?? []).isEmpty
        let url = metadataOnly ? Self.metadataURL(for: stateURL) : stateURL
        let checkpoint = UsageCheckpoint(generation: dirtyGeneration, contentGeneration: contentGeneration,
                                         ids: ledger.eventIDs ?? [], url: url)
        try checkpointWillRun?(.ledger)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if metadataOnly {
            var metadata = ledger
            metadata.entries = []
            try JSONEncoder().encode(LedgerMetadataCheckpoint(baseline: ledger.checkpointID!, metadata: metadata))
                .write(to: url, options: .atomic)
        } else {
            var durable = ledger
            durable.checkpointID = UUID()
            try JSONEncoder().encode(durable).write(to: url, options: .atomic)
            ledger.checkpointID = durable.checkpointID
        }
        pendingCheckpoint = checkpoint
        lastSave = now
        persistenceCount += 1
        try finishCheckpoint()
    }

    private func finishCheckpoint() throws {
        guard let checkpoint = pendingCheckpoint else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpoint.url.path)
        guard let eventIndex else { throw RequestArchive.failure("Event identity index is unavailable") }
        if !checkpoint.indexed {
            try checkpointWillRun?(.index)
            try eventIndex.commit(checkpoint.ids)
            pendingCheckpoint?.indexed = true
        }
        try checkpointWillRun?(.acknowledge)
        try requestArchive?.acknowledge { id in
            // Only the index contains identities backed by durable totals.
            // ledger.eventIDs may also contain newer, unsaved admissions.
            guard let found = eventIndex.contains(id) else { throw RequestArchive.failure("Event identity could not be verified") }
            return found
        }
        ledger.eventIDs?.subtract(checkpoint.ids)
        savedGeneration = checkpoint.generation
        savedContentGeneration = checkpoint.contentGeneration
        pendingCheckpoint = nil
        // No cleanup-only write: the next genuine save replaces the residual
        // on-disk ID batch. It is recovery evidence, not lifetime accumulation.
    }

    static func boundary(_ handle: FileHandle, offset: UInt64) throws -> String {
        let length = min(offset, 128)
        try handle.seek(toOffset: offset - length)
        let bytes = try handle.read(upToCount: Int(length)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func claudeTail(_ url: URL, key: String, stamp: ClaudeFileCheck,
                    consume: (Data) -> Void) throws -> ClaudeCursor {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        if !rebuilding, let saved = ledger.claudeCursors?[key],
           saved.stamp.inode == stamp.inode, stamp.size >= saved.offset,
           !(stamp.size == saved.stamp.size && stamp.modified != saved.stamp.modified),
           try Self.boundary(handle, offset: saved.offset) == saved.boundary {
            offset = saved.offset
        }
        guard let file = fopen(url.path, "r") else { throw POSIXError(.EACCES) }
        defer { fclose(file) }
        guard fseeko(file, off_t(offset), SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        while UInt64(ftello(file)) < stamp.size {
            let length = getline(&line, &capacity, file)
            guard length >= 0, let line else { break }
            lastWork.claudeBytes += length
            guard line[length - 1] == 10 else { break }
            consume(Data(bytes: line, count: length - 1))
            offset = UInt64(ftello(file))
        }
        if ferror(file) != 0 { throw POSIXError(.EIO) }
        return ClaudeCursor(offset: offset, stamp: stamp, boundary: try Self.boundary(handle, offset: offset))
    }
}

/// Stat and both digests describe the same opened descriptor used for parsing.
struct CodexContinuity: Codable, Equatable {
    var device: UInt64
    var inode: UInt64
    var size: UInt64
    var modified: Int64
    var modifiedNanos: Int64
    var changed: Int64
    var changedNanos: Int64
    var prefix: String = ""
    var boundary: String = ""

    init(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_size >= 0,
              (value.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EIO) }
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino
        size = UInt64(value.st_size)
        modified = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changed = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
    func sameFile(_ other: CodexContinuity) -> Bool { device == other.device && inode == other.inode }
}

/// A counter boundary is observation evidence, not proof of admission in either
/// date scope. While it is missing, only independently stated requests are safe.
struct CodexReconciliation: Codable, Equatable {
    var session: String?
    var previous: Tokens?
    var fingerprint: String?
    var covered: CodexCounterBoundary?
    var legacy: Bool?
    var resume: CodexCounterBoundary?
}
struct CodexCounterBoundary: Codable, Equatable {
    var session: String?
    var total: Tokens
    var date: Date
    var fingerprint: String
    var verifiedAt: Date?
}
enum CodexReadPhase { case opened, line, validated }

extension UsageScanner {
    private func codexAliases(_ url: URL) -> [String] {
        let path = url.resolvingSymlinksInPath().path
        let root = home.resolvingSymlinksInPath().path
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        return [relative, path, "/private" + path, String(path.dropFirst(path.hasPrefix("/private/") ? 8 : 0))]
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    func codexCursorKey(_ url: URL, historical: Bool) -> String {
        let cursors = historical ? (ledger.historyCursors ?? [:]) : ledger.cursors
        let aliases = codexAliases(url)
        // Never select a live cursor through the historical namespace (or vice
        // versa). Keep a reconciled primary stable while retaining legacy aliases.
        return aliases.first { cursors[$0]?.aliasWitness != nil } ??
            aliases.first { cursors[$0] != nil } ?? aliases[0]
    }
    func reconcileCodexAliases(_ url: URL, key: String, historical: Bool, cursor: inout Cursor) throws {
        let cursors = historical ? (ledger.historyCursors ?? [:]) : ledger.cursors
        let others = codexAliases(url).filter { $0 != key }.compactMap { alias in cursors[alias].map { (alias, $0) } }
        guard !others.isEmpty else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let evidence = try encoder.encode(Dictionary(uniqueKeysWithValues: others))
        let witness = SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
        guard witness != cursor.aliasWitness else { return }
        let candidates = [cursor] + others.map { $0.1 }
        // This upper bound constrains reconciliation; it is never admitted as
        // usage. Incomparable legacy aliases must not pick a weaker baseline.
        var floor = Tokens()
        for candidate in candidates {
            for value in [candidate.previous, candidate.admittedBoundary?.total].compactMap({ $0 }) {
                floor.input = max(floor.input, value.input); floor.output = max(floor.output, value.output)
            }
        }
        let sessions = Set(candidates.compactMap(\.sourceSession))
        let session = sessions.count == 1 && candidates.allSatisfy({ $0.sourceSession != nil }) ? sessions.first : nil
        let date = candidates.compactMap { $0.admittedBoundary?.date }.max() ?? .distantPast
        cursor.reconciliation = CodexReconciliation(session: session, previous: floor, fingerprint: nil,
            covered: CodexCounterBoundary(session: session, total: floor, date: date, fingerprint: ""), legacy: true)
        cursor.continuity = nil
        cursor.aliasWitness = witness
        cursor.continuityGap = "Multiple legacy cursor aliases required reconciliation; prior totals retained and coverage remains incomplete."
    }
    private func codexDigest(_ descriptor: Int32, start: UInt64, length: Int) throws -> String {
        var bytes = Data(count: length)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(start)) }
        guard count == length else { throw POSIXError(.EIO) }
        lastWork.codexValidationBytes += length
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    func readLog(_ url: URL, session: String, cursor: inout Cursor,
                 account: Account?, poll: Date, historical: Bool, startDay: Date) throws {
        guard let file = fopen(url.path, "r") else { throw POSIXError(.EACCES) }
        defer { fclose(file) }
        let descriptor = fileno(file)
        let initial = try CodexContinuity(descriptor)
        guard historical || Date(timeIntervalSince1970: Double(initial.modified)) >= startDay else { return }
        try codexReadWillRun?(.opened, url)
        var next = cursor
        var continuous = false
        if let saved = cursor.continuity, saved.sameFile(initial), initial.size >= cursor.offset,
           !(initial.size == saved.size && (initial.modified != saved.modified || initial.modifiedNanos != saved.modifiedNanos || initial.changed != saved.changed || initial.changedNanos != saved.changedNanos)) {
            let prefix = try codexDigest(descriptor, start: 0, length: Int(min(cursor.offset, 256)))
            let boundary = try codexDigest(descriptor, start: cursor.offset - min(cursor.offset, 128), length: Int(min(cursor.offset, 128)))
            continuous = prefix == saved.prefix && boundary == saved.boundary
        }
        if !continuous {
            next = Cursor()
            next.continuityGap = cursor.continuityGap
            next.aliasWitness = cursor.aliasWitness
            next.admittedBoundary = cursor.admittedBoundary
            if cursor.offset > 0 || cursor.previous != nil {
                let covered = cursor.admittedBoundary ?? (cursor.continuity == nil ? nil :
                    CodexCounterBoundary(session: cursor.sourceSession, total: Tokens(), date: .distantPast, fingerprint: ""))
                next.reconciliation = cursor.reconciliation ?? CodexReconciliation(session: cursor.sourceSession,
                    previous: cursor.previous, fingerprint: cursor.lastFingerprint, covered: covered, legacy: cursor.continuity == nil)
                next.reconciliation?.resume = nil
            }
        }
        guard next.offset <= initial.size, fseeko(file, off_t(next.offset), SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        // Defer admission until this file's read is validated. Retain only
        // counter/context records for the affected tail; prompt bytes are skipped.
        var records: [Data] = []
        while UInt64(ftello(file)) < initial.size {
            try codexReadWillRun?(.line, url)
            let length = getline(&line, &capacity, file)
            guard length >= 0, let line else { break }
            lastWork.codexBytes += length
            guard line[length - 1] == 10, UInt64(ftello(file)) <= initial.size else { break }
            let prefix = Data(bytes: line, count: min(length, 1024))
            if ["token_count", "turn_context", "session_meta"].contains(where: { prefix.range(of: Data($0.utf8)) != nil }) {
                records.append(Data(bytes: line, count: length - 1))
            }
            next.offset = UInt64(ftello(file))
        }
        guard ferror(file) == 0 else { throw POSIXError(.EIO) }
        var final = initial
        final.prefix = try codexDigest(descriptor, start: 0, length: Int(min(next.offset, 256)))
        final.boundary = try codexDigest(descriptor, start: next.offset - min(next.offset, 128), length: Int(min(next.offset, 128)))
        try codexReadWillRun?(.validated, url)
        guard try CodexContinuity(descriptor) == initial else {
            throw RequestArchive.failure("Session changed during reading; retrying without advancing its cursor")
        }
        // Path replacement must not combine the old opened file with a new
        // pathname's metadata or publish a cursor for the replacement bytes.
        let current = open(url.path, O_RDONLY | O_NONBLOCK)
        guard current >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(current) }
        guard try CodexContinuity(current) == initial else {
            throw RequestArchive.failure("Session was replaced during reading; retrying without advancing its cursor")
        }
        var accountContinuous = continuous || (cursor.offset == 0 && cursor.previous == nil)
        for record in records {
            let previousSession = next.sourceSession
            consume(record, session: session, cursor: &next, account: account, poll: poll,
                    historical: historical, continuous: accountContinuous)
            if previousSession != nil && previousSession != next.sourceSession { accountContinuous = false }
            if let loadError { throw RequestArchive.failure(loadError) }
        }
        if next.reconciliation != nil {
            if (!records.isEmpty || !continuous), var observation = next.lastObservation, observation.date <= poll {
                observation.verifiedAt = Date()
                next.reconciliation?.resume = observation
            }
            next.continuityGap = "Source continuity is incomplete; retained prior totals and admitted only independently supported requests."
        }
        if next.offset == 0 && cursor.offset == 0 && records.isEmpty { return }
        next.continuity = final
        cursor = next
    }
}
