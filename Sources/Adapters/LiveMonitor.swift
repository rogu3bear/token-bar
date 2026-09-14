import Observation
import Foundation
import Combine
import Darwin

struct QuotaReading: Codable, Identifiable, Equatable {
    var accountID: String
    var bucket: String
    var name: String
    var window: String
    var minutes: Int
    var used: Double
    var reset: Date
    var date: Date
    var id: String { accountID + "|" + bucket + "|" + window }
}
struct LiveAccount: Codable, Identifiable {
    var id: String
    var email: String
    var plan: String
    var observed: Date
    var quotas: [QuotaReading]
}
struct LivePlan: Codable, Identifiable {
    var id: String
    var accountID: String
    var email: String
    var plan: String
    var firstSeen: Date
    var lastSeen: Date
}
struct LiveState: Codable {
    var accounts: [String: LiveAccount] = [:]
    var samples: [QuotaReading] = []
    var plans: [LivePlan] = []
    // Optional for backward-compatible decoding of existing observation files.
    var quotaHistory: [QuotaReading]?
    var usage: [String: ProviderUsage]?
}

enum QuotaHistory {
    static func recording(_ readings: [QuotaReading], in existing: [QuotaReading], now: Date) -> [QuotaReading] {
        var history = existing.filter { $0.date >= now.addingTimeInterval(-90 * 86400) && $0.date <= now }
            .sorted { $0.date < $1.date }
        for reading in readings.sorted(by: { $0.date < $1.date }) where reading.date <= now {
            if let last = history.last(where: { $0.id == reading.id }) {
                guard reading.date > last.date else { continue }
                guard reading.reset != last.reset || reading.used < last.used || reading.date.timeIntervalSince(last.date) >= 300 else { continue }
            }
            history.append(reading)
        }
        return history
    }
}
struct Runway {
    var remaining: Double
    var percentPerHour: Double?
    var exhaustion: Date?
    var message: String
    /// `horizon` is how old a reading may be and still count as current. Codex polls
    /// every 30 seconds; a tool that refreshes its own cache less often passes its cadence.
    static let defaultHorizon: TimeInterval = 120
    /// A reading older than the shared two-minute horizon says so beside its read time.
    static func ageLabel(_ reading: QuotaReading, now: Date) -> String {
        let seconds = now.timeIntervalSince(reading.date)
        guard seconds >= defaultHorizon else { return "" }
        return " · \(Int(seconds / 60)) min ago"
    }
    static func estimate(_ latest: QuotaReading, samples: [QuotaReading], now: Date, horizon: TimeInterval = defaultHorizon) -> Runway {
        let remaining = max(0, 100 - latest.used)
        guard now.timeIntervalSince(latest.date) < horizon, latest.reset > now else {
            return Runway(remaining: remaining, message: "Waiting for a fresh quota reading")
        }
        if remaining == 0 { return Runway(remaining: 0, exhaustion: now, message: "Quota exhausted") }
        let relevant = samples.filter { $0.id == latest.id && $0.reset == latest.reset && $0.date >= now.addingTimeInterval(-1800) && $0.date <= latest.date }.sorted { $0.date < $1.date }
        // A quota decrease can be a manual reset or adjustment. Discard the old slope.
        var boundary = 0
        for index in relevant.indices.dropFirst() where relevant[index].used < relevant[index - 1].used { boundary = index }
        let segment = Array(relevant.dropFirst(boundary))
        guard let first = segment.first, latest.date.timeIntervalSince(first.date) >= 120 else {
            return Runway(remaining: remaining, message: "Learning quota burn · needs 2+ minutes")
        }
        let spent = latest.used - first.used
        guard spent > 0 else { return Runway(remaining: remaining, percentPerHour: 0, message: "No quota drop observed in this interval") }
        let perSecond = spent / latest.date.timeIntervalSince(first.date)
        let exhaustion = latest.date.addingTimeInterval(remaining / perSecond)
        if exhaustion >= latest.reset {
            return Runway(remaining: remaining, percentPerHour: perSecond * 3600, message: "Resets before projected exhaustion")
        }
        return Runway(remaining: remaining, percentPerHour: perSecond * 3600, exhaustion: exhaustion, message: "Estimate from recent quota burn")
    }
}
@Observable final class LiveMonitor {
    var state = LiveState()
    var currentID: String?
    var error: String?
    var busy = false
    var usageBusy = false
    var usageError: String?
    let home: URL
    let stateURL: URL
    let queue = DispatchQueue(label: "local.codex-token-bar.provider", qos: .utility, autoreleaseFrequency: .workItem)
    @ObservationIgnored private var loadError: String?
    @ObservationIgnored private let store: LiveStateStore
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var launchedAccount: String?
    init(home: URL, stateURL: URL) {
        self.home = home; self.stateURL = stateURL
        store = LiveStateStore(legacyURL: stateURL)
        do { state = try store.load() }
        catch { loadError = "Saved account observations could not be read; the stored data has been preserved. " + error.localizedDescription }
    }
    func stop() { process?.terminate() }
    func refresh() {
        if let loadError { error = loadError; return }
        guard !busy && !usageBusy else { return }
        busy = true
        let previous = state
        queue.async {
            do {
                let reading = try self.readCurrent()
                var next = previous
                next.accounts[reading.id] = reading
                next.quotaHistory = QuotaHistory.recording(reading.quotas, in: previous.quotaHistory ?? previous.samples, now: reading.observed)
                next.samples.append(contentsOf: reading.quotas)
                next.samples.removeAll { $0.date < Date().addingTimeInterval(-3600) }
                if let index = next.plans.lastIndex(where: { $0.accountID == reading.id }), next.plans[index].plan == reading.plan {
                    next.plans[index].lastSeen = reading.observed
                } else {
                    next.plans.append(LivePlan(id: UUID().uuidString, accountID: reading.id, email: reading.email, plan: reading.plan, firstSeen: reading.observed, lastSeen: reading.observed))
                }
                try self.store.save(next)
                DispatchQueue.main.async { self.state = next; self.currentID = reading.id; self.error = nil; self.busy = false }
            } catch {
                self.process?.terminate(); self.process = nil
                let message = error.localizedDescription
                DispatchQueue.main.async { self.error = message; self.currentID = nil; self.busy = false }
            }
        }
    }
    func refreshUsage() {
        if let loadError { usageError = loadError; return }
        guard !busy && !usageBusy else { return }
        usageBusy = true
        let previous = state
        queue.async {
            do {
                let before = try self.readCurrent()
                let data = try self.call("account/usage/read", [:])
                let after = try self.readCurrent()
                let usage = try ProviderUsage.decode(data, accountID: before.id, afterID: after.id)
                // The shared busy flags serialize quota and usage refreshes.
                // Persist off-main before publishing the new snapshot.
                var next = previous
                next.usage = next.usage ?? [:]; next.usage?[usage.accountID] = usage
                try self.store.save(next)
                DispatchQueue.main.async {
                    self.state = next; self.currentID = after.id; self.usageError = nil
                    self.usageBusy = false
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.usageError = message; self.currentID = nil; self.usageBusy = false }
            }
        }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexTokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func send(_ object: [String: Any]) throws {
        guard let input else { throw failure("Codex account connection is unavailable") }
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    private func call(_ method: String, _ params: Any) throws -> [String: Any] {
        sequence += 1
        let request = sequence
        try send(["id": request, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any], response["id"] as? Int == request else { continue }
                if let error = response["error"] as? [String: Any] { throw failure(error["message"] as? String ?? "Codex account read failed") }
                return response["result"] as? [String: Any] ?? [:]
            }
            guard let output else { throw failure("Codex account connection closed") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&descriptor, 1, 250)
            if status > 0 {
                let data = output.availableData
                if data.isEmpty { throw failure("Codex account connection closed") }
                buffer.append(data)
            }
        }
        throw failure("Codex account read timed out; existing readings are retained")
    }
    private func readCurrent() throws -> LiveAccount {
        guard let before = Account.read(home: home) else { throw failure("Sign in to Codex to read account quota") }
        if process?.isRunning != true || launchedAccount != before.id {
            process?.terminate()
            let executable = CodexInstallation.executable()
            guard let executable else { throw failure("The installed Codex app-server could not be found") }
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["app-server", "--stdio"]
            var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = home.path
            child.environment = environment
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            try child.run()
            process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffer = Data(); launchedAccount = before.id
            _ = try call("initialize", ["clientInfo": ["name": "codex_token_bar", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        }
        let identity = try call("account/read", ["refreshToken": false])
        let limits = try call("account/rateLimits/read", NSNull())
        guard let after = Account.read(home: home), before.id == after.id,
              let accountID = limits["accountId"] as? String, accountID == before.id,
              let account = identity["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw failure("Account identity changed or quota was not account-bound; reading rejected")
        }
        let now = Date()
        var quotas: [QuotaReading] = []
        let groups = limits["rateLimitsByLimitId"] as? [String: [String: Any]] ?? ["codex": limits["rateLimits"] as? [String: Any] ?? [:]]
        for (key, group) in groups {
            for window in ["primary", "secondary"] {
                guard let value = group[window] as? [String: Any], let used = value["usedPercent"] as? Double,
                      let reset = value["resetsAt"] as? Double, reset.isFinite, reset > now.timeIntervalSince1970,
                      used.isFinite, (0...100).contains(used),
                      let minutes = value["windowDurationMins"] as? Int, minutes > 0 else { continue }
                quotas.append(QuotaReading(accountID: accountID, bucket: key, name: group["limitName"] as? String ?? key,
                    window: window, minutes: minutes, used: used, reset: Date(timeIntervalSince1970: reset), date: now))
            }
        }
        return LiveAccount(id: accountID, email: account["email"] as? String ?? before.label,
            plan: account["planType"] as? String ?? "unknown", observed: now, quotas: quotas.sorted { $0.bucket < $1.bucket })
    }
}

extension Runway {
    static func priority(_ quotas: [QuotaReading], samples: [QuotaReading], now: Date, horizon: TimeInterval = defaultHorizon) -> QuotaReading? {
        let current = quotas.filter { $0.reset > now && now.timeIntervalSince($0.date) < horizon }
        return current.sorted { a, b in
            let left = estimate(a, samples: samples, now: now, horizon: horizon).exhaustion
            let right = estimate(b, samples: samples, now: now, horizon: horizon).exhaustion
            if left != right { return (left ?? .distantFuture) < (right ?? .distantFuture) }
            if a.used != b.used { return a.used > b.used }
            return a.id < b.id
        }.first
    }
}

extension Runway {
    static func clockLabel(_ date: Date, now: Date = Date()) -> String {
        if date <= now { return "Now" }
        // Five-minute rounding communicates the uncertainty and avoids a twitchy minute hand.
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded(.up) * 300)
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDate(rounded, inSameDayAs: now) { prefix = "" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(rounded, inSameDayAs: tomorrow) { prefix = "Tomorrow " }
        else { prefix = rounded.formatted(.dateTime.month(.abbreviated).day()) + " " }
        return prefix + "≈ " + rounded.formatted(date: .omitted, time: .shortened)
    }
}

struct QuotaPlotPoint: Identifiable {
    var reading: QuotaReading
    var segment: Int
    var id: String { reading.id + "|" + reading.date.ISO8601Format() }
    static func build(_ history: [QuotaReading], for id: String) -> [QuotaPlotPoint] {
        var seen = Set<Date>(), result: [QuotaPlotPoint] = [], segment = 0
        for reading in history.filter({ $0.id == id }).sorted(by: { $0.date < $1.date }) where seen.insert(reading.date).inserted {
            if let last = result.last?.reading,
               reading.reset != last.reset || reading.used < last.used || reading.date.timeIntervalSince(last.date) > 600 { segment += 1 }
            result.append(QuotaPlotPoint(reading: reading, segment: segment))
        }
        return result
    }
}
