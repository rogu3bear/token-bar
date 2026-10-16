import Foundation

/// Metadata enrichment only: never replaces an unmatched usage total or its account observation.
enum CostRecovery {
    static func groupKey(_ e: Entry) -> String {
        "\(LedgerDay.key(e.date))|\(e.session)|\(e.model)"
    }
    static func sameUsage(_ a: Tokens, _ b: Tokens) -> Bool {
        a.input == b.input && a.cached == b.cached && a.output == b.output && a.reasoning == b.reasoning
    }
    static func enrichCursor(_ old: Cursor, from fresh: Cursor) -> Cursor {
        guard old.offset == fresh.offset, old.model == fresh.model, old.turnID == fresh.turnID,
              let previous = old.previous, let latest = fresh.previous, sameUsage(previous, latest),
              old.provider == nil || old.provider == fresh.provider,
              old.effort == nil || old.effort == fresh.effort,
              old.requestedService == nil || old.requestedService == fresh.requestedService,
              old.previousTicks == nil || old.previousTicks == fresh.previousTicks,
              previous.cacheWrite == nil || previous.cacheWrite == latest.cacheWrite else { return old }
        var result = old
        result.previousFields = fresh.previousFields; result.requestedService = fresh.requestedService
        result.provider = fresh.provider; result.effort = fresh.effort; result.previous?.cacheWrite = latest.cacheWrite
        result.previousTicks = fresh.previousTicks
        return result
    }
    static func reconcile(original: [Entry], reconstructed: [Entry], providers: Set<String>? = nil) -> (entries: [Entry], groups: Int, acceptedKeys: Set<String>) {
        let oldGroups = Dictionary(grouping: original, by: groupKey)
        let newGroups = Dictionary(grouping: reconstructed, by: groupKey)
        var replacements: [String: [Entry]] = [:]
        for (key, old) in oldGroups {
            if let providers, !old.allSatisfy({ providers.contains($0.provider ?? "") }) { continue }
            guard let fresh = newGroups[key],
                  sameUsage(old.reduce(Tokens()) { $0 + $1.tokens }, fresh.reduce(Tokens()) { $0 + $1.tokens }),
                  old.reduce(0, { $0 + $1.eventCount }) == fresh.reduce(0, { $0 + $1.eventCount }) else { continue }
            // Do not spread a partial account attribution across a whole day.
            guard let first = old.first, old.allSatisfy({ $0.account == first.account }) else { continue }
            // A source rewrite must not remove metadata already admitted by this version.
            let known = old.filter { $0.costMetadataVersion != nil || $0.tokens.cacheWrite != nil }
            let knownGroups = Dictionary(grouping: known, by: metadataKey)
            let preservesKnown = knownGroups.allSatisfy { _, values in
                guard let basis = values.first else { return false }
                let other = fresh.filter { e in
                    (basis.provider == nil || e.provider == basis.provider) && (basis.effort == nil || e.effort == basis.effort) &&
                    (basis.contextBand == nil || e.contextBand == basis.contextBand) && (basis.tokens.cacheWrite == nil || e.tokens.cacheWrite != nil) &&
                    (basis.observedService == nil || basis.observedService == e.observedService) &&
                    (basis.requestedService == nil || basis.requestedService == e.requestedService) &&
                    (basis.observedSpeed == nil || basis.observedSpeed == e.observedSpeed) &&
                    (basis.costIsPartial == nil || basis.costIsPartial == e.costIsPartial) &&
                    (basis.costUsdTicks == nil || e.costUsdTicks != nil) &&
                    (basis.pricingDay == nil || basis.pricingDay == e.pricingDay) &&
                    Set(basis.tokenFields ?? []).isSubset(of: Set(e.tokenFields ?? []))
                }
                guard !other.isEmpty else { return false }
                let a = sum(values), b = sum(other)
                let preservesWrites = basis.tokens.cacheWrite == nil ||
                    (other.allSatisfy { $0.tokens.cacheWrite != nil } && a.cacheWrite == b.cacheWrite)
                return a.input <= b.input && a.cached <= b.cached && a.output <= b.output && a.reasoning <= b.reasoning && preservesWrites &&
                    (basis.tokens.cacheWrite5m == nil || (other.allSatisfy { $0.tokens.cacheWrite5m != nil } && a.cacheWrite5m == b.cacheWrite5m)) &&
                    (basis.tokens.cacheWrite1h == nil || (other.allSatisfy { $0.tokens.cacheWrite1h != nil } && a.cacheWrite1h == b.cacheWrite1h)) &&
                    (basis.tokens.thinking == nil || (other.allSatisfy { $0.tokens.thinking != nil } && a.thinking == b.thinking)) &&
                    (basis.costUsdTicks == nil || values.reduce(Decimal(0)) { $0 + Decimal($1.costUsdTicks ?? 0) } == other.reduce(Decimal(0)) { $0 + Decimal($1.costUsdTicks ?? 0) })
            }
            guard preservesKnown else { continue }
            replacements[key] = fresh.map { item in var e = item; e.account = first.account; return e }
        }
        var emitted = Set<String>(), result: [Entry] = []
        for entry in original {
            let key = groupKey(entry)
            if let replacement = replacements[key] {
                if emitted.insert(key).inserted { result.append(contentsOf: replacement) }
            } else { result.append(entry) }
        }
        return (result, replacements.count, Set(replacements.keys))
    }
    static func sum(_ entries: [Entry]) -> Tokens {
        guard let first = entries.first else { return Tokens() }
        return entries.dropFirst().reduce(first.tokens) { $0 + $1.tokens }
    }
    private static func metadataKey(_ e: Entry) -> String {
        "\(e.provider ?? "unknown")|\(e.effort ?? "unknown")|\(e.contextBand ?? "unknown")|\(e.tokens.cacheWrite == nil ? "unknown" : "known")|\(UsageMetadata.aggregationKey(e))"
    }
}
extension UsageScanner {
    func recoverCostDetails(progress: ((Int, Int) -> Void)? = nil, phase: ((String) -> Void)? = nil) throws -> String {
        if let loadError { throw NSError(domain: "TokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        // Recovery must not bypass an unsettled durable usage checkpoint.
        try saveIfNeeded(force: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-cost-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var rebuiltCursors: [String: Cursor] = [:]
        var rebuiltArchive: RequestArchive?
        var rebuiltClaudeCounters: [String: Tokens] = [:]
        var rebuilt: Snapshot = {
            let scratch = UsageScanner(home: home, stateURL: root.appendingPathComponent("ledger.json"), grokHome: grokHome, claudeHome: claudeHome, openCodeHome: openCodeHome)
            scratch.ledger.started = ledger.started
            scratch.rebuilding = true
            let result = scratch.scan(historical: true, otherTools: { phase?("Checking other tool cost details") }, progress: progress)
            rebuiltClaudeCounters = scratch.ledger.claudeCounters ?? [:]
            rebuiltCursors = scratch.ledger.cursors
            rebuiltArchive = scratch.requestArchive
            return result
        }()
        // Unrelated Codex read failures must not suppress independently readable
        // Claude/Grok metadata. A separate pass contains no Codex/OpenCode source;
        // exact group reconciliation still owns every accepted replacement.
        var partialRecovery = false
        var excludedSessions = Set<String>()
        if rebuilt.error != nil, claudeHome != nil || grokHome != nil {
            let isolated = root.appendingPathComponent("provider-recovery")
            try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
            let emptyHome = isolated.appendingPathComponent("no-codex-source")
            try FileManager.default.createDirectory(at: emptyHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            let scratch = UsageScanner(home: emptyHome, stateURL: isolated.appendingPathComponent("ledger.json"),
                grokHome: grokHome, claudeHome: claudeHome)
            scratch.ledger.started = ledger.started; scratch.rebuilding = true
            let providers = scratch.scan(historical: true, progress: progress)
            let identifiedConflictsOnly = !scratch.costRecoveryExcludedSessions.isEmpty &&
                (scratch.ledger.sourceErrors ?? [:]).allSatisfy { key, value in
                    key == "Claude" && value.components(separatedBy: "\n").allSatisfy {
                        $0 == "Conflicting Claude counter revisions were retained without guessing a total."
                    }
                }
            if (providers.error == nil || identifiedConflictsOnly), !providers.entries.isEmpty {
                rebuilt = providers; rebuiltCursors = [:]; rebuiltArchive = scratch.requestArchive
                rebuiltClaudeCounters = identifiedConflictsOnly ? [:] : scratch.ledger.claudeCounters ?? [:]
                excludedSessions = scratch.costRecoveryExcludedSessions
                partialRecovery = true
            }
        }
        guard rebuilt.error == nil || partialRecovery else {
            throw NSError(domain: "TokenBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cost detail recovery could not read all source records. Original history is unchanged. " + (rebuilt.error ?? "")])
        }
        phase?("Matching cost details to saved usage")
        let candidates = rebuilt.entries.filter { !excludedSessions.contains(($0.provider ?? "unknown") + "|" + $0.session) }
        let recovered = CostRecovery.reconcile(original: ledger.entries, reconstructed: candidates,
            providers: partialRecovery ? ["anthropic", "xai"] : nil)
        var next = ledger
        next.entries = recovered.entries
        // Metadata at the same provider/message counter boundary may enrich a
        // Claude revision baseline without adding usage or advancing a cursor.
        for (key, fresh) in rebuiltClaudeCounters {
            let coverageKey = EventIdentity.hash("Claude Code|" + key + "|initial")
            guard var old = next.usageCoverage?[coverageKey]?.admittedCounters ?? next.claudeCounters?[key], CostRecovery.sameUsage(old, fresh),
                  old.cacheWrite == fresh.cacheWrite,
                  old.cacheWrite5m == nil || old.cacheWrite5m == fresh.cacheWrite5m,
                  old.cacheWrite1h == nil || old.cacheWrite1h == fresh.cacheWrite1h,
                  old.thinking == nil || old.thinking == fresh.thinking else { continue }
            old.cacheWrite5m = fresh.cacheWrite5m; old.cacheWrite1h = fresh.cacheWrite1h; old.thinking = fresh.thinking
            if next.claudeCounters?[key] != nil { next.claudeCounters?[key] = old }
            if let retained = next.usageCoverage?[coverageKey]?.admittedCounters,
               CostRecovery.sameUsage(retained, old), retained.cacheWrite == old.cacheWrite,
               retained.cacheWrite5m == nil || retained.cacheWrite5m == old.cacheWrite5m,
               retained.cacheWrite1h == nil || retained.cacheWrite1h == old.cacheWrite1h,
               retained.thinking == nil || retained.thinking == old.thinking {
                next.usageCoverage?[coverageKey]?.admittedCounters = old
            }
        }
        // Old persisted cursors start at EOF and would otherwise never see session metadata.
        // Enrich only at the identical source offset and counter boundary; never advance a cursor.
        var liveCursors = next.cursors
        var historyCursors = next.historyCursors ?? [:]
        for (key, fresh) in rebuiltCursors {
            if let old = liveCursors[key] { liveCursors[key] = CostRecovery.enrichCursor(old, from: fresh) }
            if let old = historyCursors[key] { historyCursors[key] = CostRecovery.enrichCursor(old, from: fresh) }
        }
        next.cursors = liveCursors; next.historyCursors = historyCursors
        next.costMetadataVersion = 2
        let missing = next.entries.filter { ($0.costMetadataVersion ?? 0) < 2 }.reduce(0) { $0 + $1.eventCount }
        var summary = (partialRecovery ? "Claude/Grok recovery only; other source failures leave those groups unchanged. " : "") + (excludedSessions.isEmpty ? "" : "Preserved \(excludedSessions.count) conflicting source sessions without enrichment. ") + "Reconciled details for \(recovered.groups) day/task/model groups. \(missing) older records remain unchanged; missing details stay Unknown."
        next.costRecoverySummary = summary
        // Materialize the durable baseline plus matching metadata into one
        // self-contained rollback ledger; copying only the base loses cursors.
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("ledger-before-cost-" + UUID().uuidString + ".json")
            try PrivateCache.write(Self.loadLedger(from: stateURL), to: backup)
        }
        if let rebuiltArchive, let requestArchive {
            let accounts = Dictionary(next.entries.compactMap { e in e.account.map { (CostRecovery.groupKey(e), $0) } }, uniquingKeysWith: { a, _ in a })
            let excluded = try requestArchive.importAccepted(from: rebuiltArchive, groups: recovered.acceptedKeys, accounts: accounts)
            if excluded > 0 { summary += " Request archive kept \(excluded) groups unchanged because their event identities or retained details differ." }
            next.costRecoverySummary = summary
        }
        ledger = next
        rebuildHistoricalIndex()
        markDirty()
        try saveIfNeeded(force: true)
        return summary
    }
}
