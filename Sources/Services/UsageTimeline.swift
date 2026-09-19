import Foundation

/// Minute positions come only from timestamped records. Daily aggregates never
/// acquire an invented timestamp or get spread evenly across a day.
struct UsageTimeline {
    var points: [DailyUsage] = []
    var minuteResolution = false
    var dailyOnly = Tokens()
    static func build(entries: [Entry], query: UsageQuery, now: Date, minuteResolution: Bool? = nil, calendar: Calendar = .current) -> Self {
        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        let bounds = query.timeBounds(now: now, calendar: calendar)
        let last = bounds.inclusive ? bounds.upper : bounds.upper.addingTimeInterval(-0.001)
        let minute = minuteResolution ?? (query.period == 0 || calendar.isDate(bounds.lower, inSameDayAs: last) || days.count == 1)
        var result = Self(minuteResolution: minute)
        var buckets: [Date: Tokens] = [:]
        for entry in entries {
            if minute && entry.bucket == "day" { result.dailyOnly = result.dailyOnly + entry.tokens; continue }
            let date = minute ? calendar.dateInterval(of: .minute, for: entry.date)!.start : calendar.startOfDay(for: entry.date)
            buckets[date] = (buckets[date] ?? Tokens()) + entry.tokens
        }
        var cumulative = Tokens()
        result.points = buckets.keys.sorted().map { date in
            cumulative = cumulative + buckets[date]!
            return DailyUsage(date: date, tokens: minute ? cumulative : buckets[date]!)
        }
        return result
    }
    /// Extend cumulative recorded totals across the viewport, without adding ledger events.
    func plotPoints(in domain: ClosedRange<Date>) -> [DailyUsage] {
        guard minuteResolution, !points.isEmpty else { return points }
        let known = points.filter { $0.date <= domain.upperBound }
        guard let last = known.last else { return [] }
        let initial = known.last(where: { $0.date <= domain.lowerBound })?.tokens ?? Tokens()
        var result = [DailyUsage(date: domain.lowerBound, tokens: initial)]
        result.append(contentsOf: known.filter { $0.date > domain.lowerBound })
        if last.date < domain.upperBound {
            result.append(DailyUsage(date: domain.upperBound, tokens: last.tokens))
        }
        return result
    }
    /// Today’s recorded usage for the compact popover. Empty when nothing was admitted today.
    static func compact(entries: [Entry], now: Date, calendar: Calendar = .current) -> CompactUsage {
        let query = UsageQuery(period: 0)
        let bounds = query.timeBounds(now: now, calendar: calendar)
        let selected = entries.filter { query.matches($0, catalog: [:], bounds: bounds) }
        let timeline = build(entries: selected, query: query, now: now, calendar: calendar)
        let tools = HistoryTool.allCases.compactMap { tool -> ToolUsageTimeline? in
            let subset = selected.filter { HistoryTool.recorded($0) == tool }
            guard !subset.isEmpty else { return nil }
            return ToolUsageTimeline(tool: tool, totals: subset.reduce(Tokens()) { $0 + $1.tokens }, timeline: build(entries: subset, query: query, now: now, calendar: calendar))
        }
        return CompactUsage(timeline: timeline, tools: tools)
    }
}

struct CompactUsage {
    var timeline = UsageTimeline()
    var tools: [ToolUsageTimeline] = []
    static func plotDomain(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let midnight = calendar.startOfDay(for: now)
        let firstMinute = midnight.addingTimeInterval(60)
        let start = now > firstMinute ? firstMinute : midnight
        return start...max(now, start.addingTimeInterval(0.001))
    }
}

/// A clock tick only checks validity. Aggregation is owned by the usage store,
/// outside SwiftUI body evaluation, and published only when its inputs change.
struct CompactUsageCache {
    private var revision: UInt64?
    private var calendar: Calendar?
    private var lastNow: Date?
    private var validUntil = Date.distantPast
    private(set) var rebuildCount = 0

    mutating func update(entries: [Entry], revision: UInt64, now: Date, calendar: Calendar = .current) -> CompactUsage? {
        defer { lastNow = now }
        guard self.revision != revision || self.calendar != calendar ||
                lastNow.map({ now < $0 }) != false || now >= validUntil else { return nil }
        self.revision = revision
        self.calendar = calendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        validUntil = entries.reduce(tomorrow) { deadline, entry in
            entry.date > now ? min(deadline, entry.date) : deadline
        }
        rebuildCount += 1
        return UsageTimeline.compact(entries: entries, now: now, calendar: calendar)
    }
}

/// Display-only expansion. The ledger remains the authority and is never edited.
/// A partial archive cannot inflate totals or move a daily aggregate to midnight.
enum TimelineDetail {
    private static func key(_ entry: Entry) -> String {
        [CostRecovery.groupKey(entry), entry.provider ?? "", entry.harness ?? "", entry.projectPath ?? "",
         entry.effort ?? "", entry.contextBand ?? "", UsageMetadata.aggregationKey(entry)].joined(separator: "|")
    }
    static func expand(_ source: [Entry], archive: RequestArchive) throws -> [Entry] {
        let daily = source.filter { $0.bucket == "day" }
        guard let first = daily.map(\.date).min(), let last = daily.map(\.date).max() else { return source }
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!
        let groups = Set(daily.map(key))
        var retained: [Entry] = []
        try archive.forEach(start: calendar.startOfDay(for: first), end: end.addingTimeInterval(-0.001)) { entry in
            if entry.bucket != "day", groups.contains(key(entry)) { retained.append(entry) }
        }
        return reconcile(source, details: retained)
    }
    /// Whole-group reconciliation is shared by broad timeline recovery and bounded comparison reads.
    static func reconcile(_ source: [Entry], details retained: [Entry]) -> [Entry] {
        let originals = Dictionary(grouping: source.filter { $0.bucket == "day" }, by: key)
        let details = Dictionary(grouping: retained.filter { $0.bucket != "day" && originals[key($0)] != nil }, by: key)
        var replacements: [String: [Entry]] = [:]
        for (group, old) in originals {
            guard let fresh = details[group], let basis = old.first,
                  old.allSatisfy({ $0.account == basis.account }),
                  old.allSatisfy({ $0.tokens.cacheWrite != nil }) == fresh.allSatisfy({ $0.tokens.cacheWrite != nil }),
                  old.reduce(0, { $0 + ($1.tokens.cacheWrite ?? 0) }) == fresh.reduce(0, { $0 + ($1.tokens.cacheWrite ?? 0) }),
                  old.reduce(Tokens(), { $0 + $1.tokens }) == fresh.reduce(Tokens(), { $0 + $1.tokens }),
                  old.reduce(0, { $0 + $1.eventCount }) == fresh.reduce(0, { $0 + $1.eventCount }) else { continue }
            replacements[group] = fresh.map { detail in
                var entry = basis
                entry.date = detail.date; entry.tokens = detail.tokens
                entry.bucket = nil; entry.sampleCount = detail.sampleCount
                entry.recordID = detail.recordID; entry.lastObserved = detail.lastObserved
                entry.firstObserved = detail.firstObserved; entry.costUsdTicks = detail.costUsdTicks
                return entry
            }
        }
        var emitted = Set<String>()
        return source.flatMap { entry -> [Entry] in
            guard entry.bucket == "day", let fresh = replacements[key(entry)] else { return [entry] }
            return emitted.insert(key(entry)).inserted ? fresh : []
        }
    }
}


/// Historical grouping uses recorded tool identity, never current activity or a model-name guess.
enum HistoryTool: String, CaseIterable, Identifiable {
    case codex = "Codex", claude = "Claude Code", grok = "Grok", other = "Other tools", unknown = "Unknown tool"
    var id: String { rawValue }
    static func recorded(_ entry: Entry) -> Self {
        guard let tool = entry.harness, !tool.isEmpty, tool != DimensionReport.unattributed else { return .unknown }
        if tool.lowercased().hasPrefix("codex") { return .codex }
        if tool == "Claude Code" { return .claude }
        if tool == "Grok" { return .grok }
        return .other
    }
}
struct ToolUsageTimeline: Identifiable {
    var tool: HistoryTool
    var totals: Tokens
    var timeline: UsageTimeline
    var id: String { tool.rawValue }
}
