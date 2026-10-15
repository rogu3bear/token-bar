import Foundation

/// A proved counter interval. Its lower endpoint is not a claim that earlier
/// counters were admitted. Epochs are supplied by the source's continuity proof.
struct UsageExtent: Codable, Equatable {
    var lowerInput: Int
    var lowerOutput: Int
    var upperInput: Int
    var upperOutput: Int

    init?(lower: Tokens, upper: Tokens) {
        guard lower.input >= 0, lower.output >= 0,
              upper.input >= lower.input, upper.output >= lower.output else { return nil }
        lowerInput = lower.input; lowerOutput = lower.output
        upperInput = upper.input; upperOutput = upper.output
    }
    func contains(_ other: Self) -> Bool {
        lowerInput <= other.lowerInput && lowerOutput <= other.lowerOutput &&
        upperInput >= other.upperInput && upperOutput >= other.upperOutput
    }
    func precedes(_ other: Self) -> Bool {
        upperInput <= other.lowerInput && upperOutput <= other.lowerOutput
    }
    func joined(_ other: Self) -> Self? {
        if upperInput == other.lowerInput && upperOutput == other.lowerOutput {
            var result = self; result.upperInput = other.upperInput; result.upperOutput = other.upperOutput; return result
        }
        if other.upperInput == lowerInput && other.upperOutput == lowerOutput { return other.joined(self) }
        return nil
    }
}

/// Optional ledger metadata: legacy cursors are never promoted to admitted
/// ranges. Receipts remain authoritative when an old range cannot be recovered.
struct AdmittedUsageCoverage: Codable, Equatable {
    var provider: String
    var observed: Tokens?
    var admittedCounters: Tokens?
    var admitted: [UsageExtent] = []
    var unresolved = false

    init(provider: String) { self.provider = provider }
    private enum CodingKeys: String, CodingKey { case provider, observed, admittedCounters, admitted, unresolved }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        observed = try values.decodeIfPresent(Tokens.self, forKey: .observed)
        admittedCounters = try values.decodeIfPresent(Tokens.self, forKey: .admittedCounters)
        admitted = try values.decode([UsageExtent].self, forKey: .admitted)
        unresolved = try values.decode(Bool.self, forKey: .unresolved)
        guard !provider.isEmpty, provider.count <= 200, admitted.allSatisfy({
            $0.lowerInput >= 0 && $0.lowerOutput >= 0 && $0.upperInput >= $0.lowerInput && $0.upperOutput >= $0.lowerOutput
        }), admittedCounters.map({ $0.input >= 0 && $0.output >= 0 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .admitted, in: values, debugDescription: "Invalid admitted counter coverage")
        }
        let ordered = admitted.sorted { ($0.lowerInput, $0.lowerOutput) < ($1.lowerInput, $1.lowerOutput) }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.precedes($1) }) else {
            throw DecodingError.dataCorruptedError(forKey: .admitted, in: values, debugDescription: "Overlapping admitted counter coverage")
        }
    }

    mutating func insert(_ extent: UsageExtent) {
        var merged = extent
        var remaining = admitted
        var index = 0
        while index < remaining.count {
            if let joined = merged.joined(remaining[index]) {
                merged = joined; remaining.remove(at: index); index = 0
            } else { index += 1 }
        }
        remaining.append(merged)
        admitted = remaining.sorted { ($0.lowerInput, $0.lowerOutput) < ($1.lowerInput, $1.lowerOutput) }
    }
}

struct UsageEvidence {
    var source: String
    var epoch: String = "initial"
    var provider: String
    var counters: Tokens
    var delta: Tokens
    var extent: UsageExtent?
    var fingerprint: String
    var key: String { EventIdentity.hash(source + "|" + epoch) }
}

enum UsageAdmission {
    case new(UsageEvidence)
    case covered(receipt: Bool)
    case unresolved
    var evidence: UsageEvidence? { if case .new(let value) = self { return value }; return nil }
}

extension UsageScanner {
    /// The only novelty decision. Reader positions select evidence; neither an
    /// unseen receipt nor a cumulative high-water mark proves an uncovered range.
    func assessUsage(_ evidence: UsageEvidence) -> UsageAdmission {
        guard let known = identityKnown(evidence.fingerprint) else { return .unresolved }
        var coverage = ledger.usageCoverage?[evidence.key] ?? AdmittedUsageCoverage(provider: evidence.provider)
        coverage.observed = evidence.counters
        defer {
            if ledger.usageCoverage?[evidence.key] != coverage {
                if ledger.usageCoverage == nil { ledger.usageCoverage = [:] }
                ledger.usageCoverage?[evidence.key] = coverage
                markMetadataDirty()
            }
        }
        if known { return .covered(receipt: true) }
        guard evidence.delta.total > 0 else { return .covered(receipt: false) }
        if let extent = evidence.extent {
            if coverage.admitted.contains(where: { $0.contains(extent) }) { return .covered(receipt: false) }
            if coverage.admitted.contains(where: { !$0.precedes(extent) && !extent.precedes($0) }) {
                coverage.unresolved = true
                return .unresolved
            }
        }
        // An independently identified request may lack cumulative endpoints.
        // OpenCode's once-per-message contract deliberately uses this case.
        return .new(evidence)
    }

    func recordCoverage(_ evidence: UsageEvidence) {
        var coverage = ledger.usageCoverage?[evidence.key] ?? AdmittedUsageCoverage(provider: evidence.provider)
        coverage.observed = evidence.counters
        if evidence.counters.input >= 0, evidence.counters.output >= 0,
           coverage.admittedCounters == nil || (evidence.counters.input >= coverage.admittedCounters!.input && evidence.counters.output >= coverage.admittedCounters!.output) {
            coverage.admittedCounters = evidence.counters
        }
        if let extent = evidence.extent { coverage.insert(extent) }
        if ledger.usageCoverage == nil { ledger.usageCoverage = [:] }
        ledger.usageCoverage?[evidence.key] = coverage
    }

    /// Provider counter evidence for an ordinary cumulative tail or an explicit
    /// last request at startup/reset. This never seeds coverage from `previous`.
    static func cumulativeEvidence(source: String, provider: String, total: Tokens, previous: Tokens?,
                                   last: Tokens?, fingerprint: String, epoch: inout String?) -> UsageEvidence {
        let delta: Tokens
        let lower: Tokens?
        if let previous, total.input >= previous.input, total.output >= previous.output {
            delta = total.delta(from: previous); lower = previous
        } else {
            if previous != nil { epoch = fingerprint }
            delta = last ?? Tokens()
            lower = total.input >= delta.input && total.output >= delta.output ? total.delta(from: delta) : nil
        }
        return UsageEvidence(source: source, epoch: epoch ?? "initial", provider: provider, counters: total,
            delta: delta, extent: lower.flatMap { UsageExtent(lower: $0, upper: total) }, fingerprint: fingerprint)
    }
}

// Source-specific recovery witnesses remain explicit. They establish a candidate
// interval; assessUsage alone decides whether that interval is uncovered.
extension UsageScanner {
    func codexEvidence(total: Tokens, last: Tokens?, rawLast: [String: Any]?, fingerprint: String,
                       session: String, date: Date, poll: Date, continuous: Bool, cursor: inout Cursor)
        -> (evidence: UsageEvidence, reconciling: Bool, resumed: Bool) {
        let reconciling = cursor.reconciliation != nil
        let recoveredBoundary = cursor.reconciliation.map { recovery in
            let matches = recovery.fingerprint.map { $0 == fingerprint && recovery.session == cursor.sourceSession } ??
                ((ledger.eventIDs?.contains(fingerprint) == true || eventIndex?.contains(fingerprint) == true))
            return matches && (recovery.session == nil || recovery.session == cursor.sourceSession) && recovery.previous == total &&
                (recovery.covered.map { total.input >= $0.total.input && total.output >= $0.total.output && date >= $0.date } ?? true)
        } ?? false
        if recoveredBoundary { cursor.reconciliation = nil }
        var resumedAtVerifiedBoundary = false
        let delta: Tokens
        if reconciling {
            // A replayed earlier snapshot is not a safe cumulative baseline:
            // A100/B200 admitted, then A100/C300 must add only C's last100.
            let complete = rawLast?["input_tokens"] as? Int != nil && rawLast?["output_tokens"] as? Int != nil
            let covered = cursor.reconciliation?.covered ?? cursor.admittedBoundary
            let disjoint = covered.map { old in
                guard old.session != nil, old.session == cursor.sourceSession, let last else { return false }
                return date >= old.date && last.input >= 0 && last.output >= 0 &&
                    total.input >= last.input && total.output >= last.output &&
                    total.input - last.input >= old.total.input && total.output - last.output >= old.total.output
            } ?? (cursor.reconciliation == nil)
            let legacyFloor = cursor.reconciliation?.legacy == true ? cursor.reconciliation?.previous : nil
            let beyondLegacy = legacyFloor.map { floor in
                guard let last else { return false }
                return total.input >= last.input && total.output >= last.output &&
                    total.input - last.input >= floor.input && total.output - last.output >= floor.output
            } ?? true
            // If the old anchor is gone, a later dated request on a verified
            // append can establish a new boundary without erasing the old gap.
            resumedAtVerifiedBoundary = cursor.reconciliation?.resume.map { observed in
                guard let verifiedAt = observed.verifiedAt, let last,
                      observed.session != nil, observed.session == cursor.sourceSession else { return false }
                return continuous && date > verifiedAt && date <= poll && date > observed.date &&
                    last.input >= 0 && last.output >= 0 && total.input >= last.input && total.output >= last.output &&
                    total.input - last.input >= observed.total.input && total.output - last.output >= observed.total.output &&
                    (covered.map { date >= $0.date } ?? true)
            } ?? false
            delta = complete && ((disjoint && beyondLegacy) || resumedAtVerifiedBoundary) ? (last ?? Tokens()) : Tokens()
        } else {
            let evidence = Self.cumulativeEvidence(source: "codex|" + (cursor.sourceSession ?? session), provider: "Codex",
                total: total, previous: cursor.previous, last: last, fingerprint: fingerprint, epoch: &cursor.usageEpoch)
            return (evidence, reconciling, false)
        }
        let lower = total.input >= delta.input && total.output >= delta.output ? total.delta(from: delta) : nil
        let evidence = UsageEvidence(source: "codex|" + (cursor.sourceSession ?? session), epoch: cursor.usageEpoch ?? "initial",
            provider: "Codex", counters: total, delta: delta,
            extent: lower.flatMap { UsageExtent(lower: $0, upper: total) }, fingerprint: fingerprint)
        return (evidence, reconciling, resumedAtVerifiedBoundary)
    }
}

extension UsageScanner {
    func assessClaude(_ turn: ClaudeCodeUsage.Turn, baseID: String, errors: inout [String])
        -> (admission: UsageAdmission, revision: Bool) {
        var previous = ledger.usageCoverage?[EventIdentity.hash("Claude Code|" + baseID + "|initial")]?.admittedCounters ?? ledger.claudeCounters?[baseID]
        if previous == nil {
            guard let known = identityKnown(baseID) else { return (.unresolved, previous != nil) }
            if known {
                do {
                    let retained = try requestArchive?.entry(id: baseID) ?? ledger.entries.first { $0.recordID == baseID }
                    if let retained, retained.recordID == baseID, retained.harness == ClaudeCodeUsage.harness,
                       retained.provider == ClaudeCodeUsage.provider, retained.session == turn.session, retained.model == turn.model {
                        previous = retained.tokens
                    }
                } catch { errors.append("A retained Claude counter baseline could not be read."); return (.unresolved, previous != nil) }
                guard previous != nil else {
                    errors.append("Some older Claude messages lack retained counter baselines; their totals are preserved and increases cannot be reconciled.")
                    return (.unresolved, previous != nil)
                }
            }
        }
        let baseline = previous ?? Tokens()
        guard ClaudeCodeUsage.components(baseline).allSatisfy({ $0 >= 0 }) else {
            errors.append("A retained Claude counter baseline is inconsistent; its total was preserved.")
            return (.unresolved, previous != nil)
        }
        guard ClaudeCodeUsage.dominates(turn.tokens, baseline) else {
            if !ClaudeCodeUsage.dominates(baseline, turn.tokens) {
                if rebuilding {
                    costRecoveryExcludedSessions.insert("anthropic|" + turn.session)
                    if let prior = try? requestArchive?.entry(id: baseID) {
                        costRecoveryExcludedSessions.insert("anthropic|" + prior.session)
                    }
                }
                errors.append("Conflicting Claude counter revisions were retained without guessing a total.")
            }
            return (ClaudeCodeUsage.dominates(baseline, turn.tokens) ? .covered(receipt: false) : .unresolved, previous != nil)
        }
        let delta = previous == nil ? turn.tokens : ClaudeCodeUsage.increment(turn.tokens, over: baseline)
        let fingerprint = previous == nil ? baseID : Self.foreignIdentity(harness: "Claude Code revision", messageID:
            baseID + "|" + ClaudeCodeUsage.components(turn.tokens).map(String.init).joined(separator: ":"))
        let evidence = UsageEvidence(source: "Claude Code|" + baseID, provider: "Claude",
            counters: turn.tokens, delta: delta, extent: UsageExtent(lower: baseline, upper: turn.tokens), fingerprint: fingerprint)
        return (assessUsage(evidence), previous != nil)
    }
}

extension UsageScanner {
    /// Turn counters are disjoint observations. When the session endpoints can
    /// locate them exactly, they share coverage with cumulative observations.
    /// A source lacking those endpoints retains independent receipt admission.
    static func grokExtents(_ turns: [[String: Any]], total: Tokens) -> [UsageExtent?] {
        var result = Array<UsageExtent?>(repeating: nil, count: turns.count)
        var upper = total
        for index in turns.indices.reversed() {
            let tokens = GrokUsage.tokens(turns[index]).0
            guard tokens.input >= 0, tokens.output >= 0,
                  upper.input >= tokens.input, upper.output >= tokens.output else {
                return Array(repeating: nil, count: turns.count)
            }
            var lower = Tokens(); lower.input = upper.input - tokens.input; lower.output = upper.output - tokens.output
            result[index] = UsageExtent(lower: lower, upper: upper)
            upper = lower
        }
        return result
    }
}
