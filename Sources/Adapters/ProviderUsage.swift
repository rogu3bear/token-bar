import Foundation

struct ProviderUsage: Codable {
    var accountID: String
    var observed: Date
    var lifetimeTokens: Int?
    var days: [String: Int]
    var source = "Installed app-server · account/usage/read"
    static func dayDate(_ day: String) -> Date? {
        let parser = ISO8601DateFormatter()
        guard day.count == 10, let date = parser.date(from: day + "T00:00:00Z"), UsageMetadata.day(date) == day else { return nil }
        return date
    }
    static func decode(_ data: [String: Any], accountID: String, afterID: String, now: Date = Date()) throws -> Self {
        guard accountID == afterID else { throw RequestArchive.failure("Account changed during usage read; comparison rejected") }
        var days: [String: Int] = [:]
        for bucket in data["dailyUsageBuckets"] as? [[String: Any]] ?? [] {
            guard let day = bucket["startDate"] as? String, dayDate(day) != nil,
                  let tokens = bucket["tokens"] as? Int, tokens >= 0, days[day] == nil else {
                throw RequestArchive.failure("Provider usage contains an invalid or duplicate day; reading rejected")
            }
            days[day] = tokens
        }
        let lifetime = (data["summary"] as? [String: Any])?["lifetimeTokens"] as? Int
        guard lifetime.map({ $0 >= 0 }) ?? true else { throw RequestArchive.failure("Invalid provider lifetime total") }
        return Self(accountID: accountID, observed: now, lifetimeTokens: lifetime, days: days)
    }
}
struct ProviderComparison {
    var selectedDays = 0
    var reportedDays = 0
    var providerTokens = 0
    var localInferredTokens = 0
    var localUnattributedTokens = 0
    var unknownDateTokens = 0
    var reason: String?
    var firstDay: String?
    var lastDay: String?
    var delta: Int? { reportedDays > 0 ? localInferredTokens - providerTokens : nil }
    static func build(snapshot: ProviderUsage, currentID: String?, source: [Entry], query: UsageQuery, effort: String, now: Date = Date()) -> Self {
        var result = Self()
        guard snapshot.accountID == currentID else { result.reason = "Refresh the active account before comparing."; return result }
        guard query.harness == "All tools", query.model == "All models", effort == "All levels", query.search.isEmpty,
              query.account == "All accounts" || query.account == snapshot.accountID else {
            result.reason = "Provider totals cover the whole active account. Clear tool, model, effort, task and other-account filters to compare."; return result
        }
        let bounds = query.timeBounds(now: now)
        let firstLocal = source.compactMap { $0.pricingDay.flatMap(ProviderUsage.dayDate) }.min()
        let firstProvider = snapshot.days.keys.compactMap(ProviderUsage.dayDate).min()
        guard let first = [firstLocal, firstProvider].compactMap({ $0 }).min() else { result.reason = "No dated usage is available."; return result }
        var day = max(first, ProviderUsage.dayDate(UsageMetadata.day(bounds.lower)) ?? first)
        let end = min(bounds.upper, now, snapshot.observed)
        var selected = Set<String>()
        while day.addingTimeInterval(86400) <= end {
            if day >= bounds.lower { selected.insert(UsageMetadata.day(day)) }
            day = day.addingTimeInterval(86400)
        }
        result.selectedDays = selected.count
        let reported = selected.intersection(snapshot.days.keys)
        result.reportedDays = reported.count; result.firstDay = reported.min(); result.lastDay = reported.max()
        result.providerTokens = reported.reduce(0) { $0 + (snapshot.days[$1] ?? 0) }
        for entry in source {
            guard let date = entry.pricingDay else {
                if query.includes(entry, catalog: [:], now: now) { result.unknownDateTokens += entry.tokens.total }; continue
            }
            guard reported.contains(date) else { continue }
            if entry.account?.id == snapshot.accountID { result.localInferredTokens += entry.tokens.total }
            else if entry.account == nil { result.localUnattributedTokens += entry.tokens.total }
        }
        if reported.isEmpty { result.reason = "No complete UTC day with a provider bucket lies inside this period. Partial boundary days are excluded." }
        return result
    }
}
