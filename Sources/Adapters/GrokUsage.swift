import Foundation
import CryptoKit

/// Local Grok/xAI session usage. Reads persisted usage.json, summary.json, and the grok usage envelope.
/// Never copies prompt, chat, title, or summary text into the ledger.
enum GrokUsage {
    static let provider = "xai"
    static func int(_ json: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            guard json[key] != nil else { continue }
            if let value = json[key] as? Int { return value }
            if let value = json[key] as? Int64 { return Int(value) }
            if let value = json[key] as? Double, let integer = Int(exactly: value) { return integer }
        }
        return nil
    }
    static func date(_ raw: Any?, iso: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> Date? {
        if let value = raw as? Double {
            guard value.isFinite, value > 0, value < 253402300800 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        if let value = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(value)) }
        guard let text = raw as? String, !text.isEmpty else { return nil }
        if let date = iso.date(from: text) ?? plain.date(from: text) { return date }
        let offset = ISO8601DateFormatter()
        offset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let candidates = text.hasSuffix("Z") ? [text, String(text.dropLast()) + "+00:00"] : [text]
        for candidate in candidates {
            if let date = offset.date(from: candidate) { return date }
        }
        offset.formatOptions = [.withInternetDateTime]
        for candidate in candidates {
            if let date = offset.date(from: candidate) { return date }
        }
        return fractionalDate(text)
    }
    /// Grok writes six-digit fractional seconds; ISO8601DateFormatter often accepts milliseconds only.
    private static func fractionalDate(_ text: String) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let fractionStart = text.index(after: dot)
        let zoneStart = text[fractionStart...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? text.endIndex
        let digits = text[fractionStart..<zoneStart].filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        let millis = String(digits.padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3))
        var zone = String(text[zoneStart...])
        if zone == "Z" || zone.isEmpty { zone = "+00:00" }
        let trimmed = String(text[..<fractionStart]) + millis + zone
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }
    /// Map Grok counters onto Codex's split. Missing keys stay absent rather than invented zeros.
    static func tokens(_ json: [String: Any]) -> (Tokens, [String]) {
        var raw: [String: Any] = [:]
        if let value = int(json, "inputTokens", "input_tokens") { raw["input_tokens"] = value }
        if let value = int(json, "cachedReadTokens", "cached_input_tokens", "cache_read_input_tokens", "cacheReadInputTokens") {
            raw["cached_input_tokens"] = value
        }
        if let value = int(json, "cacheCreationTokens", "cache_write_input_tokens", "cache_creation_input_tokens", "cacheWriteInputTokens") {
            raw["cache_write_input_tokens"] = value
        }
        if let value = int(json, "outputTokens", "output_tokens") { raw["output_tokens"] = value }
        if let value = int(json, "reasoningTokens", "reasoning_output_tokens", "reasoning_tokens") {
            raw["reasoning_output_tokens"] = value
        }
        var tokens = Tokens(raw)
        if let total = int(json, "totalTokens", "total_tokens") {
            let cached = tokens.cached, writes = tokens.cacheWrite ?? 0
            if total == tokens.input + cached + writes + tokens.output, total != tokens.input + tokens.output {
                tokens.input += cached + writes
            }
        }
        return (tokens, UsageMetadata.fields.filter { raw[$0] as? Int != nil })
    }
    static func effort(_ raw: String?) -> String? {
        guard let value = raw?.lowercased(),
              ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(value) else { return nil }
        return value
    }
    /// Session ticks are cumulative; admit only the increment since the last cursor.
    static func tickDelta(session: Int?, previous: Int?) -> Int? {
        guard let session else { return nil }
        guard let previous else { return session }
        return session >= previous ? session - previous : session
    }
}

struct GrokActivity {
    var session: String
    var kind: ActivityKind
    var model: String
    var turn: String
    var output: Int
    var date: Date
    var outputDate: Date?
    var running: Bool
    var path: URL
    var name: String = ""
}

/// Serial ActivityFeed-owned metadata references, including children whose
/// summary has not been created yet. Full discovery refreshes this inventory.
final class GrokActivityMetadata {
    var paths: [String: URL] = [:]
}

enum GrokActivitySources {
    static func read(home: URL, paths: Set<URL>? = nil, known: [GrokActivity] = [], metadata cache: GrokActivityMetadata? = nil) -> [GrokActivity] {
        let cache = cache ?? GrokActivityMetadata()
        var result: [GrokActivity] = []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let active = GrokSessionFile.activeSessionIDs(home: home)
        let now = Date()
        let root = home.appendingPathComponent("sessions")
        let summaries: [URL]
        if let paths, !paths.contains(home) {
            var folders = Set(paths.filter { $0.path.hasPrefix(root.path + "/") &&
                ["usage.json", "summary.json", "signals.json"].contains($0.lastPathComponent) }.map { $0.deletingLastPathComponent() })
            if paths.contains(home.appendingPathComponent("active_sessions.json")) {
                folders.formUnion(known.map { $0.path.deletingLastPathComponent() })
                folders.formUnion(active.map { root.appendingPathComponent($0) })
            }
            summaries = folders.map { $0.appendingPathComponent("summary.json") }
        } else {
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            summaries = walker?.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "summary.json" } ?? []
        }
        for url in summaries {
            guard let summary = GrokSessionFile.summary(at: url), let id = summary.id else { continue }
            let folder = url.deletingLastPathComponent()
            let usageURL = folder.appendingPathComponent("usage.json")
            let usage = GrokSessionFile.usage(at: usageURL)
            let kind = ActivityKind.grok(parentSessionID: summary.parentSessionID, subagentType: nil, sessionKind: summary.sessionKind)
            let output = usage.flatMap { GrokUsage.int($0.session, "outputTokens", "output_tokens") } ?? 0
            let lastActive = GrokUsage.date(summary.lastActiveAt, iso: iso, plain: plain)
                ?? GrokUsage.date(summary.updatedAt, iso: iso, plain: plain)
            let outputDate = usage.flatMap { GrokUsage.date($0.updatedAt, iso: iso, plain: plain) }
            let open = active.contains(id)
            var observed = lastActive ?? outputDate ?? .distantPast
            if open { observed = max(observed, now) }
            let running = summary.running || open || (observed != .distantPast && now.timeIntervalSince(observed) < 300)
            let model = usage.flatMap { $0.session["primaryModelId"] as? String } ?? summary.model ?? "Unknown model"
            let turn = usage.flatMap { $0.turns.last.flatMap { GrokUsage.int($0, "turnNumber").map(String.init) } } ?? id
            result.append(GrokActivity(session: id, kind: kind, model: model, turn: "grok:" + id + ":" + turn, output: output,
                                       date: observed, outputDate: outputDate, running: running, path: usageURL,
                                       name: Project.name(summary.cwd) ?? ""))
        }
        let metadata: [URL]
        if let paths, !paths.contains(home) { metadata = paths.filter { $0.lastPathComponent == "meta.json" } }
        else {
            metadata = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "meta.json" && $0.path.contains("/subagents/") } ?? []
        }
        if paths == nil || paths!.contains(home) { cache.paths = [:] }
        for url in metadata {
            if let child = GrokSessionFile.meta(at: url)?.childSessionID { cache.paths[child] = url }
        }
        let changedChildren = Set(metadata.compactMap { GrokSessionFile.meta(at: $0)?.childSessionID })
        for child in changedChildren where !result.contains(where: { $0.session == child }) {
            if let previous = known.first(where: { $0.session == child }) { result.append(previous) }
        }
        for index in result.indices {
            let child = result[index].session
            if let url = cache.paths[child], let meta = GrokSessionFile.meta(at: url) {
                result[index].kind = .agent
                if meta.running { result[index].running = true }
            } else if known.contains(where: { $0.session == child && $0.kind == .agent }) {
                result[index].kind = .agent
            }
        }
        return result
    }
}

enum GrokSessionFile {
    static func activeSessionIDs(home: URL) -> Set<String> {
        let url = home.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return Set(rows.compactMap { $0["session_id"] as? String }.filter { !$0.isEmpty })
    }
    static func summary(at url: URL) -> (id: String?, model: String?, parentSessionID: String?, updatedAt: Any?, lastActiveAt: Any?, running: Bool, effort: String?, cwd: String?, sessionKind: String?)? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let info = root["info"] as? [String: Any]
        let id = info?["id"] as? String ?? root["session_id"] as? String
        let status = (root["status"] as? String)?.lowercased()
        let running = status == "running"
        return (id, root["current_model_id"] as? String, root["parent_session_id"] as? String,
                root["updated_at"], root["last_active_at"] ?? root["updated_at"], running,
                root["reasoning_effort"] as? String, Project.path(info?["cwd"]), root["session_kind"] as? String)
    }
    static func usage(at url: URL) -> (session: [String: Any], turns: [[String: Any]], sessionId: String?, updatedAt: Any?)? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let session = root["session"] as? [String: Any] ?? [:]
        let turns = root["turns"] as? [[String: Any]] ?? []
        return (session, turns, root["sessionId"] as? String, root["updatedAt"])
    }
    static func meta(at url: URL) -> (childSessionID: String?, parentSessionID: String?, running: Bool, type: String?)? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let status = (root["status"] as? String)?.lowercased()
        return (root["child_session_id"] as? String, root["parent_session_id"] as? String,
                status == "running", root["subagent_type"] as? String)
    }
}

extension ActivityKind {
    static func grok(parentSessionID: String?, subagentType: String?, sessionKind: String? = nil) -> ActivityKind {
        if parentSessionID != nil || subagentType != nil { return .agent }
        if let kind = sessionKind?.lowercased(), kind.hasPrefix("subagent") { return .agent }
        return .chat
    }
}

extension UsageScanner {
    func scanGrok(historical: Bool, poll: Date, paths: Set<URL>? = nil, errors: inout [String], progress: ((Int, Int) -> Void)? = nil) -> Int {
        guard let grokHome else { return 0 }
        let root = grokHome.appendingPathComponent("sessions")
        var count = 0
        let startDay = Calendar.current.startOfDay(for: ledger.started)
        let files: [URL]
        if let paths {
            files = Array(Set(paths.filter {
                $0.path.hasPrefix(root.path + "/") &&
                ["usage.json", "summary.json"].contains($0.lastPathComponent)
            }.map { $0.deletingLastPathComponent().appendingPathComponent("usage.json") })).sorted { $0.path < $1.path }
        } else {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { return 0 }
            files = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "usage.json" }
        }
        progress?(0, files.count)
        for (index, url) in files.enumerated() {
            defer { progress?(index + 1, files.count) }
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard historical || (values.contentModificationDate ?? .distantPast) >= startDay else { continue }
                let key = "grok:" + url.path.replacingOccurrences(of: grokHome.path + "/", with: "")
                var cursor = historical ? (ledger.historyCursors?[key] ?? Cursor()) : (ledger.cursors[key] ?? Cursor())
                count += 1
                lastWork.grokFiles += 1
                let previous = cursor
                try ingestGrok(usageURL: url, cursor: &cursor, poll: poll, historical: historical)
                guard cursor != previous else { continue }
                markMetadataDirty()
                if historical {
                    if ledger.historyCursors == nil { ledger.historyCursors = [:] }
                    ledger.historyCursors?[key] = cursor
                    if rebuilding { ledger.cursors[key] = cursor }
                } else { ledger.cursors[key] = cursor }
            } catch { errors.append("A Grok session could not be read: \(error.localizedDescription)") }
        }
        return count
    }
    func ingestGrok(usageURL: URL, cursor: inout Cursor, poll: Date, historical: Bool) throws {
        guard let usage = GrokSessionFile.usage(at: usageURL) else { return }
        let summaryURL = usageURL.deletingLastPathComponent().appendingPathComponent("summary.json")
        let summary = GrokSessionFile.summary(at: summaryURL)
        let sessionID = usage.sessionId ?? summary?.id ?? String(usageURL.deletingLastPathComponent().lastPathComponent.prefix(36))
        let model = (usage.session["primaryModelId"] as? String) ?? summary?.model ?? cursor.model
        cursor.model = model
        cursor.provider = GrokUsage.provider
        cursor.effort = GrokUsage.effort(summary?.effort)
        cursor.requestedService = nil
        let parent = summary?.parentSessionID
        let projectPath = summary?.cwd
        cursor.projectPath = projectPath
        let turns = usage.turns.sorted { (GrokUsage.int($0, "turnNumber") ?? 0) < (GrokUsage.int($1, "turnNumber") ?? 0) }
        let lastSeen = Int(cursor.turnID ?? "") ?? 0
        let selected: [[String: Any]]
        if cursor.previous == nil {
            selected = turns
        } else {
            selected = turns.filter { (GrokUsage.int($0, "turnNumber") ?? 0) > lastSeen }
        }
        let sessionTicks = GrokUsage.int(usage.session, "costUsdTicks", "total_cost_usd_ticks")
        if selected.isEmpty, let previous = cursor.previous {
            let (total, fields) = GrokUsage.tokens(usage.session)
            if total == previous { return }
            let delta: Tokens
            if total.input >= previous.input && total.output >= previous.output {
                delta = total.delta(from: previous)
            } else if let last = turns.last {
                delta = GrokUsage.tokens(last).0
            } else {
                delta = Tokens()
            }
            let ticks = GrokUsage.tickDelta(session: sessionTicks, previous: cursor.previousTicks)
            guard let stamp = GrokUsage.date(usage.updatedAt, iso: iso, plain: plainISO)
                ?? GrokUsage.date(turns.last?["endedAt"] ?? turns.last?["ended_at"], iso: iso, plain: plainISO)
            else { throw NSError(domain: "CodexTokenBar", code: 12, userInfo: [NSLocalizedDescriptionKey: "Grok usage has no usable event timestamp"]) }
            cursor.previous = total
            cursor.previousFields = fields
            cursor.previousTicks = sessionTicks
            try admitGrok(session: sessionID, model: model, tokens: delta, fields: fields,
                          date: stamp, turn: cursor.turnID ?? "session", ticks: ticks,
                          raw: usage.session, historical: historical, last: nil, effort: cursor.effort,
                          projectPath: projectPath)
            return
        }
        if cursor.previous == nil, parent != nil, let last = turns.last {
            let (sessionTokens, sessionFields) = GrokUsage.tokens(usage.session)
            let (turnTokens, turnFields) = GrokUsage.tokens(last)
            // Real Grok forks copy inherited session totals onto turn 1. That snapshot is a
            // baseline, not new work. An incremental last turn (smaller than the session) is
            // the Codex last-request analog and is admitted.
            if CostRecovery.sameUsage(turnTokens, sessionTokens) {
                cursor.previous = sessionTokens
                cursor.turnID = GrokUsage.int(last, "turnNumber").map(String.init)
                cursor.previousFields = sessionFields
                cursor.previousTicks = sessionTicks
                return
            }
            try admitGrokTurn(last, session: sessionID, model: model, historical: historical, effort: cursor.effort, projectPath: projectPath)
            cursor.previous = sessionTokens
            cursor.turnID = GrokUsage.int(last, "turnNumber").map(String.init)
            cursor.previousFields = turnFields
            cursor.previousTicks = sessionTicks
            return
        }
        for turn in selected {
            try admitGrokTurn(turn, session: sessionID, model: model, historical: historical, effort: cursor.effort, projectPath: projectPath)
            cursor.turnID = GrokUsage.int(turn, "turnNumber").map(String.init) ?? cursor.turnID
        }
        cursor.previous = GrokUsage.tokens(usage.session).0
        cursor.previousFields = GrokUsage.tokens(usage.session).1
        cursor.previousTicks = sessionTicks
    }
    private func admitGrokTurn(_ turn: [String: Any], session: String, model: String, historical: Bool, effort: String?, projectPath: String?) throws {
        let (tokens, fields) = GrokUsage.tokens(turn)
        guard tokens.total > 0 else { return }
        guard let date = GrokUsage.date(turn["endedAt"] ?? turn["ended_at"], iso: iso, plain: plainISO) else {
            throw NSError(domain: "CodexTokenBar", code: 12, userInfo: [NSLocalizedDescriptionKey: "Grok usage has no usable event timestamp"])
        }
        let turnID = GrokUsage.int(turn, "turnNumber").map(String.init) ?? "turn"
        let ticks = GrokUsage.int(turn, "costUsdTicks", "total_cost_usd_ticks")
        try admitGrok(session: session, model: model, tokens: tokens, fields: fields, date: date, turn: turnID, ticks: ticks, raw: turn, historical: historical, last: tokens, effort: effort, projectPath: projectPath)
    }
    private func admitGrok(session: String, model: String, tokens: Tokens, fields: [String], date: Date, turn: String, ticks: Int?, raw: [String: Any], historical: Bool, last: Tokens?, effort: String?, projectPath: String?) throws {
        let boundary = Calendar.current.startOfDay(for: ledger.started)
        guard rebuilding || (historical ? date < boundary : date >= boundary) else { return }
        guard tokens.total > 0 else { return }
        let canonical = (try? JSONSerialization.data(withJSONObject: raw.filter { key, _ in
            ["inputTokens", "outputTokens", "cachedReadTokens", "cacheCreationTokens", "reasoningTokens", "totalTokens",
             "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "reasoning_tokens",
             "turnNumber", "endedAt"].contains(key)
        }, options: [.sortedKeys])) ?? Data()
        let identity = "grok|\(session)|\(turn)|\(String(decoding: canonical, as: UTF8.self))"
        let fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let duplicate = identityKnown(fingerprint) { if duplicate { return } } else { return }
        var cursor = Cursor(); cursor.turnID = turn; cursor.provider = GrokUsage.provider; cursor.model = model
        cursor.effort = effort
        cursor.projectPath = projectPath
        var entry = Entry(date: date, session: session, model: model, tokens: tokens, account: nil)
        entry.provider = GrokUsage.provider
        entry.harness = Harness.grok
        entry.projectPath = projectPath
        entry.effort = effort
        entry.costUsdTicks = ticks
        UsageMetadata.enrich(&entry, cursor: cursor, fields: fields, fingerprint: fingerprint, last: last, info: [:])
        if rebuilding { entry.account = restoredAccounts[Self.restoreKey(entry)] }
        persistAdmitted(entry, fingerprint: fingerprint, date: date)
        if loadError != nil { throw NSError(domain: "CodexTokenBar", code: 3, userInfo: [NSLocalizedDescriptionKey: loadError!]) }
    }
}
