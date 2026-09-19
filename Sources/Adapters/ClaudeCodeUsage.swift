import Foundation

/// Local Claude Code transcript usage.
///
/// Transcripts are append-only JSONL under `~/.claude/projects/<slug>/*.jsonl`.
/// Assistant usage may increase across repeated records for one message.
/// Count the largest compatible snapshot, never the sum of repeated snapshots.
///
/// Cache counters are disjoint from input here, unlike Codex. `Tokens.canonical`
/// performs that conversion.
enum ClaudeCodeUsage {
    /// Counters this harness records, in the canonical vocabulary.
    static let recordedFields = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"]
    static let harness = "Claude Code"
    static let provider = "anthropic"

    /// Legacy transcript overrides take precedence; otherwise follow Claude's official root.
    static func home(environment: [String: String] = ProcessInfo.processInfo.environment,
                     userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        for key in ["CLAUDE_HOME", "CLAUDE_CONFIG_DIR"] {
            if let value = environment[key], !value.isEmpty { return URL(fileURLWithPath: value) }
        }
        return userHome.appendingPathComponent(".claude")
    }

    /// One admitted assistant message.
    struct Turn {
        var messageID: String
        var session: String
        var model: String
        var tokens: Tokens
        var date: Date
        var projectPath: String?
        var gitBranch: String?
        var clientVersion: String?
        var serviceTier: String?
        /// Sidechain records are subagent transcripts. They are real usage and
        /// are counted once, like any other message.
        var isSidechain: Bool
    }

    /// Decode one transcript line. Returns nil for anything without usage.
    static func turn(from root: [String: Any]) -> Turn? {
        turn(from: root, includingZeroUsage: false)
    }

    /// Scans also validate empty observations without admitting them as usage.
    static func turn(from root: [String: Any], includingZeroUsage: Bool) -> Turn? {
        guard root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let id = message["id"] as? String, !id.isEmpty,
              let usage = message["usage"] as? [String: Any] else { return nil }
        guard let stamp = date(root["timestamp"]),
              let input = usage["input_tokens"] as? Int,
              let cached = usage["cache_read_input_tokens"] as? Int,
              let written = usage["cache_creation_input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int,
              [input, cached, written, output].allSatisfy({ $0 >= 0 }) else { return nil }
        let context = input.addingReportingOverflow(cached)
        let fullContext = context.partialValue.addingReportingOverflow(written)
        guard !context.overflow, !fullContext.overflow, !fullContext.partialValue.addingReportingOverflow(output).overflow else { return nil }
        var tokens = Tokens.canonical(
            input: input,
            cacheRead: cached,
            cacheWrite: written,
            output: output,
            reasoning: 0,
            convention: .cacheBesideInput)
        tokens.cacheWrite = written // A recorded zero is available, not missing.
        guard includingZeroUsage || tokens.total > 0 else { return nil }
        let session = (root["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        return Turn(messageID: id,
                    session: session,
                    model: message["model"] as? String ?? "Unknown model",
                    tokens: tokens,
                    date: stamp,
                    projectPath: Project.path(root["cwd"]),
                    gitBranch: branch(root["gitBranch"]),
                    clientVersion: root["version"] as? String,
                    serviceTier: UsageMetadata.service(usage["service_tier"]),
                    isSidechain: root["isSidechain"] as? Bool ?? false)
    }

    /// Retain a dominating snapshot; older duplicates cannot lower counters.
    static func deduplicate(_ turns: [Turn]) -> [Turn] {
        var result: [Turn] = [], positions: [String: Int] = [:]
        for turn in turns {
            if let index = positions[turn.messageID] {
                if dominates(turn.tokens, result[index].tokens) { result[index] = turn }
            } else { positions[turn.messageID] = result.count; result.append(turn) }
        }
        return result
    }
    static func components(_ tokens: Tokens) -> [Int] {
        [tokens.input - tokens.cached - (tokens.cacheWrite ?? 0), tokens.cached, tokens.cacheWrite ?? 0, tokens.output]
    }
    static func dominates(_ new: Tokens, _ old: Tokens) -> Bool {
        zip(components(new), components(old)).allSatisfy { $0 >= $1 }
    }
    static func increment(_ new: Tokens, over old: Tokens) -> Tokens {
        let delta = zip(components(new), components(old)).map { $0 - $1 }
        var result = Tokens.canonical(input: delta[0], cacheRead: delta[1], cacheWrite: delta[2], output: delta[3], reasoning: 0, convention: .cacheBesideInput)
        if new.cacheWrite != nil { result.cacheWrite = delta[2] }
        return result
    }

    static func date(_ raw: Any?) -> Date? { EventTime.parse(raw) }

    private static func branch(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 200 ? nil : trimmed
    }

    /// Every transcript under the Claude Code home, in deterministic order.
    static func transcripts(home: URL) -> [URL] {
        let root = home.appendingPathComponent("projects")
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" { found.append(url.resolvingSymlinksInPath().standardizedFileURL) }
        return found.sorted { $0.path < $1.path }
    }
}
