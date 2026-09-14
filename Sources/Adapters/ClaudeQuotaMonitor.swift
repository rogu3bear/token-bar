import Observation
import Foundation
import Combine
import CryptoKit

/// Passive, account-bound observations come from Claude Code's local usage cache.
/// The identity-free status-line relay proves connection transport only.
/// Missing or changed fields fail closed.
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
}
enum ClaudeQuotaSource {
    /// Claude Code refreshes its cache only on demand (session start, its usage
    /// screen) and re-runs its status line after each turn. Remaining allowance
    /// cannot fall while Claude is unused, so a reading stays current for one
    /// runway sample window and shows its read time.
    static let horizon: TimeInterval = 1800
    static let bucket = "claude", name = "Claude"
    static let windows: [(key: String, minutes: Int)] = [("five_hour", 300), ("seven_day", 10080)]
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
        Claude Code refreshes its own usage cache only at session start and on its usage screen, so Token Bar can read it just then. \
        Connect captures status-line data only; it cannot refresh or authenticate quota. By hand, add the relay in ~/.claude/settings.json:

        "statusLine": {"type": "command", "command": "'\(relayScriptPath)'"}

        Connect preserves an existing command through /bin/sh -c. \
        The relay stores Claude Code's status JSON privately (0600) under Token Bar's support directory; only rate_limits is read. \
        The status line has no account identity, so its readings are not used as account quota. Token Bar uses only the account-matched usage cache, edits only that statusLine key, keeps a backup, and never contacts Anthropic.
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
    struct Utilization: Decodable { var five_hour: Window?; var seven_day: Window? }
    struct Cache: Decodable { var accountUuid: String; var fetchedAtMs: Double; var utilization: Utilization }
    var oauthAccount: Account?
    var cachedUsageUtilization: Cache?

    var accountID: String? {
        guard let account = oauthAccount, !account.accountUuid.isEmpty else { return nil }
        return ClaudeQuotaSource.accountID(account.accountUuid)
    }
    func readings(now: Date) -> [QuotaReading] {
        guard let account = oauthAccount, let id = accountID,
              let cache = cachedUsageUtilization, cache.accountUuid == account.accountUuid,
              cache.fetchedAtMs.isFinite else { return [] }
        let date = Date(timeIntervalSince1970: cache.fetchedAtMs / 1000)
        let parser = ISO8601DateFormatter()
        return ClaudeQuotaSource.windows.compactMap { key, minutes in
            guard let value = key == "five_hour" ? cache.utilization.five_hour : cache.utilization.seven_day else { return nil }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var reset = parser.date(from: value.resets_at)
            if reset == nil { parser.formatOptions = [.withInternetDateTime]; reset = parser.date(from: value.resets_at) }
            return ClaudeQuotaSource.reading(accountID: id, window: key, minutes: minutes, used: value.utilization, reset: reset, date: date, now: now)
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
    let cacheURL: URL
    let relayURL: URL
    private let queue = DispatchQueue(label: "local.token-bar.claude-quota", qos: .utility)
    @ObservationIgnored private var busy = false
    init(cacheURL: URL, relayURL: URL) { self.cacheURL = cacheURL; self.relayURL = relayURL }
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
        queue.async {
            let now = Date()
            let readings = Self.readings(cacheURL: self.cacheURL, relayURL: self.relayURL, now: now)
            let relayObserved = (try? JSONDecoder().decode(ClaudeStatuslineRelay.self, from: Data(contentsOf: self.relayURL)))?.statusline.rate_limits != nil
            DispatchQueue.main.async {
                self.relayObserved = relayObserved
                let id = readings.first?.accountID
                var samples = self.quota.samples.filter { $0.accountID == id && $0.date >= now.addingTimeInterval(-ClaudeQuotaSource.horizon) }
                for reading in readings where !samples.contains(where: { $0.id == reading.id && $0.date == reading.date }) { samples.append(reading) }
                self.quota = ToolQuotaState(readings: readings, samples: samples, unavailable: Self.unavailable, horizon: ClaudeQuotaSource.horizon,
                    guardAccountID: id, guardAuthenticated: id != nil)
                self.busy = false
            }
        }
    }
}
