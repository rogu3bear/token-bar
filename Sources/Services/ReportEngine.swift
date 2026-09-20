import Foundation

/// Report selections change at local calendar boundaries or when a future
/// record becomes current, not merely because another minute has elapsed.
struct ReportValidity {
    var observedAt: Date
    var until: Date
    var calendar: Calendar
    init(now: Date, futureRecord: Date?, calendar: Calendar = .current) {
        observedAt = now
        self.calendar = calendar
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        until = min(midnight, futureRecord ?? midnight)
    }
    func contains(_ now: Date, calendar: Calendar = .current) -> Bool {
        self.calendar == calendar && now >= observedAt && now < until
    }
}

/// Built once per entry revision. Session tariffs intentionally span the entire
/// ledger, while the date index bounds each report selection.
struct ReportIndex {
    var entries: [Entry]
    var chronological: [Int]
    var context: CostContextIndex
    init(_ entries: [Entry]) {
        self.entries = entries
        chronological = entries.indices.sorted {
            entries[$0].date == entries[$1].date ? $0 < $1 : entries[$0].date < entries[$1].date
        }
        context = CostContextIndex(entries)
    }
    /// Existing observations retain their index and session context. Historical
    /// enrichment/replacement must rebuild because it can change prior tariffs.
    mutating func append(_ source: [Entry]) -> Bool {
        guard source.count >= entries.count, source.starts(with: entries) else { return false }
        let start = entries.count
        let added = Array(source.dropFirst(start))
        context.append(added)
        entries = source
        let newOrder = (start..<source.count).sorted {
            source[$0].date == source[$1].date ? $0 < $1 : source[$0].date < source[$1].date
        }
        var merged: [Int] = []; merged.reserveCapacity(source.count)
        var old = 0, new = 0
        while old < chronological.count && new < newOrder.count {
            if source[chronological[old]].date <= source[newOrder[new]].date {
                merged.append(chronological[old]); old += 1
            } else { merged.append(newOrder[new]); new += 1 }
        }
        merged.append(contentsOf: chronological.dropFirst(old))
        merged.append(contentsOf: newOrder.dropFirst(new))
        chronological = merged
        return true
    }
    init(entries: [Entry], chronological: [Int], context: CostContextIndex) {
        self.entries = entries; self.chronological = chronological; self.context = context
    }
    private func bound(_ date: Date, inclusive: Bool) -> Int {
        var low = 0, high = chronological.count
        while low < high {
            let middle = (low + high) / 2
            let value = entries[chronological[middle]].date
            if value < date || (inclusive && value == date) { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func select(_ query: UsageQuery, catalog: [String: TaskInfo], now: Date, calendar: Calendar = .current) -> [Entry] {
        let bounds = query.timeBounds(now: now, calendar: calendar)
        let lower = bound(bounds.lower, inclusive: false)
        let upper = bound(bounds.upper, inclusive: bounds.inclusive)
        guard lower < upper else { return [] }
        // Preserve source order, including ties, for stable grouping/export.
        return chronological[lower..<upper].sorted().compactMap {
            let entry = entries[$0]
            return query.matches(entry, catalog: catalog, bounds: bounds) ? entry : nil
        }
    }
    func validity(now: Date, calendar: Calendar = .current) -> ReportValidity {
        let next = bound(now, inclusive: true)
        return ReportValidity(now: now, futureRecord: next < chronological.count ? entries[chronological[next]].date : nil, calendar: calendar)
    }
}

struct ReportRevisionInputs: Equatable {
    var entries: UInt64
    var catalog: UInt64
    var query: UsageQuery
    var effort: String
    var service: CostService
    var basis: CostPriceBasis
}

/// Serial report-queue cache. Pricing-only changes reuse the History report and
/// selection; clock and metadata changes invalidate explicitly.
final class ReportEngine {
    private var index: ReportIndex?
    private var revision: UInt64?
    private var previous: ReportRevisionInputs?
    private var selected: [Entry] = []
    private var context = CostContextIndex([])
    private var usage = UsageReport()
    private var costs = CostReport()
    private(set) var validity: ReportValidity?
    private let storageURL: URL?
    private var triedRestore = false
    private(set) var indexRestores = 0
    private(set) var indexAppends = 0
    private(set) var storageError: String?
    init(storageURL: URL? = nil) { self.storageURL = storageURL }
    private(set) var indexBuilds = 0
    private(set) var usageBuilds = 0
    private(set) var costBuilds = 0

    func build(source: [Entry], inputs: ReportRevisionInputs, catalog: [String: TaskInfo], now: Date, sourceID: UUID? = nil,
               calendar: Calendar = .current, expand: (([Entry]) -> [Entry]?)? = nil) -> (UsageReport, CostReport) {
        if revision != inputs.entries {
            var restored = false
            if !triedRestore, let storageURL, let sourceID {
                do {
                    index = try ReportIndexStorage.load(storageURL, contentID: sourceID, entries: source)
                    if index != nil { indexRestores += 1; restored = true }
                } catch { storageError = "Saved report index could not be read; rebuilding from saved usage." }
            }
            triedRestore = true
            if !restored {
                if index != nil, index!.append(source) { indexAppends += 1 }
                else { index = ReportIndex(source); indexBuilds += 1 }
            }
            revision = inputs.entries
            if !restored, let storageURL, let sourceID {
                do { try ReportIndexStorage.save(index!, to: storageURL, contentID: sourceID); storageError = nil }
                catch { storageError = "Report index could not be saved; usage history remains available." }
            }
        }
        let selectionChanged = previous?.entries != inputs.entries || previous?.catalog != inputs.catalog ||
            previous?.query != inputs.query || validity?.contains(now, calendar: calendar) != true
        if selectionChanged {
            let index = index!
            selected = index.select(inputs.query, catalog: catalog, now: now, calendar: calendar)
            context = index.context
            let bounds = inputs.query.timeBounds(now: now, calendar: calendar)
            if ReportScope.expandsDailyAggregates(selected: selected, query: inputs.query, bounds: bounds, calendar: calendar),
               selected.contains(where: { $0.bucket == "day" }), let expanded = expand?(selected) {
                // Expanded request metadata can refine a session tariff. Replace
                // only selected buckets, retaining out-of-period observations.
                context = CostContextIndex(source.filter { !inputs.query.matches($0, catalog: catalog, bounds: bounds) } + expanded)
                selected = expanded
            }
            usage = UsageReport.build(entries: selected, query: inputs.query, catalog: catalog, now: now, prefiltered: true)
            usageBuilds += 1
            validity = index.validity(now: now, calendar: calendar)
        }
        if selectionChanged || previous?.effort != inputs.effort ||
            previous?.service != inputs.service || previous?.basis != inputs.basis {
            costs = CostReport.build(source: selected, query: inputs.query, catalog: catalog,
                effort: inputs.effort, service: inputs.service, basis: inputs.basis, now: now,
                context: context, prefiltered: true)
            costBuilds += 1
        }
        previous = inputs
        return (usage, costs)
    }
}

/// Same-day History/Cost selections expand daily aggregates to request minutes. Today is always that scope.
enum ReportScope {
    static func expandsDailyAggregates(selected: [Entry], query: UsageQuery,
                                       bounds: (lower: Date, upper: Date, inclusive: Bool),
                                       calendar: Calendar) -> Bool {
        let days = Set(selected.map { calendar.startOfDay(for: $0.date) })
        let last = bounds.inclusive ? bounds.upper : bounds.upper.addingTimeInterval(-0.001)
        return days.count == 1 || query.period == 0 || calendar.isDate(bounds.lower, inSameDayAs: last)
    }
}
