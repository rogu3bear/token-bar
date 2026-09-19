import Foundation
import Darwin

/// Asks the installed Claude Code to refresh its own account-bound usage cache,
/// the analog of the Codex app-server and Grok billing reads. The experimental
/// `get_usage` control request fetches plan utilization; after a successful fetch
/// Claude Code rewrites `cachedUsageUtilization` with its own account and
/// `fetchedAtMs`. The reply is undated and can be served from saved data when the
/// fetch is rate limited, so Token Bar ignores it and reads only that cache.
/// No prompt is sent, no session is saved, and no user settings, hooks, MCP
/// servers or skills load.
enum ClaudeUsageRefresh {
    /// Quarter-hour cadence; `ClaudeQuotaSource.horizon` tolerates one missed attempt.
    static let interval: TimeInterval = 900
    static let timeout: TimeInterval = 20
    static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                            "--no-session-persistence", "--setting-sources", "project", "--strict-mcp-config",
                            "--disable-slash-commands"]
    enum Outcome: Equatable { case success, failure(String) }

    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt, lastAttempt <= now else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        CLIExecutable.path(name: "claude", overrideVariable: "CLAUDE_CLI_PATH",
                           extras: [userHome.appendingPathComponent(".local/bin/claude").path, userHome.appendingPathComponent(".claude/local/claude").path,
                                    "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                           environment: environment, isExecutable: isExecutable)
    }
    /// Telemetry, error reporting and self-update stay off for this background request.
    static func environment(_ base: [String: String]) -> [String: String] {
        base.merging(["DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"]) { _, quiet in quiet }
    }
    static func request(id: String) throws -> Data {
        let object: [String: Any] = ["type": "control_request", "request_id": id,
                                     "request": ["subtype": "get_usage", "skip_behaviors": true]]
        return try JSONSerialization.data(withJSONObject: object) + Data([10])
    }
    /// The matching control response, or nil for any other line.
    static func outcome(_ line: Data, id: String) -> Outcome? {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["type"] as? String == "control_response",
              let response = message["response"] as? [String: Any],
              response["request_id"] as? String == id else { return nil }
        if response["subtype"] as? String == "success" { return .success }
        return .failure(response["error"] as? String ?? "Claude Code refused the usage request")
    }
    static func failure(_ text: String) -> NSError {
        NSError(domain: "CodexTokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Runs one request and returns once Claude Code answers; the child never outlives the call.
    static func run(executable: String, directory: URL, environment: [String: String], timeout: TimeInterval = timeout) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = Self.environment(environment)
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        // A child that exits early must surface as an error, not as SIGPIPE in the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let id = UUID().uuidString
        try input.fileHandleForWriting.write(contentsOf: request(id: id))
        let reader = output.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                switch outcome(line, id: id) {
                case .success?: return
                case .failure(let message)?: throw failure(message)
                case nil: continue
                }
            }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 250) > 0 {
                let data = reader.availableData
                if data.isEmpty { throw failure("Claude Code exited before answering the usage request") }
                buffer.append(data)
            }
        }
        throw failure("Claude Code usage refresh timed out")
    }
}
