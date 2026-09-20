import Foundation
import Darwin

/// Publish a complete private cache without exposing a permissive intermediate
/// file or replacing the previous checkpoint before the new bytes are flushed.
enum PrivateCache {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(JSONEncoder().encode(value), to: url)
    }
}
