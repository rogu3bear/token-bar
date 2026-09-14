import Observation
import Foundation

/// Connects Claude Code's status line to the Token Bar relay and back again.
/// The only file touched is the user-level Claude Code `settings.json`, and the
/// only key touched inside it is `statusLine`. Every write keeps a backup.
enum ClaudeStatuslineConnection {
    static let backupPrefix = "settings.json.token-bar-backup-"
    static let backupCap = 3
    static let previousKey = "claudeStatusLine.previous.v1"

    /// What `statusLine` held before Connect, so Disconnect can put it back exactly.
    struct Previous: Codable, Equatable {
        var present: Bool
        var raw: Data?
    }

    static func settingsURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        return directory.appendingPathComponent("settings.json")
    }
    static func stableRelayURL(support: URL) -> URL {
        support.appendingPathComponent("CodexTokenBar/claude-statusline-relay.sh")
    }
    /// A shell-safe single-quoted path; the support directory contains a space.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func command(relay: String, existing: String?) -> String {
        let trimmed = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? quoted(relay) : quoted(relay) + " /bin/sh -c " + quoted(trimmed)
    }
    static func isConnected(_ settings: [String: Any], relay: String) -> Bool {
        guard let line = settings["statusLine"] as? [String: Any], line["type"] as? String == "command",
              let command = line["command"] as? String else { return false }
        return command == quoted(relay) || command.hasPrefix(quoted(relay) + " ")
    }

    /// Copies the bundled relay only when its bytes differ; the copy is what settings reference.
    static func installRelay(from source: URL, to target: URL) throws {
        let bytes = try Data(contentsOf: source)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let existing = try? Data(contentsOf: target), existing == bytes {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return
        }
        let temporary = directory.appendingPathComponent(".claude-statusline-relay.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try bytes.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
    }

    static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object"])
        }
        return object
    }
    static func serialize(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Returns the settings after Connect and what to remember for Disconnect. Nil means nothing changed.
    static func connect(_ settings: [String: Any], relay: String) throws -> (settings: [String: Any], previous: Previous)? {
        if isConnected(settings, relay: relay) { return nil }
        var updated = settings
        let previous: Previous
        if let line = settings["statusLine"] {
            guard let object = line as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "statusLine is not an object"])
            }
            previous = Previous(present: true, raw: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            var line = object
            let existing = object["type"] as? String == "command" ? object["command"] as? String : nil
            line["type"] = "command"
            line["command"] = command(relay: relay, existing: existing)
            updated["statusLine"] = line
        } else {
            previous = Previous(present: false, raw: nil)
            updated["statusLine"] = ["type": "command", "command": quoted(relay)]
        }
        return (updated, previous)
    }

    /// Restores the remembered status line when the relay stands alone as we
    /// wrote it; otherwise only strips the relay prefix so later user edits survive.
    static func disconnect(_ settings: [String: Any], relay: String, previous: Previous?) -> [String: Any]? {
        guard isConnected(settings, relay: relay), var line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return nil }
        var updated = settings
        if let previous, previous.present, let raw = previous.raw,
           let original = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           command == Self.command(relay: relay, existing: original["command"] as? String) {
            updated["statusLine"] = original
            return updated
        }
        if command == quoted(relay) {
            if let previous, previous.present, let raw = previous.raw,
               let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                updated["statusLine"] = object
            } else {
                updated.removeValue(forKey: "statusLine")
            }
            return updated
        }
        line["command"] = String(command.dropFirst(quoted(relay).count + 1))
        updated["statusLine"] = line
        return updated
    }

    /// Timestamped backup beside the file, capped, then an atomic replace that keeps permissions.
    static func write(_ data: Data, to url: URL, now: Date = Date()) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var permissions: Int = 0o600
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            permissions = (attributes[.posixPermissions] as? Int) ?? permissions
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = directory.appendingPathComponent(backupPrefix + formatter.string(from: now))
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            try FileManager.default.copyItem(at: url, to: backup)
            pruneBackups(in: directory)
        }
        let temporary = directory.appendingPathComponent(".settings.json.token-bar-\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
    static func backups(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func pruneBackups(in directory: URL) {
        let extra = backups(in: directory).dropLast(backupCap)
        for url in extra { try? FileManager.default.removeItem(at: url) }
    }
    /// A sibling `settings.local.json` status line would override the user-level one.
    static func shadowCaveat(settingsURL: URL) -> String? {
        let local = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.local.json")
        guard let data = try? Data(contentsOf: local), let object = try? parse(data), object["statusLine"] != nil else { return nil }
        return "settings.local.json also sets a status line; it takes precedence over the connected one."
    }
}

@Observable final class ClaudeConnectionModel {
    enum Status: Equatable {
        case notConnected, configured, connected
        var label: String {
            switch self {
            case .notConnected: return "Not connected"
            case .configured: return "Configured · waiting for the first Claude Code turn"
            case .connected: return "Connected"
            }
        }
    }
    var status: Status
    var caveat: String?
    var error: String?
    let enabled: Bool
    let settingsURL: URL
    let relayURL: URL
    let bundleRelayURL: URL?
    @ObservationIgnored private let defaults: UserDefaults?

    init(settingsURL: URL, relayURL: URL, bundleRelayURL: URL?, defaults: UserDefaults) {
        self.settingsURL = settingsURL; self.relayURL = relayURL; self.bundleRelayURL = bundleRelayURL
        self.defaults = defaults; enabled = true; status = .notConnected
    }
    /// Previews and tests without a real settings file.
    init(fixture: Status) {
        settingsURL = URL(fileURLWithPath: "/dev/null"); relayURL = settingsURL; bundleRelayURL = nil
        defaults = nil; enabled = false; status = fixture
    }
    var explanation: String {
        "Token Bar will add its relay to the status line in \(settingsURL.path), keeping any command already there. " +
        "After each Claude Code turn the relay stores Claude Code's status JSON privately at " +
        "\(relayURL.deletingLastPathComponent().path)/claude-statusline.json (0600); only its rate_limits are read. " +
        "Relay readings lack account identity and are not used as account quota. " +
        "A backup of settings.json is kept beside it. Disconnect restores the previous status line."
    }
    var settingsConnected: Bool {
        guard let object = try? ClaudeStatuslineConnection.parse(try? Data(contentsOf: settingsURL)) else { return false }
        return ClaudeStatuslineConnection.isConnected(object, relay: relayURL.path)
    }
    @discardableResult func installRelay() -> Bool {
        guard enabled else { return false }
        guard let bundleRelayURL else {
            error = "Relay install failed: the bundled relay is unavailable."
            return false
        }
        do {
            try ClaudeStatuslineConnection.installRelay(from: bundleRelayURL, to: relayURL)
            return true
        } catch {
            self.error = "Relay install failed: " + error.localizedDescription
            return false
        }
    }
    func refresh(relayObserved: Bool) {
        guard enabled else { return }
        status = settingsConnected ? (relayObserved ? .connected : .configured) : .notConnected
        caveat = settingsConnected ? ClaudeStatuslineConnection.shadowCaveat(settingsURL: settingsURL) : nil
    }
    @discardableResult func connect() -> Bool {
        guard enabled else { return false }
        guard installRelay() else { return false }
        do {
            let settings = try ClaudeStatuslineConnection.parse(try? Data(contentsOf: settingsURL))
            if let result = try ClaudeStatuslineConnection.connect(settings, relay: relayURL.path) {
                try ClaudeStatuslineConnection.write(try ClaudeStatuslineConnection.serialize(result.settings), to: settingsURL)
                defaults?.set(try JSONEncoder().encode(result.previous), forKey: ClaudeStatuslineConnection.previousKey)
            }
            error = nil
            refresh(relayObserved: false)
            return true
        } catch {
            self.error = "Connect failed: " + error.localizedDescription
            return false
        }
    }
    @discardableResult func disconnect() -> Bool {
        guard enabled else { return false }
        do {
            let settings = try ClaudeStatuslineConnection.parse(try? Data(contentsOf: settingsURL))
            let previous = defaults?.data(forKey: ClaudeStatuslineConnection.previousKey)
                .flatMap { try? JSONDecoder().decode(ClaudeStatuslineConnection.Previous.self, from: $0) }
            if let updated = ClaudeStatuslineConnection.disconnect(settings, relay: relayURL.path, previous: previous) {
                try ClaudeStatuslineConnection.write(try ClaudeStatuslineConnection.serialize(updated), to: settingsURL)
            }
            defaults?.removeObject(forKey: ClaudeStatuslineConnection.previousKey)
            error = nil
            refresh(relayObserved: false)
            return true
        } catch {
            self.error = "Disconnect failed: " + error.localizedDescription
            return false
        }
    }
}
