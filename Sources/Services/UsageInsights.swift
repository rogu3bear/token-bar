import Observation
import Foundation
import Combine

struct UsageInsightsSummary {
    var report = UsageReport()
    var recentOutput = 0
    var previousOutput = 0
    var recentRecords = 0
    var previousRecords = 0
    var comparisonMissingOutput = 0
    /// Absence of records is not evidence of zero activity.
    var outputChangePercent: Double? {
        guard recentRecords > 0, previousRecords > 0,
              comparisonMissingOutput == 0, previousOutput > 0 else { return nil }
        return (Double(recentOutput) / Double(previousOutput) - 1) * 100
    }
    var activeDays = 0
    var busiestDay: DailyUsage?
    var cacheShare: Double?
    /// Highest single-request context occupancy observed, and how many requests
    /// could be measured. Absent when no request carried both a known input and
    /// a harness-reported window.
    var peakContext: Double?
    var contextSamples = 0
    var earliest: Date?
    static func build(entries: [Entry], catalog: [String: TaskInfo], now: Date = Date()) -> UsageInsightsSummary {
        var result = UsageInsightsSummary()
        result.report = UsageReport.build(entries: entries, query: UsageQuery(period: 3), catalog: catalog, now: now)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let recent = calendar.date(byAdding: .day, value: -7, to: today)!
        let previous = calendar.date(byAdding: .day, value: -14, to: today)!
        for entry in entries where entry.date < today {
            if entry.date >= recent {
                result.recentOutput += entry.tokens.output
                result.recentRecords += 1
            } else if entry.date >= previous {
                result.previousOutput += entry.tokens.output
                result.previousRecords += 1
            }
            if entry.date >= previous && !entry.hasField("output_tokens") {
                result.comparisonMissingOutput += 1
            }
        }
        result.activeDays = result.report.days.filter { $0.tokens.total > 0 }.count
        result.busiestDay = result.report.days.max { $0.tokens.output < $1.tokens.output }
        let totals = result.report.totals
        if totals.input > 0 && result.report.entries.allSatisfy({ $0.hasField("input_tokens") && $0.hasField("cached_input_tokens") && $0.tokens.cached <= $0.tokens.input }) {
            result.cacheShare = Double(totals.cached) / Double(totals.input)
        }
        let occupancies = result.report.entries.compactMap(\.contextOccupancy)
        result.contextSamples = occupancies.count
        result.peakContext = occupancies.max()
        result.earliest = entries.map(\.date).min()
        return result
    }
}

@Observable final class UsageInsightsModel {
    var summary = UsageInsightsSummary()
    var busy = false
    private(set) var hasResult = false
    private(set) var sourceUnavailable = false
    private let queue = DispatchQueue(label: "local.codex-token-bar.usage-insights", qos: .background, autoreleaseFrequency: .workItem)
    @ObservationIgnored private var pending: ([Entry], [String: TaskInfo], UUID?, UInt64?)?
    @ObservationIgnored private var inFlightEntries: [Entry]?
    @ObservationIgnored private var inFlightCatalog: [String: TaskInfo]?
    @ObservationIgnored private var evaluatedEntries: [Entry]?
    @ObservationIgnored private var evaluatedCatalog: [String: TaskInfo]?
    @ObservationIgnored private var validity: ReportValidity?
    @ObservationIgnored private var evaluatedRevision: UUID?
    @ObservationIgnored private var evaluatedCatalogRevision: UInt64?
    @ObservationIgnored private var inFlightRevision: UUID?
    @ObservationIgnored private var inFlightCatalogRevision: UInt64?
    private(set) var evaluatedAt: Date?
    private let clock: () -> Date
    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    func refresh(entries: [Entry], catalog: [String: TaskInfo], sourceAvailable: Bool = true, revision: UUID? = nil, catalogRevision: UInt64? = nil) {
        sourceUnavailable = !sourceAvailable
        guard sourceAvailable else { pending = nil; return }
        if busy {
            let same = revision != nil && catalogRevision != nil
                ? revision == inFlightRevision && catalogRevision == inFlightCatalogRevision
                : entries == inFlightEntries && catalog == inFlightCatalog
            pending = same ? nil : (entries, catalog, revision, catalogRevision)
            return
        }
        let now = clock()
        let same = revision != nil && catalogRevision != nil
            ? revision == evaluatedRevision && catalogRevision == evaluatedCatalogRevision
            : entries == evaluatedEntries && catalog == evaluatedCatalog
        if same && validity?.contains(now) == true { return }
        busy = true
        inFlightEntries = revision == nil ? entries : nil; inFlightCatalog = catalogRevision == nil ? catalog : nil
        inFlightRevision = revision; inFlightCatalogRevision = catalogRevision
        queue.async {
            let result = UsageInsightsSummary.build(entries: entries, catalog: catalog, now: now)
            DispatchQueue.main.async {
                self.busy = false
                self.inFlightEntries = nil; self.inFlightCatalog = nil
                guard !self.sourceUnavailable else { return }
                do { // Publish completed evidence even while newer usage is queued.
                    self.summary = result
                    self.hasResult = true
                    self.evaluatedEntries = revision == nil ? entries : nil
                    self.evaluatedCatalog = catalogRevision == nil ? catalog : nil
                    self.evaluatedRevision = revision; self.evaluatedCatalogRevision = catalogRevision
                    self.evaluatedAt = now
                    self.validity = ReportValidity(now: now, futureRecord: entries.lazy.map(\.date).filter { $0 > now }.min())
                }
                if let next = self.pending {
                    self.pending = nil
                    self.refresh(entries: next.0, catalog: next.1, revision: next.2, catalogRevision: next.3)
                }
            }
        }
    }
}
