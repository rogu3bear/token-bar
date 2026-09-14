import Observation
import Foundation
import Combine
import CryptoKit
import Darwin

/// Account remaining from the installed Grok agent, the Codex app-server analog.
/// `_x.ai/billing` after `initialize`; no session is created and no prompt is sent.
enum GrokBilling {
    static func accountID(home: URL) -> String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for value in root.values {
            guard let object = value as? [String: Any] else { continue }
            if let id = (object["user_id"] as? String) ?? (object["principal_id"] as? String), !id.isEmpty {
                return "grok:" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return nil
    }
    static func percent(_ raw: Any?) -> Double? {
        if let value = raw as? Double, value.isFinite, (0...100).contains(value) { return value }
        if let value = raw as? Int, (0...100).contains(value) { return Double(value) }
        return nil
    }
    static func reading(from result: [String: Any], accountID: String, now: Date) -> QuotaReading? {
        let config = result["config"] as? [String: Any] ?? result
        guard let used = percent(config["creditUsagePercent"]) else { return nil }
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let reset = GrokUsage.date(period["end"] ?? config["billingPeriodEnd"], iso: iso, plain: plain), reset > now else { return nil }
        let start = GrokUsage.date(period["start"] ?? config["billingPeriodStart"], iso: iso, plain: plain)
        let minutes: Int
        if let start, start < reset { minutes = Int(reset.timeIntervalSince(start) / 60) }
        else if let known = windowMinutes(period["type"] as? String) { minutes = known }
        else { return nil }
        guard minutes > 0 else { return nil }
        let window = windowName(period["type"] as? String)
        let plan = result["subscription_tier"] as? String
        return QuotaReading(accountID: accountID, bucket: "grok", name: plan ?? "Grok", window: window, minutes: minutes, used: used, reset: reset, date: now)
    }
    static func windowName(_ type: String?) -> String {
        let text = type?.uppercased() ?? ""
        if text.contains("WEEK") { return "weekly" }
        if text.contains("MONTH") { return "monthly" }
        if text.contains("DAY") { return "daily" }
        return "primary"
    }
    static func windowMinutes(_ type: String?) -> Int? {
        switch windowName(type) {
        case "weekly": return 10080
        case "monthly": return nil // Calendar months require source period endpoints.
        case "daily": return 1440
        default: return nil
        }
    }
}

@Observable final class GrokQuotaMonitor {
    var quota = ToolQuotaState(unavailable: "Awaiting fresh Grok quota")
    let home: URL
    let enabled: Bool
    private let queue = DispatchQueue(label: "local.token-bar.grok-quota", qos: .utility, autoreleaseFrequency: .workItem)
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var processAccount: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var sequence = 0
    init(home: URL, enabled: Bool = true) {
        self.home = home
        self.enabled = enabled
    }
    func stop() {
        generation += 1; busy = false
        queue.async { self.process?.terminate(); self.process = nil; self.processAccount = nil }
    }
    func refresh() {
        guard enabled else { return }
        guard !busy else { return }
        busy = true
        let generation = self.generation
        queue.async {
            let now = Date()
            do {
                guard let id = GrokBilling.accountID(home: self.home) else { throw self.failure("Grok account identity is unavailable") }
                if self.processAccount != id { self.process?.terminate(); self.process = nil }
                let result = try self.readBilling(account: id)
                guard GrokBilling.accountID(home: self.home) == id, self.processAccount == id else {
                    throw self.failure("Grok account changed during the quota read")
                }
                guard let reading = GrokBilling.reading(from: result, accountID: id, now: now) else {
                    throw self.failure("Grok billing did not include a usable remaining allowance")
                }
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    guard GrokBilling.accountID(home: self.home) == id else {
                        self.quota = ToolQuotaState(unavailable: "Grok account changed; awaiting a fresh quota")
                        self.busy = false; return
                    }
                    var samples = self.quota.samples.filter { $0.accountID == id && $0.date >= now.addingTimeInterval(-1800) }
                    if !samples.contains(where: { $0.id == reading.id && $0.date == reading.date }) { samples.append(reading) }
                    self.quota = ToolQuotaState(readings: [reading], samples: samples,
                        unavailable: "Grok quota unavailable · billing missing or stale",
                        accountLabel: reading.name)
                    self.busy = false
                }
            } catch {
                self.process?.terminate(); self.process = nil
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    let current = GrokBilling.accountID(home: self.home)
                    if current == nil || self.quota.readings.contains(where: { $0.accountID != current }) || self.quota.readings.isEmpty {
                        self.quota = ToolQuotaState(unavailable: message)
                    }
                    self.busy = false
                }
            }
        }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexTokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func readBilling(account: String) throws -> [String: Any] {
        if process?.isRunning != true { try start(); processAccount = account }
        return try call("_x.ai/billing", [:])
    }
    private func start() throws {
        process?.terminate(); buffer = Data(); sequence = 0
        guard let executable = GrokInstallation.executable() else { throw failure("Grok is not installed") }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["agent", "--no-leader", "stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["GROK_HOME"] = home.path
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        _ = try call("initialize", ["protocolVersion": 1, "clientInfo": ["name": "token_bar", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"], "clientCapabilities": [:]])
    }
    private func send(_ object: [String: Any]) throws {
        guard let input else { throw failure("Grok billing connection is unavailable") }
        var payload = object
        payload["jsonrpc"] = "2.0"
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: payload) + Data([10]))
    }
    private func call(_ method: String, _ params: Any) throws -> [String: Any] {
        sequence += 1
        let request = sequence
        try send(["id": request, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let echoed = response["id"] as? Int ?? (response["id"] as? Double).map(Int.init)
                guard echoed == request else { continue }
                if let error = response["error"] as? [String: Any] {
                    throw failure(error["message"] as? String ?? "Grok billing read failed")
                }
                return response["result"] as? [String: Any] ?? [:]
            }
            guard let output else { throw failure("Grok billing connection closed") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&descriptor, 1, 250)
            if status > 0 {
                let data = output.availableData
                if data.isEmpty { throw failure("Grok billing connection closed") }
                buffer.append(data)
            }
        }
        throw failure("Grok billing read timed out; existing readings are retained")
    }
}
