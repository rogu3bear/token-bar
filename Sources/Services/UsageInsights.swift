import Observation
import Foundation
import Combine

struct UsageInsightsSummary {
    enum OutputChangeClaim: Equatable {
        case changed(percent: Double, recent: Int, previous: Int)
        case missingPeriod
        case missingOutput(Int)
        case zeroBaseline(recent: Int)
    }
    enum PeakContextClaim: Equatable {
        case measured(Double, samples: Int, records: Int)
        case unavailable
    }
    var report = UsageReport()
    var recentOutput = 0
    var previousOutput = 0
    var recentRecords = 0
    var previousRecords = 0
    var comparisonMissingOutput = 0
    /// Absence of records is not evidence of zero activity. A zero baseline is
    /// undefined, not 0%.
    var outputChangeClaim: OutputChangeClaim {
        guard recentRecords > 0, previousRecords > 0 else { return .missingPeriod }
        if comparisonMissingOutput > 0 { return .missingOutput(comparisonMissingOutput) }
        if previousOutput <= 0 { return .zeroBaseline(recent: recentOutput) }
        return .changed(percent: (Double(recentOutput) / Double(previousOutput) - 1) * 100,
                        recent: recentOutput, previous: previousOutput)
    }
    var outputChangePercent: Double? {
        if case .changed(let percent, _, _) = outputChangeClaim { return percent }
        return nil
    }
    func outputChangeHeadline(compactTokens: (Int) -> String) -> String {
        switch outputChangeClaim {
        case .changed(let percent, _, _) where percent == 0:
            return "Unchanged between recorded periods"
        case .changed(let percent, _, _):
            return String(format: "%.1f%% %@ the prior period", abs(percent), percent > 0 ? "above" : "below")
        case .missingPeriod:
            return "Comparison unavailable: one or both periods have no local records."
        case .missingOutput(let count):
            return "Comparison unavailable: \(count.formatted()) records lack explicit output counters."
        case .zeroBaseline(let recent):
            return "\(compactTokens(recent)) recorded output tokens after a prior period with zero recorded output. A percentage change is undefined."
        }
    }
    func outputChangeEvidence(compactTokens: (Int) -> String) -> String? {
        guard case .changed(_, let recent, let previous) = outputChangeClaim else { return nil }
        return "\(compactTokens(recent)) output tokens in the last seven full days · \(compactTokens(previous)) in the preceding seven."
    }
    var activeDays = 0
    var busiestDay: DailyUsage?
    var cacheShare: Double?
    var cacheShareCaption: String? {
        cacheShare.map {
            String(format: "%.1f%% of recorded input was cached. Cached input is included in input; this is not a cost-savings estimate.", $0 * 100)
        }
    }
    /// Highest single-request context occupancy observed, and how many requests
    /// could be measured. Absent when no request carried both a known input and
    /// a harness-reported window.
    var peakContext: Double?
    var contextSamples = 0
    var peakContextClaim: PeakContextClaim {
        if let peak = peakContext {
            return .measured(peak, samples: contextSamples, records: report.entries.count)
        }
        return .unavailable
    }
    var peakContextHeadline: String {
        switch peakContextClaim {
        case .measured(let peak, _, _):
            return String(format: "Highest measured request occupancy: %.0f%%", peak * 100)
        case .unavailable:
            return "Context utilization unavailable: no records contain both request input and a known context window."
        }
    }
    var peakContextEvidence: String? {
        guard case .measured(_, let samples, let records) = peakContextClaim else { return nil }
        return "\(samples.formatted()) of \(records.formatted()) records contain measurable request context. This is a recorded maximum, not an anomaly threshold or a forecast."
    }
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
    // Requested report work must make progress while other applications are busy.
    // Match ReportScheduler; background QoS may defer even tiny visible queries.
    private let queue = DispatchQueue(label: "local.codex-token-bar.usage-insights", qos: .utility, autoreleaseFrequency: .workItem)
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
