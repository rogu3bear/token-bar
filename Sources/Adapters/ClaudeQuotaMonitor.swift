import Observation
import Foundation
import Combine
import CryptoKit

/// Passive, account-bound observations come from Claude Code's local usage cache,
/// which the installed Claude Code refreshes on request. The identity-free
/// status-line relay proves connection transport only. Missing or changed fields fail closed.
struct ToolQuotaState {
    var readings: [QuotaReading] = []
    var samples: [QuotaReading] = []
    var unavailable = "Awaiting fresh quota"
    var accountLabel: String?
    /// Age at which a reading stops counting as current; owned by the tool's refresh cadence.
    var horizon: TimeInterval = Runway.defaultHorizon
    var guardAccountID: String? = nil
    var guardAuthenticated = false
    var guardFailed = false
    /// Model-scoped windows such as a Fable weekly limit. They stay out of the
    /// prioritized allowance and Quota Guard; only the Fable figures read them.
    var scoped: [QuotaReading] = []
    /// Account-bound readings from recent hours for the averaged Fable pace; runway
    /// estimates and Quota Guard keep using `samples`.
    var paceHistory: [QuotaReading] = []
}
enum ClaudeQuotaSource {
    /// Claude Code rewrites its cache at session start, on its usage screen, and
    /// when Token Bar asks the installed CLI every `ClaudeUsageRefresh.interval`.
    /// A reading stays current for two refresh intervals and shows its read time.
    static let horizon: TimeInterval = 1800
    static let bucket = "claude", name = "Claude"
    static let windows: [(key: String, minutes: Int)] = [("five_hour", 300), ("seven_day", 10080)]
    static let fableWindow = scopedWindow("Fable")
    static func scopedWindow(_ model: String) -> String { "seven_day_model:" + model.lowercased() }
    static func accountID(_ uuid: String) -> String {
        "claude:" + SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func reading(accountID: String, window: String, minutes: Int, used: Double, reset: Date?, date: Date, now: Date) -> QuotaReading? {
        guard used.isFinite, (0...100).contains(used), let reset, reset > now,
              date <= now, now.timeIntervalSince(date) < horizon else { return nil }
        return QuotaReading(accountID: accountID, bucket: bucket, name: name, window: window, minutes: minutes, used: used, reset: reset, date: date)
    }
    static var relayHelp: String {
        """
        Claude Code refreshes its own usage cache at session start, on its usage screen, and when Token Bar asks the installed Claude Code for usage every 15 minutes. \
        Connect captures status-line data only; it cannot refresh or authenticate quota. By hand, add the relay in ~/.claude/settings.json:

        "statusLine": {"type": "command", "command": "'\(relayScriptPath)'"}

        Connect preserves an existing command through /bin/sh -c. \
        The relay stores Claude Code's status JSON privately (0600) under Token Bar's support directory; only rate_limits is read. \
        The status line has no account identity, so its readings are not used as account quota. Token Bar uses only the account-matched usage cache, edits only that statusLine key, keeps a backup, and never contacts Anthropic itself; the installed Claude Code makes its own usage request.
        """
    }
    /// The stable relay copy that settings reference; the bundle copy only seeds it.
    static var relayScriptPath: String {
        ClaudeStatuslineConnection.stableRelayURL(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).path
    }
}
struct ClaudeQuotaCache: Decodable {
    struct Account: Decodable { var accountUuid: String }
    struct Window: Decodable { var utilization: Double; var resets_at: String }
    /// One row of Claude Code's `limits[]`; only model-scoped weekly rows are read.
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { var display_name: String? }
            var model: Model?
        }
        var kind: String?
        var percent: Double?
        var resets_at: String?
        var scope: Scope?
    }
    struct Utilization: Decodable {
        var five_hour: Window?
        var seven_day: Window?
        var limits: [Limit]?
        private enum CodingKeys: String, CodingKey { case five_hour, seven_day, limits }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            five_hour = try container.decodeIfPresent(Window.self, forKey: .five_hour)
            seven_day = try container.decodeIfPresent(Window.self, forKey: .seven_day)
            // A malformed or future limits list drops only the model-scoped readings.
            limits = try? container.decodeIfPresent([Limit].self, forKey: .limits)
        }
    }
    struct Cache: Decodable { var accountUuid: String; var fetchedAtMs: Double; var utilization: Utilization }
    var oauthAccount: Account?
    var cachedUsageUtilization: Cache?

    var accountID: String? {
        guard let account = oauthAccount, !account.accountUuid.isEmpty else { return nil }
        return ClaudeQuotaSource.accountID(account.accountUuid)
    }
    /// The cache sample only when its own account is the signed-in account.
    private var bound: (id: String, date: Date, utilization: Utilization)? {
        guard let account = oauthAccount, let id = accountID,
              let cache = cachedUsageUtilization, cache.accountUuid == account.accountUuid,
              cache.fetchedAtMs.isFinite else { return nil }
        return (id, Date(timeIntervalSince1970: cache.fetchedAtMs / 1000), cache.utilization)
    }
    /// Claude Code adds sub-second noise to a reset that differs between fetches
    /// (…22:40:00.453, then …22:40:00.251), so resets keep whole seconds and one
    /// period's readings stay comparable.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: text)
        if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: text) }
        return date.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }
    func readings(now: Date) -> [QuotaReading] {
        guard let bound else { return [] }
        return ClaudeQuotaSource.windows.compactMap { key, minutes in
            guard let value = key == "five_hour" ? bound.utilization.five_hour : bound.utilization.seven_day else { return nil }
            return ClaudeQuotaSource.reading(accountID: bound.id, window: key, minutes: minutes, used: value.utilization,
                                             reset: Self.date(value.resets_at), date: bound.date, now: now)
        }
    }
    /// Model-scoped weekly rows, such as `weekly_scoped` with model display name "Fable".
    func scopedReadings(now: Date) -> [QuotaReading] {
        guard let bound else { return [] }
        return (bound.utilization.limits ?? []).compactMap { limit in
            guard limit.kind == "weekly_scoped", let model = limit.scope?.model?.display_name, !model.isEmpty,
                  let used = limit.percent else { return nil }
            return ClaudeQuotaSource.reading(accountID: bound.id, window: ClaudeQuotaSource.scopedWindow(model), minutes: 10080,
                                             used: used, reset: Self.date(limit.resets_at), date: bound.date, now: now)
        }
    }
}
/// What `claude-statusline-relay.sh` stores: the relay's own receipt time and the
/// status-line JSON Claude Code produced. Only `rate_limits` is read.
struct ClaudeStatuslineRelay: Decodable {
    struct Window: Decodable { var used_percentage: Double; var resets_at: Double }
    struct RateLimits: Decodable { var five_hour: Window?; var seven_day: Window? }
    struct Statusline: Decodable { var rate_limits: RateLimits? }
    var received_at_ms: Double
    var statusline: Statusline

    // This payload has no originating account identity. Receipt time and the
    // currently signed-in account cannot establish which account produced it.
    // Keep it as connection evidence only; never turn it into account quota.
}
@Observable final class ClaudeQuotaMonitor {
    static let unavailable = "Claude quota unavailable · no account-bound reading in the last 30 minutes"
    var quota = ToolQuotaState(unavailable: "Awaiting fresh Claude quota", horizon: ClaudeQuotaSource.horizon)
    /// True once the relay file has carried rate_limits, whatever its age.
    var relayObserved = false
    /// Why the last installed Claude Code usage refresh did not complete; nil after success.
    var refreshFailure: String?
    let cacheURL: URL
    let relayURL: URL
    /// Empty private working directory for the installed Claude Code usage request.
    /// Nil in previews and fixtures, which never start a provider tool.
    let refreshDirectory: URL?
    private let executable: () -> String?
    private let queue = DispatchQueue(label: "local.token-bar.claude-quota", qos: .utility)
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var lastRefreshAttempt: Date?
    init(cacheURL: URL, relayURL: URL, refreshDirectory: URL? = nil,
         executable: @escaping () -> String? = { ClaudeUsageRefresh.executable() }) {
        self.cacheURL = cacheURL; self.relayURL = relayURL
        self.refreshDirectory = refreshDirectory; self.executable = executable
    }
    static func readings(cacheURL: URL, relayURL: URL, now: Date) -> [QuotaReading] {
        let cache = try? JSONDecoder().decode(ClaudeQuotaCache.self, from: Data(contentsOf: cacheURL))
        // Identity-free relay observations are rejected even after restart or
        // when the current cache is stale. Only the cache binds its own sample
        // to an account and checks that account against the active sign-in.
        return cache?.readings(now: now) ?? []
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        let started = Date()
        let directory = ClaudeUsageRefresh.isDue(lastAttempt: lastRefreshAttempt, now: started) ? refreshDirectory : nil
        if directory != nil { lastRefreshAttempt = started }
        queue.async {
            // The reply only prompts Claude Code to rewrite the cache read below;
            // nil means no attempt, .some(nil) a completed request.
            let outcome: String?? = directory.map { directory in
                do {
                    guard let executable = self.executable() else { throw ClaudeUsageRefresh.failure("Claude Code is not installed") }
                    try ClaudeUsageRefresh.run(executable: executable, directory: directory, environment: ProcessInfo.processInfo.environment)
                    return nil
                } catch { return error.localizedDescription }
            }
            let now = Date()
            let cache = try? JSONDecoder().decode(ClaudeQuotaCache.self, from: Data(contentsOf: self.cacheURL))
            let readings = cache?.readings(now: now) ?? [], scoped = cache?.scopedReadings(now: now) ?? []
            // Pace history follows the signed-in account, so a stale cache does not erase it.
            let account = cache?.accountID
            let relayObserved = (try? JSONDecoder().decode(ClaudeStatuslineRelay.self, from: Data(contentsOf: self.relayURL)))?.statusline.rate_limits != nil
            DispatchQueue.main.async {
                if let outcome { self.refreshFailure = outcome }
                self.relayObserved = relayObserved
                let id = readings.first?.accountID
                var samples = self.quota.samples.filter { $0.accountID == id && $0.date >= now.addingTimeInterval(-ClaudeQuotaSource.horizon) }
                for reading in readings where !samples.contains(where: { $0.id == reading.id && $0.date == reading.date }) { samples.append(reading) }
                var history = self.quota.paceHistory.filter { $0.accountID == account && $0.date >= now.addingTimeInterval(-ClaudeQuotaSource.paceLookback) }
                for reading in readings + scoped where !history.contains(where: { $0.id == reading.id && $0.date == reading.date }) { history.append(reading) }
                let unavailable = self.refreshFailure.map { Self.unavailable + " · Claude Code usage refresh failed: " + $0 } ?? Self.unavailable
                self.quota = ToolQuotaState(readings: readings, samples: samples, unavailable: unavailable, horizon: ClaudeQuotaSource.horizon,
                    guardAccountID: id, guardAuthenticated: id != nil, scoped: scoped, paceHistory: history)
                self.busy = false
            }
        }
    }
}
