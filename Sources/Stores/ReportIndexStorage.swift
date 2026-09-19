import Foundation

/// Derived positions and tariff context only. The ledger's durable content ID
/// binds this disposable index to the exact entries that produced it.
enum ReportIndexStorage {
    static let version = 1
    private struct Saved: Codable {
        var version = ReportIndexStorage.version
        var contentID: UUID
        var count: Int
        var chronological: [Int]
        var context: CostContextIndex
    }
    static func load(_ url: URL, contentID: UUID, entries: [Entry]) throws -> ReportIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        guard saved.version == version, saved.contentID == contentID, saved.count == entries.count else { return nil }
        guard saved.chronological.count == entries.count,
              Set(saved.chronological) == Set(entries.indices),
              zip(saved.chronological, saved.chronological.dropFirst()).allSatisfy({
                  entries[$0].date < entries[$1].date || (entries[$0].date == entries[$1].date && $0 < $1)
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return ReportIndex(entries: entries, chronological: saved.chronological, context: saved.context)
    }
    static func save(_ index: ReportIndex, to url: URL, contentID: UUID) throws {
        try PrivateCache.write(Saved(contentID: contentID, count: index.entries.count,
                                     chronological: index.chronological, context: index.context), to: url)
    }
}
