import Foundation
import CryptoKit

/// Durable byte position; the boundary digest detects replacement/truncation
/// without rereading an unchanged transcript prefix.
struct ClaudeCursor: Codable {
    var offset: UInt64
    var stamp: ClaudeFileCheck
    var boundary: String
}

struct ScanWork {
    var codexFiles = 0
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
    func markDirty() { dirtyGeneration &+= 1; contentGeneration &+= 1 }
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
