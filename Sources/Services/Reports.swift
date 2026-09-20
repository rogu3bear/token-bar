import Foundation

struct UsageQuery: Equatable {
    var period = 0
    var start = Calendar.current.startOfDay(for: Date())
    var end = Date()
    var model = "All models"
    var account = "All accounts"
    var search = ""
    var harness = "All tools"
    func timeBounds(now: Date, calendar: Calendar = .current) -> (lower: Date, upper: Date, inclusive: Bool) {
        let today = calendar.startOfDay(for: now)
        let lower: Date
        var upper = now
        switch period {
        case 0: lower = today
        case 2: lower = calendar.date(byAdding: .day, value: -6, to: today)!
        case 3: lower = calendar.date(byAdding: .day, value: -29, to: today)!
        case 6: lower = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        case 5: lower = start
        case 4:
            lower = calendar.startOfDay(for: start)
            upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        default: lower = .distantPast
        }
        return (lower, upper, period != 4)
    }
    func includes(_ entry: Entry, catalog: [String: TaskInfo], now: Date) -> Bool {
        matches(entry, catalog: catalog, bounds: timeBounds(now: now))
    }
    func matches(_ entry: Entry, catalog: [String: TaskInfo], bounds: (lower: Date, upper: Date, inclusive: Bool)) -> Bool {
        guard entry.date >= bounds.lower && (bounds.inclusive ? entry.date <= bounds.upper : entry.date < bounds.upper) else { return false }
        guard harness == "All tools" || (entry.harness ?? "Unattributed") == harness else { return false }
        guard model == "All models" || entry.model == model else { return false }
        guard account == "All accounts" || (entry.account?.id ?? "Unattributed") == account else { return false }
        if search.isEmpty { return true }
        let task = catalog[entry.session]
        return [entry.session, entry.projectPath ?? "", task?.title ?? "", task?.directory ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
    }
}
struct UsageRow: Identifiable {
    var id: String
    var title: String
    var subtitle = ""
    var tokens = Tokens()
    var events = 0
    var last: Date = .distantPast
    var input: Int { tokens.input }
    var cached: Int { tokens.cached }
    var output: Int { tokens.output }
    var total: Int { tokens.total }
}
struct DailyUsage: Identifiable {
    var date: Date
    var tokens: Tokens
    var id: Date { date }
}
struct UsageReport {
    var entries: [Entry] = []
    var totals = Tokens()
    var eventCount = 0
    var days: [DailyUsage] = []
    var timeline = UsageTimeline()
    var toolTimelines: [ToolUsageTimeline] = []
    var models: [UsageRow] = []
    var accounts: [UsageRow] = []
    var tasks: [UsageRow] = []
    /// Grouped by working directory. Absent attribution becomes one explicit
    /// unattributed row rather than being dropped from the totals.
    var projects: [UsageRow] = []
    /// Grouped by the client program that ran the turn, not by provider.
    var harnesses: [UsageRow] = []
    /// Export the published report, without re-evaluating a newer query or clock.
    func csv() -> String {
        func quote(_ s: String) -> String { RequestExport.quote(s) }
        let iso = ISO8601DateFormatter()
        let rows = entries.map { e in
            [iso.string(from: e.date), e.session, e.model, String(e.tokens.input), String(e.tokens.cached), String(e.tokens.output), String(e.tokens.reasoning), String(e.tokens.total), e.account?.label ?? "Unattributed", UsageMetadata.accountAttribution(e.account), e.bucket ?? "event", String(e.eventCount)].map(quote).joined(separator: ",")
        }
        return (["timestamp,session,model,input,cached_input,output,reasoning_subset,total,account,attribution,granularity,event_count"] + rows).joined(separator: "\n")
    }
    static func build(entries source: [Entry], query: UsageQuery, catalog: [String: TaskInfo], now: Date = Date(), prefiltered: Bool = false) -> UsageReport {
        var result = UsageReport()
        var days: [Date: Tokens] = [:]
        var models: [String: UsageRow] = [:], accounts: [String: UsageRow] = [:], tasks: [String: UsageRow] = [:]
        var projects: [String: UsageRow] = [:], harnesses: [String: UsageRow] = [:]
        var harnessProviders: [String: Set<String>] = [:]
        func add(_ rows: inout [String: UsageRow], key: String, title: String, subtitle: String = "", entry: Entry) {
            var row = rows[key] ?? UsageRow(id: key, title: title, subtitle: subtitle)
            row.tokens = row.tokens + entry.tokens; row.events += entry.eventCount; row.last = max(row.last, entry.lastObserved ?? entry.date)
            rows[key] = row
        }
        let bounds = query.timeBounds(now: now)
        for entry in source where prefiltered || query.matches(entry, catalog: catalog, bounds: bounds) {
            result.entries.append(entry)
            result.eventCount += entry.eventCount
            result.totals = result.totals + entry.tokens
            let day = Calendar.current.startOfDay(for: entry.date)
            days[day] = (days[day] ?? Tokens()) + entry.tokens
            add(&models, key: entry.model, title: entry.model, entry: entry)
            add(&accounts, key: entry.account?.id ?? "Unattributed", title: entry.account.map { $0.label + " (inferred)" } ?? "Unattributed", entry: entry)
            add(&projects, key: Project.key(entry.projectPath) ?? "Unattributed",
                title: Project.name(entry.projectPath) ?? "Unattributed",
                subtitle: entry.projectPath ?? "No working directory recorded for these turns", entry: entry)
            let harness = entry.harness ?? "Unattributed"
            if let provider = entry.provider { harnessProviders[harness, default: []].insert(provider) }
            add(&harnesses, key: harness, title: harness, entry: entry)
            let info = catalog[entry.session]
            add(&tasks, key: entry.session, title: info?.title.isEmpty == false ? info!.title : entry.session,
                subtitle: info?.directory ?? entry.session, entry: entry)
        }
        result.timeline = UsageTimeline.build(entries: result.entries, query: query, now: now)
        let toolEntries = Dictionary(grouping: result.entries, by: HistoryTool.recorded)
        result.toolTimelines = HistoryTool.allCases.compactMap { tool in
            guard let entries = toolEntries[tool] else { return nil }
            return ToolUsageTimeline(tool: tool, totals: entries.reduce(Tokens()) { $0 + $1.tokens },
                timeline: UsageTimeline.build(entries: entries, query: query, now: now, minuteResolution: result.timeline.minuteResolution))
        }
        result.days = days.map { DailyUsage(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date }
        result.models = models.values.sorted { $0.total > $1.total }
        result.accounts = accounts.values.sorted { $0.total > $1.total }
        result.tasks = tasks.values.sorted { $0.total > $1.total }
        result.projects = projects.values.sorted { $0.total > $1.total }
        result.harnesses = harnesses.values.map { row in
            var row = row
            let providers = (harnessProviders[row.id] ?? []).sorted()
            row.subtitle = providers.isEmpty ? "Provider unavailable" : (providers.count == 1 ? "Provider: " : "Providers: ") + providers.joined(separator: ", ")
            return row
        }.sorted { $0.total > $1.total }
        return result
    }
}

struct LocalPace {
    var tokensPerSecond: Double
    var latest: Date?
    var tasks: Int
    var models: [String]
    static func measure(_ entries: [Entry], now: Date) -> LocalPace {
        let recent = entries.filter { $0.bucket == nil && $0.date > now.addingTimeInterval(-60) && $0.date <= now }
        return LocalPace(tokensPerSecond: Double(recent.reduce(0) { $0 + $1.tokens.output }) / 60,
            latest: recent.map(\.date).max(), tasks: Set(recent.map(\.session)).count, models: Array(Set(recent.map(\.model))).sorted())
    }
}


/// Equality includes metadata, not just totals, so enrichment invalidates a cached report.
struct ReportInputs: Equatable {
    var entries: [Entry]
    var catalog: [String: TaskInfo]
    var query: UsageQuery
    var effort: String
    var service: CostService
    var basis: CostPriceBasis
}
