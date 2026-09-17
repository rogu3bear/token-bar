import Foundation
import Observation

struct MeteringInterval: Identifiable {
    var start: Date
    var end: Date
    var usedPoints: Double
    var input = 0
    var output = 0
    var cached = 0
    var missingFields = 0
    var unattributed = 0
    var unattributedRecords = 0
    var models = Set<String>()
    var coarseTiming = false
    var id: Date { end }
    var tokensPerPoint: Double? {
        usedPoints > 0 && input + output > 0 && missingFields == 0 && unattributedRecords == 0 && !coarseTiming
            ? Double(input + output) / usedPoints : nil
    }
}
struct MeteringComparison {
    var intervals: [MeteringInterval] = []
    var excludedIntervals = 0
    var coarseRecords = 0
    var reason: String?
    static func build(history: [QuotaReading], windowID: String, accountID: String?, source: [Entry],
                      query: UsageQuery, effort: String, now: Date) -> Self {
        var result = Self()
        guard let accountID else { result.reason = "No active Codex account is available."; return result }
        guard query.model == "All models", query.harness == "All tools", query.search.isEmpty, effort == "All levels",
              query.account == "All accounts" || query.account == accountID else {
            result.reason = "Clear model, tool, task, reasoning and other-account filters. Allowance is account-level."; return result
        }
        let bounds = query.timeBounds(now: now)
        let readings = history.filter { $0.id == windowID && $0.accountID == accountID && $0.date >= bounds.lower && $0.date <= min(bounds.upper, now) }
            .sorted { $0.date < $1.date }
        guard readings.count >= 2 else { result.reason = "At least two retained observations inside this period are needed."; return result }
        let entries = source.filter { entry in
            guard entry.account == nil || entry.account?.id == accountID else { return false }
            if entry.bucket == "day", let day = Calendar.current.dateInterval(of: .day, for: entry.date) {
                return day.end > bounds.lower && day.start <= min(bounds.upper, now)
            }
            return entry.date >= bounds.lower && entry.date <= min(bounds.upper, now)
        }
        // Known foreign-tool/provider work is outside Codex allowance. Unknown
        // origin remains ambiguous; it must not silently disappear from coverage.
        let plausible = entries.filter {
            ($0.provider == nil || $0.provider == "openai") &&
                (HistoryTool.recorded($0) == .codex || HistoryTool.recorded($0) == .unknown)
        }
        let coarseDays = Set(plausible.filter { $0.bucket == "day" }.map { Calendar.current.startOfDay(for: $0.date) })
        result.coarseRecords = plausible.filter { $0.bucket == "day" }.reduce(0) { $0 + $1.eventCount }
        let precise = plausible.filter { $0.bucket != "day" }.sorted { $0.date < $1.date }
        var cursor = 0
        for index in 1..<readings.count {
            let first = readings[index - 1], last = readings[index]
            let duration = last.date.timeIntervalSince(first.date)
            guard duration > 0, duration <= 600, first.reset == last.reset, first.reset.map({ $0 > last.date }) == true,
                  first.minutes == last.minutes, first.name == last.name,
                  first.used.isFinite, last.used.isFinite, (0...100).contains(first.used), (0...100).contains(last.used), last.used >= first.used else {
                result.excludedIntervals += 1; continue
            }
            var interval = MeteringInterval(start: first.date, end: last.date, usedPoints: last.used - first.used)
            interval.coarseTiming = coarseDays.contains(Calendar.current.startOfDay(for: first.date)) ||
                coarseDays.contains(Calendar.current.startOfDay(for: last.date))
            while cursor < precise.count && precise[cursor].date <= first.date { cursor += 1 }
            while cursor < precise.count && precise[cursor].date <= last.date {
                let entry = precise[cursor]; cursor += 1
                if entry.account == nil { interval.unattributed += entry.tokens.total; interval.unattributedRecords += entry.eventCount; continue }
                // A cumulative multi-request delta has no precise interval for its work.
                guard entry.provider == "openai", HistoryTool.recorded(entry) == .codex,
                      entry.isSingleRequest, entry.hasField("input_tokens"), entry.hasField("output_tokens"),
                      entry.hasField("cached_input_tokens") else { interval.missingFields += entry.eventCount; continue }
                interval.input += entry.tokens.input; interval.output += entry.tokens.output; interval.cached += entry.tokens.cached
                interval.models.insert(entry.model)
            }
            result.intervals.append(interval)
        }
        if result.intervals.isEmpty { result.reason = "No comparable intervals remain after resets, decreases and gaps are excluded." }
        return result
    }
}

/// Queue-owned cache of reconciled coarse groups, bounded to the selected intervals.
/// Admitted archive rows are immutable: a fully reconciled group remains valid until
/// its ledger group changes. Incomplete groups are reconsidered when archive count changes.
final class ComparisonDetails {
    typealias Reader = (String) throws -> [Entry]
    private struct Cached {
        var original: [Entry]
        var recovered: [Entry]
        var archiveCount: Int?
        var complete: Bool
    }
    private var cache: [String: Cached] = [:]
    private var archiveURL: URL?
    private let open: (URL) throws -> Reader
    init(open: @escaping (URL) throws -> Reader = { url in
        let archive = try RequestArchive(url: url, readOnly: true)
        return { group in
            var entries: [Entry] = []
            try archive.forEach(group: group) { entries.append($0) }
            return entries
        }
    }) { self.open = open }
    func recover(_ source: [Entry], intervals: [MeteringInterval], account: String?,
                 url: URL?, archiveCount: Int?) throws -> [Entry] {
        if archiveURL != url { cache = [:]; archiveURL = url }
        var ranges: [(start: Date, end: Date)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, interval.start <= last.end {
                ranges[ranges.count - 1].end = max(last.end, interval.end)
            } else { ranges.append((interval.start, interval.end)) }
        }
        guard !ranges.isEmpty else { cache = [:]; return [] }
        // First interval whose end reaches this timestamp: O(log intervals),
        // including for a coarse day whose whole group is needed to reconcile.
        func firstEnding(at date: Date) -> Int {
            var lower = 0, upper = ranges.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if ranges[middle].end < date { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        let needed = source.filter { entry in
            guard entry.account == nil || entry.account?.id == account,
                  entry.provider == nil || entry.provider == "openai",
                  HistoryTool.recorded(entry) == .codex || HistoryTool.recorded(entry) == .unknown else { return false }
            if entry.bucket == "day", let day = Calendar.current.dateInterval(of: .day, for: entry.date) {
                let index = firstEnding(at: day.start)
                return index < ranges.count && ranges[index].start < day.end
            }
            let index = firstEnding(at: entry.date)
            return index < ranges.count && ranges[index].start < entry.date
        }
        let groups = Dictionary(grouping: needed.filter { $0.bucket == "day" }, by: CostRecovery.groupKey)
        cache = cache.filter { groups[$0.key] != nil }
        guard let url, !groups.isEmpty else { return needed }
        var reader: Reader?
        var result = needed.filter { $0.bucket != "day" }
        for (key, original) in groups.sorted(by: { $0.key < $1.key }) {
            if let saved = cache[key], saved.original == original,
               saved.complete || saved.archiveCount == archiveCount {
                result += saved.recovered; continue
            }
            if reader == nil { reader = try open(url) }
            let recovered = TimelineDetail.reconcile(original, details: try reader!(key))
            cache[key] = Cached(original: original, recovered: recovered, archiveCount: archiveCount,
                                complete: recovered.allSatisfy { $0.bucket != "day" })
            result += recovered
        }
        return result
    }
}

/// Process-owned background results. Reopening a page only consumes this cache.
@Observable final class UsageComparisonStore {
    struct Key: Equatable {
        var source: UInt64
        var quota: UInt64
        var account: String?
        var query: UsageQuery
        var effort: String
        var day: Date
        var archiveCount: Int?
        func sameScope(as other: Self) -> Bool {
            account == other.account && query == other.query && effort == other.effort && day == other.day
        }
    }
    private(set) var provider: ProviderComparison?
    private(set) var providerSnapshot: ProviderUsage?
    private(set) var metering: [String: MeteringComparison] = [:]
    private(set) var busy = false
    private(set) var calculatedAt: Date?
    private(set) var builds = 0
    private(set) var recoveryError: String?
    @ObservationIgnored private var desired: Key?
    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private let details: ComparisonDetails
    init(details: ComparisonDetails = ComparisonDetails()) { self.details = details }
    @ObservationIgnored private let queue = DispatchQueue(label: "local.token-bar.usage-comparison", qos: .utility)
    func refresh(source: [Entry], revision: UInt64, quotaRevision: UInt64, state: LiveState, currentID: String?,
                 query: UsageQuery, effort: String, now: Date, archiveURL: URL? = nil, archiveCount: Int? = nil) {
        let key = Key(source: revision, quota: quotaRevision, account: currentID, query: query, effort: effort,
                      day: Calendar.current.startOfDay(for: now), archiveCount: archiveCount)
        guard key != desired || (recoveryError != nil && !busy && now >= (retryAfter ?? .distantPast)) else { return }
        if desired?.sameScope(as: key) != true { provider = nil; providerSnapshot = nil; metering = [:]; calculatedAt = nil; recoveryError = nil; retryAfter = nil }
        desired = key
        let operation = { [weak self] in
            guard let self else { return }
            self.busy = true; self.builds += 1
            self.queue.async {
                let snapshot = currentID.flatMap { state.usage?[$0] }
                let provider = snapshot.map {
                    ProviderComparison.build(snapshot: $0, currentID: currentID, source: source, query: query, effort: effort, now: now)
                }
                var metering: [String: MeteringComparison] = [:]
                let windows = currentID.flatMap { state.accounts[$0]?.quotas } ?? []
                let history = state.quotaHistory ?? state.samples
                let scopes = windows.map {
                    MeteringComparison.build(history: history, windowID: $0.id, accountID: currentID,
                                             source: [], query: query, effort: effort, now: now)
                }
                var failure: String?
                var recovered: [Entry] = []
                do {
                    recovered = try self.details.recover(source, intervals: scopes.flatMap(\.intervals),
                        account: currentID, url: archiveURL, archiveCount: archiveCount)
                } catch {
                    failure = "Archived timing unavailable: " + error.localizedDescription
                        + ". Completed comparisons are retained. Unchanged data retries at most once every 30 seconds."
                    recovered = source
                }
                for window in windows {
                    metering[window.id] = MeteringComparison.build(history: history, windowID: window.id,
                        accountID: currentID, source: recovered, query: query, effort: effort, now: now)
                }
                let recoveryFailure = failure
                let completed = metering
                DispatchQueue.main.async {
                    if self.desired?.sameScope(as: key) == true {
                        self.provider = provider; self.providerSnapshot = snapshot
                        self.recoveryError = recoveryFailure
                        self.retryAfter = recoveryFailure == nil ? nil : now.addingTimeInterval(30)
                        if recoveryFailure == nil || self.calculatedAt == nil {
                            self.metering = completed; self.calculatedAt = now
                        }
                    }
                    self.busy = false
                    let next = self.pending; self.pending = nil; next?()
                }
            }
        }
        if busy { pending = operation } else { operation() }
    }
}
