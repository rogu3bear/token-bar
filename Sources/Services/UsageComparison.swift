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
            guard duration > 0, duration <= 600, first.reset == last.reset, first.reset > last.date,
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
    @ObservationIgnored private var desired: Key?
    @ObservationIgnored private var pending: (() -> Void)?
    // Serial queue-owned detail cache; quota-only updates never reopen the archive.
    @ObservationIgnored private var detailRevision: UInt64?
    @ObservationIgnored private var detailCount: Int?
    @ObservationIgnored private var details: [Entry] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "local.token-bar.usage-comparison", qos: .utility)
    func refresh(source: [Entry], revision: UInt64, quotaRevision: UInt64, state: LiveState, currentID: String?,
                 query: UsageQuery, effort: String, now: Date, archiveURL: URL? = nil, archiveCount: Int? = nil) {
        let key = Key(source: revision, quota: quotaRevision, account: currentID, query: query, effort: effort,
                      day: Calendar.current.startOfDay(for: now), archiveCount: archiveCount)
        guard key != desired else { return }
        if desired?.sameScope(as: key) != true { provider = nil; providerSnapshot = nil; metering = [:]; calculatedAt = nil }
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
                if !windows.isEmpty && (self.detailRevision != revision || self.detailCount != archiveCount) {
                    self.details = source
                    if source.contains(where: { $0.bucket == "day" }), let archiveURL,
                       let archive = try? RequestArchive(url: archiveURL, readOnly: true),
                       let recovered = try? TimelineDetail.expand(source, archive: archive) { self.details = recovered }
                    self.detailRevision = revision; self.detailCount = archiveCount
                }
                for window in windows {
                    metering[window.id] = MeteringComparison.build(history: state.quotaHistory ?? state.samples, windowID: window.id,
                                                                 accountID: currentID, source: self.details, query: query, effort: effort, now: now)
                }
                let completed = metering
                DispatchQueue.main.async {
                    if self.desired?.sameScope(as: key) == true {
                        self.provider = provider; self.providerSnapshot = snapshot; self.metering = completed; self.calculatedAt = now
                    }
                    self.busy = false
                    let next = self.pending; self.pending = nil; next?()
                }
            }
        }
        if busy { pending = operation } else { operation() }
    }
}
