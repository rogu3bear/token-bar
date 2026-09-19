import Foundation

extension QuotaReading {
    /// Remaining allowance percent. Used is spent 0...100; leftover is never negative.
    var remaining: Double { max(0, 100 - used) }
}

/// The Fable Quota menu-bar figures. Remaining is the tightest current limit that
/// applies to Fable; time left projects each of those limits at its averaged recent burn.
extension ClaudeQuotaSource {
    /// Remaining Fable budget, named by the limit that binds. Percentages are compared, never added.
    struct FableBudget: Equatable { var remaining: Double; var binding: String }
    /// When the first limit that applies to Fable would run out at the averaged recent pace.
    enum FablePace: Equatable {
        /// A limit has less than `paceMinimumSpan` of comparable readings.
        case learning
        /// No quota burn in the averaging window.
        case idle
        /// Every burning limit resets before it would run out.
        case resetsFirst
        case exhausted
        case left(TimeInterval, binding: String)
    }
    /// Readings arrive at uneven times while use comes in bursts, so pace is a
    /// time-weighted average over recent hours with a one-hour half-life, not the latest slope.
    static let paceLookback: TimeInterval = 4 * 3600
    static let paceHalfLife: TimeInterval = 3600
    static let paceMinimumSpan: TimeInterval = 1800

    static func fableLimits(_ quota: ToolQuotaState) -> [(binding: String, reading: QuotaReading?)] {
        [("5h", quota.readings.first { $0.window == "five_hour" }),
         ("week", quota.readings.first { $0.window == "seven_day" }),
         ("Fable week", quota.scoped.first { $0.window == fableWindow })]
    }
    static func fableBudget(_ quota: ToolQuotaState, now: Date) -> FableBudget? {
        guard !quota.guardFailed, let account = quota.guardAccountID else { return nil }
        var budget: FableBudget?
        for limit in fableLimits(quota) {
            // Any missing, stale, reset or other-account input leaves the budget unknown.
            guard let reading = limit.reading, reading.accountID == account, reading.used.isFinite, (0...100).contains(reading.used),
                  let reset = reading.reset, reset > now, reading.date <= now, now.timeIntervalSince(reading.date) < quota.horizon else { return nil }
            let leftover = reading.remaining
            if leftover < (budget?.remaining ?? .infinity) {
                budget = FableBudget(remaining: leftover, binding: limit.binding)
            }
        }
        return budget
    }
    static func fablePace(_ quota: ToolQuotaState, now: Date) -> FablePace? {
        guard let budget = fableBudget(quota, now: now) else { return nil }
        if budget.remaining == 0 { return .exhausted }
        var earliest: (date: Date, binding: String)?
        var burning = false
        for limit in fableLimits(quota) {
            guard let latest = limit.reading else { return nil }
            // One unlearned limit could run out first, so no partial projection is shown.
            guard let rate = averageBurn(latest, history: quota.paceHistory, now: now) else { return .learning }
            guard rate > 0 else { continue }
            burning = true
            let exhaustion = latest.date.addingTimeInterval(latest.remaining / rate)
            if let reset = latest.reset, exhaustion < reset && exhaustion < (earliest?.date ?? .distantFuture) { earliest = (exhaustion, limit.binding) }
        }
        if let earliest { return .left(max(0, earliest.date.timeIntervalSince(now)), binding: earliest.binding) }
        return burning ? .resetsFirst : .idle
    }
    /// Percent per second across the current reset period, weighted toward recent intervals;
    /// nil until comparable readings span `paceMinimumSpan`.
    static func averageBurn(_ latest: QuotaReading, history: [QuotaReading], now: Date) -> Double? {
        var series = history.filter { $0.id == latest.id && $0.date < latest.date && $0.date >= now.addingTimeInterval(-paceLookback) }
        series.sort { $0.date < $1.date }
        series.append(latest)
        // A decrease or a new reset starts a new period; earlier burn belonged to the old one.
        // Resets within a minute of each other are one period despite reporting jitter.
        var start = 0
        for index in series.indices.dropFirst()
        where series[index].used < series[index - 1].used || abs((series[index].reset ?? .distantPast).timeIntervalSince(series[index - 1].reset ?? .distantPast)) > 60 {
            start = index
        }
        let period = series[start...]
        guard let first = period.first, latest.date.timeIntervalSince(first.date) >= paceMinimumSpan else { return nil }
        var burned = 0.0, elapsed = 0.0
        for (earlier, later) in zip(period, period.dropFirst()) {
            let weight = pow(0.5, max(0, now.timeIntervalSince(later.date)) / paceHalfLife)
            burned += weight * (later.used - earlier.used)
            elapsed += weight * later.date.timeIntervalSince(earlier.date)
        }
        return elapsed > 0 ? burned / elapsed : nil
    }
}

extension ClaudeQuotaSource.FablePace {
    /// Short secondary menu-bar copy. ≈ marks a projection; times round down to five minutes.
    var menuText: String {
        switch self {
        case .learning: return "learning pace"
        case .idle: return "no recent use"
        case .resetsFirst: return "resets first"
        case .exhausted: return "0m left"
        case .left(let seconds, _):
            let minutes = Int((seconds / 300).rounded(.down)) * 5
            if minutes < 5 { return "<5m left" }
            let hours = minutes / 60, days = hours / 24
            if days > 0 { return hours % 24 == 0 ? "≈\(days)d left" : "≈\(days)d \(hours % 24)h left" }
            if hours > 0 { return minutes % 60 == 0 ? "≈\(hours)h left" : "≈\(hours)h \(minutes % 60)m left" }
            return "≈\(minutes)m left"
        }
    }
}
