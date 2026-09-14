import Foundation

struct CoverageDimension: Codable, Identifiable {
    var id: String
    var title: String
    var knownTokens = 0
    var knownRecords = 0
    func tokenFraction(total: Int) -> Double? { total > 0 ? Double(knownTokens) / Double(total) : nil }
}
struct CostCoverage: Codable {
    var totalTokens = 0
    var records = 0
    var first: Date?
    var last: Date?
    var preciseTimestampRecords = 0
    var dimensions: [CoverageDimension] = [
        CoverageDimension(id: "model", title: "Model known"),
        CoverageDimension(id: "effort", title: "Reasoning level known"),
        CoverageDimension(id: "cache_read", title: "Cache reads recorded"),
        CoverageDimension(id: "cache_write", title: "Cache writes recorded"),
        CoverageDimension(id: "request", title: "Single-request size known"),
        CoverageDimension(id: "service", title: "Usage tier recorded"),
        CoverageDimension(id: "requested_service", title: "Requested tier recorded"),
        CoverageDimension(id: "provider", title: "Provider known"),
        CoverageDimension(id: "harness", title: "Tool known"),
        CoverageDimension(id: "project", title: "Project known"),
        CoverageDimension(id: "context_window", title: "Context window reported")
    ]
    /// Per-harness coverage. An aggregate percentage hides which tool is weak,
    /// which is the question that matters when four tools are supported.
    var byHarness: [String: CoverageDimension] = [:]
    mutating func add(_ entry: Entry) {
        let tool = entry.harness ?? "Unattributed"
        var row = byHarness[tool] ?? CoverageDimension(id: tool, title: tool)
        row.knownTokens += entry.tokens.total
        row.knownRecords += entry.eventCount
        byHarness[tool] = row

        let tokens = entry.tokens.total, count = entry.eventCount
        totalTokens += tokens; records += count
        let observed = entry.firstObserved ?? entry.date, latest = entry.lastObserved ?? entry.date
        first = min(first ?? observed, observed); last = max(last ?? latest, latest)
        if entry.firstObserved != nil || entry.bucket != "day" { preciseTimestampRecords += count }
        let known = [entry.model != "Unknown model", entry.effort != nil, entry.hasField("cached_input_tokens"),
                     entry.hasField("cache_write_input_tokens"), entry.isSingleRequest, entry.observedService != nil, entry.requestedService != nil,
                     entry.provider != nil, entry.harness != nil, entry.projectPath != nil, entry.contextWindow != nil]
        for index in dimensions.indices where known[index] { dimensions[index].knownTokens += tokens; dimensions[index].knownRecords += count }
    }
    static func build(_ entries: [Entry]) -> Self { entries.reduce(Self()) { value, entry in var next = value; next.add(entry); return next } }
    func json() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(self) }
}
