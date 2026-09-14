import Foundation

/// Metadata enrichment only: never replaces an unmatched usage total or its account observation.
enum CostRecovery {
    static func groupKey(_ e: Entry) -> String {
        "\(Calendar.current.startOfDay(for: e.date).timeIntervalSince1970)|\(e.session)|\(e.model)"
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
    static func reconcile(original: [Entry], reconstructed: [Entry]) -> (entries: [Entry], groups: Int, acceptedKeys: Set<String>) {
        let oldGroups = Dictionary(grouping: original, by: groupKey)
        let newGroups = Dictionary(grouping: reconstructed, by: groupKey)
        var replacements: [String: [Entry]] = [:]
        for (key, old) in oldGroups {
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
                    (basis.pricingDay == nil || basis.pricingDay == e.pricingDay) &&
                    Set(basis.tokenFields ?? []).isSubset(of: Set(e.tokenFields ?? []))
                }
                guard !other.isEmpty else { return false }
                let a = values.reduce(Tokens(["cache_write_input_tokens": 0])) { $0 + $1.tokens }, b = other.reduce(Tokens(["cache_write_input_tokens": 0])) { $0 + $1.tokens }
                let preservesWrites = basis.tokens.cacheWrite == nil ||
                    (other.allSatisfy { $0.tokens.cacheWrite != nil } && a.cacheWrite == b.cacheWrite)
                return a.input <= b.input && a.cached <= b.cached && a.output <= b.output && a.reasoning <= b.reasoning && preservesWrites
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
        let rebuilt: Snapshot = {
            let scratch = UsageScanner(home: home, stateURL: root.appendingPathComponent("ledger.json"), grokHome: grokHome)
            scratch.ledger.started = ledger.started
            scratch.rebuilding = true
            let result = scratch.scan(historical: true, otherTools: { phase?("Checking other tool cost details") }, progress: progress)
            rebuiltCursors = scratch.ledger.cursors
            rebuiltArchive = scratch.requestArchive
            return result
        }()
        guard rebuilt.error == nil else {
            throw NSError(domain: "TokenBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cost detail recovery could not read all source records. Original history is unchanged. " + (rebuilt.error ?? "")])
        }
        phase?("Matching cost details to saved usage")
        let recovered = CostRecovery.reconcile(original: ledger.entries, reconstructed: rebuilt.entries)
        var next = ledger
        next.entries = recovered.entries
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
        var summary = "Reconciled details for \(recovered.groups) day/task/model groups. \(missing) older records remain unchanged; missing details stay Unknown."
        next.costRecoverySummary = summary
        // Materialize the durable baseline plus matching metadata into one
        // self-contained rollback ledger; copying only the base loses cursors.
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("ledger-before-cost-" + UUID().uuidString + ".json")
            try JSONEncoder().encode(Self.loadLedger(from: stateURL)).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
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
