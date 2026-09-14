import Foundation
import CryptoKit

/// Ledger admission for the two harnesses that keep their own stores.
///
/// Both admit through the same path as Codex and Grok, so deduplication, the
/// historical boundary and the request archive behave identically. Identity is
/// scoped by harness: a message id is unique within its tool, and the prefix
/// keeps two tools from ever colliding on one fingerprint.
extension UsageScanner {
    /// `<harness>|<message id>` is stable across rescans and unique across tools.
    static func foreignIdentity(harness: String, messageID: String) -> String {
        SHA256.hash(data: Data("\(harness)|\(messageID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func scanClaudeCode(historical: Bool, paths: Set<URL>? = nil, errors: inout [String], progress: ((Int, Int) -> Void)? = nil) -> Int {
        guard let configuredHome = claudeHome else { return 0 }
        let home = configuredHome.resolvingSymlinksInPath().standardizedFileURL
        var admitted = 0
        let transcripts = paths.map { $0.map { $0.resolvingSymlinksInPath().standardizedFileURL }.filter { $0.path.hasPrefix(home.appendingPathComponent("projects").path + "/") }.sorted { $0.path < $1.path } } ?? ClaudeCodeUsage.transcripts(home: home)
        progress?(0, transcripts.count)
        for (index, transcript) in transcripts.enumerated() {
            defer { progress?(index + 1, transcripts.count) }
            do {
                let stamp = try ClaudeFileCheck.read(transcript)
                let key = (historical ? "history:" : "current:") + String(ledger.started.timeIntervalSince1970) + ":" + transcript.path
                if !rebuilding, ledger.claudeFileChecks?[key] == stamp { continue }
                if ledger.claudeFileChecks?[key] != nil { ledger.claudeFileChecks?[key] = nil; markMetadataDirty() }
                let errorsBefore = errors.count
                let cursor = try claudeTail(transcript, key: key, stamp: stamp) { line in
                    guard line.range(of: Data("\"assistant\"".utf8)) != nil,
                          line.range(of: Data("\"usage\"".utf8)) != nil else { return }
                    guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        errors.append("A Claude Code usage record could not be decoded; coverage is incomplete.")
                        return
                    }
                    guard root["type"] as? String == "assistant",
                          let message = root["message"] as? [String: Any], message["usage"] != nil else { return }
                    guard let turn = ClaudeCodeUsage.turn(from: root, includingZeroUsage: true) else {
                        errors.append("A Claude Code usage record has missing or invalid counters, identity, or timestamp; coverage is incomplete.")
                        return
                    }
                    if admit(claude: turn, historical: historical, errors: &errors) { admitted += 1 }
                }
                if errors.count == errorsBefore, loadError == nil, try ClaudeFileCheck.read(transcript) == stamp {
                    if ledger.claudeFileChecks == nil { ledger.claudeFileChecks = [:] }
                    ledger.claudeFileChecks?[key] = stamp
                    if ledger.claudeCursors == nil { ledger.claudeCursors = [:] }
                    ledger.claudeCursors?[key] = cursor
                    markMetadataDirty()
                }
            } catch {
                errors.append("A Claude Code transcript could not be read: \(error.localizedDescription)")
            }
        }
        return admitted
    }

    private func admit(claude turn: ClaudeCodeUsage.Turn, historical: Bool, errors: inout [String]) -> Bool {
        let baseID = Self.foreignIdentity(harness: ClaudeCodeUsage.harness, messageID: turn.messageID)
        let boundary = Calendar.current.startOfDay(for: ledger.started)
        guard rebuilding || (historical ? turn.date < boundary : turn.date >= boundary) else { return false }
        var previous = ledger.claudeCounters?[baseID]
        if previous == nil {
            guard let known = identityKnown(baseID) else { return false }
            if known {
                do {
                    let retained = try requestArchive?.entry(id: baseID) ?? ledger.entries.first { $0.recordID == baseID }
                    if let retained, retained.recordID == baseID, retained.harness == ClaudeCodeUsage.harness,
                       retained.provider == ClaudeCodeUsage.provider, retained.session == turn.session, retained.model == turn.model {
                        previous = retained.tokens
                    }
                } catch { errors.append("A retained Claude counter baseline could not be read."); return false }
                guard previous != nil else {
                    errors.append("Some older Claude messages lack retained counter baselines; their totals are preserved and increases cannot be reconciled.")
                    return false
                }
            }
        }
        let baseline = previous ?? Tokens()
        guard ClaudeCodeUsage.components(baseline).allSatisfy({ $0 >= 0 }) else {
            errors.append("A retained Claude counter baseline is inconsistent; its total was preserved.")
            return false
        }
        guard ClaudeCodeUsage.dominates(turn.tokens, baseline) else {
            if !ClaudeCodeUsage.dominates(baseline, turn.tokens) {
                errors.append("Conflicting Claude counter revisions were retained without guessing a total.")
            }
            return false
        }
        let delta = ClaudeCodeUsage.increment(turn.tokens, over: baseline)
        guard delta.total > 0 else { return false }
        let fingerprint = previous == nil ? baseID : Self.foreignIdentity(harness: "Claude Code revision", messageID:
            baseID + "|" + ClaudeCodeUsage.components(turn.tokens).map(String.init).joined(separator: ":"))
        guard let known = identityKnown(fingerprint), !known else { return false }
        var entry = Entry(date: turn.date, session: turn.session, model: turn.model, tokens: delta, account: nil)
        entry.provider = ClaudeCodeUsage.provider
        entry.harness = ClaudeCodeUsage.harness
        entry.projectPath = turn.projectPath
        entry.observedService = turn.serviceTier
        entry.serviceEvidence = turn.serviceTier == nil ? nil : "message.usage.service_tier"
        entry.turnID = turn.messageID
        entry.recordID = fingerprint
        entry.tokenFields = ClaudeCodeUsage.recordedFields
        entry.pricingDay = UsageMetadata.day(turn.date)
        entry.firstObserved = turn.date
        entry.requestInputTokens = turn.tokens.input
        entry.costMetadataVersion = 2
        // An increase belongs to the existing message, not a second request.
        if previous != nil { entry.sampleCount = 0; entry.bucket = "revision" }
        persistAdmitted(entry, fingerprint: fingerprint, date: turn.date)
        guard ledger.eventIDs?.contains(fingerprint) == true else { return false }
        if ledger.claudeCounters == nil { ledger.claudeCounters = [:] }
        ledger.claudeCounters?[baseID] = turn.tokens
        return true
    }

    func scanOpenCode(historical: Bool, errors: inout [String], progress: ((Int, Int) -> Void)? = nil) -> Int {
        guard let home = openCodeHome else { openCodeReader = nil; return 0 }
        let database = home.appendingPathComponent("opencode.db")
        var admitted = 0
        do {
            let key = (historical ? "history:" : "current:") + String(ledger.started.timeIntervalSince1970) + ":" + database.path
            guard FileManager.default.fileExists(atPath: database.path) else { openCodeReader = nil; return 0 }
            let resolved = database.resolvingSymlinksInPath()
            let inode = try ClaudeFileCheck.read(resolved).inode
            if openCodeReader?.path != resolved.path || openCodeReader?.inode != inode { openCodeReader = nil }
            let reader: OpenCodeUsage.Reader
            if let existing = openCodeReader { reader = existing.reader }
            else {
                reader = try OpenCodeUsage.Reader(database: resolved)
                // A file disappearing between stat and open must not cache an empty reader.
                if reader.isOpen { openCodeReader = (resolved.path, inode, reader) }
            }
            var cursor = rebuilding ? nil : ledger.openCodeCursors?[key]
            if cursor?.inode != inode { cursor = nil }
            var pending = ledger.openCodePending?[key] ?? []
            let previousPending = pending.sorted()
            func accept(_ page: OpenCodeUsage.Page, checked: [String] = []) {
                lastWork.openCodeRows += page.rows
                for turn in page.turns {
                    if admit(openCode: turn, historical: historical) { admitted += 1 }
                }
                pending.subtract(checked)
                pending.formUnion(page.pending)
            }
            for start in stride(from: 0, to: previousPending.count, by: 512) {
                let ids = Array(previousPending[start..<min(start + 512, previousPending.count)])
                accept(try reader.page(ids: ids), checked: ids)
            }
            while true {
                let page = try reader.page(after: cursor)
                accept(page)
                guard loadError == nil else { openCodeReader = nil; return admitted }
                if var next = page.watermark { next.inode = inode; cursor = next }
                if page.rows < 512 { break }
            }
            if ledger.openCodeCursors?[key] != cursor || ledger.openCodePending?[key] != pending {
                if ledger.openCodeCursors == nil { ledger.openCodeCursors = [:] }
                if ledger.openCodePending == nil { ledger.openCodePending = [:] }
                ledger.openCodeCursors?[key] = cursor
                ledger.openCodePending?[key] = pending
                markMetadataDirty()
            }
            progress?(lastWork.openCodeRows, lastWork.openCodeRows)
        } catch {
            openCodeReader = nil
            errors.append("OpenCode usage could not be read: \(error.localizedDescription)")
        }
        return admitted
    }

    private func admit(openCode turn: OpenCodeUsage.Turn, historical: Bool) -> Bool {
        let fingerprint = Self.foreignIdentity(harness: OpenCodeUsage.harness, messageID: turn.messageID)
        guard let duplicate = identityKnown(fingerprint), duplicate == false else { return false }
        let boundary = Calendar.current.startOfDay(for: ledger.started)
        guard rebuilding || (historical ? turn.date < boundary : turn.date >= boundary) else { return false }
        var entry = Entry(date: turn.date, session: turn.session, model: turn.model, tokens: turn.tokens, account: nil)
        // The provider is whatever OpenCode routed to, which is not the tool.
        entry.provider = turn.provider
        entry.harness = OpenCodeUsage.harness
        entry.projectPath = turn.projectPath
        entry.turnID = turn.messageID
        entry.recordID = fingerprint
        entry.tokenFields = turn.tokenFields
        entry.pricingDay = UsageMetadata.day(turn.date)
        entry.firstObserved = turn.date
        entry.requestInputTokens = turn.tokenFields.contains("input_tokens") ? turn.tokens.input : nil
        entry.costMetadataVersion = 2
        persistAdmitted(entry, fingerprint: fingerprint, date: turn.date)
        return true
    }
}


/// Persisted with admitted usage. Failed or changing files never receive a checkpoint.
struct ClaudeFileCheck: Codable, Equatable {
    // Retry checkpoints written before rejected usage was reported as incomplete.
    var version = 2
    var size: UInt64
    var modified: Date
    var inode: UInt64
    static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return Self(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
}
