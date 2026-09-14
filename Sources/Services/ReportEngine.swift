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
    let entries: [Entry]
    let chronological: [Int]
    let context: CostContextIndex
    init(_ entries: [Entry]) {
        self.entries = entries
        chronological = entries.indices.sorted {
            entries[$0].date == entries[$1].date ? $0 < $1 : entries[$0].date < entries[$1].date
        }
        context = CostContextIndex(entries)
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
    func select(_ query: UsageQuery, catalog: [String: TaskInfo], now: Date) -> [Entry] {
        let bounds = query.timeBounds(now: now)
        let lower = bound(bounds.lower, inclusive: false)
        let upper = bound(bounds.upper, inclusive: bounds.inclusive)
        guard lower < upper else { return [] }
        // Preserve source order, including ties, for stable grouping/export.
        return chronological[lower..<upper].sorted().compactMap {
            let entry = entries[$0]
            return query.matches(entry, catalog: catalog, bounds: bounds) ? entry : nil
        }
    }
    func validity(now: Date) -> ReportValidity {
        let next = bound(now, inclusive: true)
        return ReportValidity(now: now, futureRecord: next < chronological.count ? entries[chronological[next]].date : nil)
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
    private(set) var indexBuilds = 0
    private(set) var usageBuilds = 0
    private(set) var costBuilds = 0

    func build(source: [Entry], inputs: ReportRevisionInputs, catalog: [String: TaskInfo], now: Date,
               expand: (([Entry]) -> [Entry]?)? = nil) -> (UsageReport, CostReport) {
        if revision != inputs.entries {
            index = ReportIndex(source); revision = inputs.entries; indexBuilds += 1
        }
        let selectionChanged = previous?.entries != inputs.entries || previous?.catalog != inputs.catalog ||
            previous?.query != inputs.query || validity?.contains(now) != true
        if selectionChanged {
            let index = index!
            selected = index.select(inputs.query, catalog: catalog, now: now)
            context = index.context
            let bounds = inputs.query.timeBounds(now: now)
            let oneDay = Set(selected.map { Calendar.current.startOfDay(for: $0.date) }).count == 1
            let singleDay = oneDay || inputs.query.period == 0 || Calendar.current.isDate(bounds.lower,
                inSameDayAs: bounds.inclusive ? bounds.upper : bounds.upper.addingTimeInterval(-0.001))
            if singleDay, selected.contains(where: { $0.bucket == "day" }), let expanded = expand?(selected) {
                // Expanded request metadata can refine a session tariff. Replace
                // only selected buckets, retaining out-of-period observations.
                context = CostContextIndex(source.filter { !inputs.query.matches($0, catalog: catalog, bounds: bounds) } + expanded)
                selected = expanded
            }
            usage = UsageReport.build(entries: selected, query: inputs.query, catalog: catalog, now: now, prefiltered: true)
            usageBuilds += 1
            validity = index.validity(now: now)
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
