import Foundation

/// One row of a report grouped by a dimension that was previously unmodeled.
/// `providers` and `harnesses` are the cross-dimension evidence: they prove the
/// grouping key does not silently stand in for another dimension.
struct DimensionRow: Identifiable {
    var id: String
    /// Display label. `nil` in the source becomes an explicit unattributed row.
    var name: String
    var tokens: Tokens
    var events: Int
    /// Distinct values of the other dimensions seen under this key, sorted.
    var providers: [String]
    var harnesses: [String]
    var models: [String]
    /// Full paths observed for a project key. More than one means the same
    /// directory was recorded under different spellings.
    var paths: [String]
    var attributed: Bool
}

/// Groups usage by harness or by project without collapsing either into the
/// provider dimension.
enum DimensionReport {
    static let unattributed = "Unattributed"

    static func byHarness(_ entries: [Entry]) -> [DimensionRow] {
        group(entries, key: { $0.harness }, name: { $0.harness })
    }

    static func byProject(_ entries: [Entry]) -> [DimensionRow] {
        group(entries, key: { Project.key($0.projectPath) }, name: { Project.name($0.projectPath) })
    }

    /// Distinct providers reached by one harness. The value that makes harness a
    /// real dimension: a result above one cannot be expressed by `provider` alone.
    static func providers(ofHarness harness: String, in entries: [Entry]) -> [String] {
        sortedDistinct(entries.filter { $0.harness == harness }.compactMap(\.provider))
    }

    /// Distinct harnesses that reached one provider.
    static func harnesses(ofProvider provider: String, in entries: [Entry]) -> [String] {
        sortedDistinct(entries.filter { $0.provider == provider }.compactMap(\.harness))
    }

    private static func group(_ entries: [Entry], key: (Entry) -> String?,
                              name: (Entry) -> String?) -> [DimensionRow] {
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        var labels: [String: String] = [:]
        for entry in entries {
            let resolved = key(entry)
            let id = resolved ?? unattributed
            if buckets[id] == nil { order.append(id) }
            buckets[id, default: []].append(entry)
            // First non-empty label wins, so a project keeps one display name
            // even when its path was recorded under several spellings.
            if labels[id] == nil { labels[id] = resolved == nil ? unattributed : (name(entry) ?? id) }
        }
        return order.map { id in
            let bucket = buckets[id] ?? []
            return DimensionRow(
                id: id,
                name: labels[id] ?? id,
                tokens: bucket.reduce(Tokens()) { $0 + $1.tokens },
                events: bucket.reduce(0) { $0 + $1.eventCount },
                providers: sortedDistinct(bucket.compactMap(\.provider)),
                harnesses: sortedDistinct(bucket.compactMap(\.harness)),
                models: sortedDistinct(bucket.map(\.model)),
                paths: sortedDistinct(bucket.compactMap { Project.path($0.projectPath) }),
                attributed: id != unattributed)
        }.sorted { ($0.tokens.total, $1.name) > ($1.tokens.total, $0.name) }
    }

    private static func sortedDistinct(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}
