import Foundation

/// Usage coverage and execution failure are independent. Raw legacy messages
/// remain readable; unfamiliar diagnostics fail closed until classified here.
struct UsageDiagnostic: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case sessionChanged, sessionReplaced, unresolvedBoundary, legacyAliases
        case counterConflict, missingBaseline, readFailure
    }
    enum Scope: String, Codable { case live, history, provider }
    enum Recovery: String, Codable { case unresolved, resumed, unknown }
    var provider: String
    var scope: Scope
    var source: String?
    var kind: Kind
    var recovery: Recovery = .unknown
    var message: String
    var firstChecked: Date?
    var lastChecked: Date?
    var id: String { [provider, scope.rawValue, source ?? "", kind.rawValue, message].joined(separator: "|") }
    var isFailure: Bool { kind == .readFailure }
    var isContinuity: Bool {
        [.sessionChanged, .sessionReplaced, .unresolvedBoundary, .legacyAliases].contains(kind)
    }
    static func classify(_ message: String) -> Kind {
        if message == "Source was replaced by a different session; prior totals retained." { return .sessionReplaced }
        if message == "Source continuity is incomplete across a session change; prior totals retained." { return .sessionChanged }
        if message == "Source continuity is incomplete; retained prior totals and admitted only independently supported requests." { return .unresolvedBoundary }
        if message == "Multiple legacy cursor aliases required reconciliation; prior totals retained and coverage remains incomplete." { return .legacyAliases }
        if message == "Conflicting Claude counter revisions were retained without guessing a total." { return .counterConflict }
        if message == "Some older Claude messages lack retained counter baselines; their totals are preserved and increases cannot be reconciled." { return .missingBaseline }
        return .readFailure
    }
    static func decodeLegacy(scope: String, message: String) -> [UsageDiagnostic] {
        // Older snapshots joined scoped diagnostics with spaces. Recover those
        // boundaries before classifying; never treat a mixed failure as a gap.
        if scope == "Usage" || scope == "Saved history",
           let expression = try? NSRegularExpression(pattern: "Codex · (?:history|live) · ") {
            let matches = expression.matches(in: message, range: NSRange(message.startIndex..., in: message))
            if !matches.isEmpty {
                let text = message as NSString
                var result: [UsageDiagnostic] = []
                if matches[0].range.location > 0 {
                    result += decodeLegacy(scope: "Other sources", message: text.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                for index in matches.indices {
                    let start = matches[index].range.location
                    let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
                    let chunk = text.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let boundary = chunk.range(of: ": ") {
                        result += decodeLegacy(scope: String(chunk[..<boundary.lowerBound]), message: String(chunk[boundary.upperBound...]))
                    } else { result += decodeLegacy(scope: "Other sources", message: chunk) }
                }
                return result
            }
        }
        let parts = scope.components(separatedBy: " · ")
        let provider = parts.first ?? "Usage"
        let scanScope = parts.count >= 3 ? Scope(rawValue: parts[1]) ?? .provider : .provider
        let source = parts.count >= 3 ? parts.dropFirst(2).joined(separator: " · ") : nil
        return message.components(separatedBy: "\n").filter { !$0.isEmpty }.map { raw in
            let text = raw.hasPrefix(scope + ": ") ? String(raw.dropFirst(scope.count + 2)) : raw
            return UsageDiagnostic(provider: provider, scope: scanScope, source: source,
                                   kind: classify(text), message: text)
        }
    }
}

struct DiagnosticObservation: Codable, Equatable {
    var firstChecked: Date
    var lastChecked: Date
}

struct UsageReadHealth: Equatable {
    var diagnostics: [UsageDiagnostic] = []
    var lastSuccessfulRead: Date?
    var failed: Bool { diagnostics.contains(where: \.isFailure) }
    var partial: Bool { !diagnostics.isEmpty }
    var continuityCount: Int { diagnostics.filter(\.isContinuity).count }
    var affectedFiles: Int { Set(diagnostics.compactMap(\.source)).count }
    var failureCount: Int { diagnostics.filter(\.isFailure).count }
    var summary: String {
        let gaps = diagnostics.filter { !$0.isFailure }.count
        let coverageFiles = Set(diagnostics.filter { !$0.isFailure }.compactMap(\.source)).count
        let coverage = gaps == 0 ? "" : "\(gaps.formatted()) coverage warnings" +
            (coverageFiles > 0 ? " across \(coverageFiles.formatted()) source files" : "") + ". Available usage is retained."
        let failures = failureCount == 0 ? "" : "\(failureCount.formatted()) source read failures. Previous results are retained."
        return [failures, coverage].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Snapshot {
    var readHealth: UsageReadHealth {
        let issues = diagnostics ?? error.map { UsageDiagnostic.decodeLegacy(scope: "Usage", message: $0) } ?? []
        // Only legacy snapshots used updated as their completed-read clock.
        // Loading a typed snapshot must not fabricate a new successful read.
        let completed = successfulReadAt ?? (diagnostics == nil && !issues.contains(where: \.isFailure) ? updated : nil)
        return UsageReadHealth(diagnostics: issues, lastSuccessfulRead: completed)
    }
    var hasUsageResult: Bool { readHealth.lastSuccessfulRead != nil || !entries.isEmpty }
    mutating func recordFailure(_ message: String, provider: String) {
        successfulReadAt = readHealth.lastSuccessfulRead
        var issues = readHealth.diagnostics
        issues.append(UsageDiagnostic(provider: provider, scope: .provider, kind: .readFailure, message: message))
        diagnostics = issues
        error = [error, message].compactMap { $0 }.joined(separator: "\n")
    }
}

extension UsageScanner {
    var legacyDiagnosticText: String? {
        guard let sources = ledger.sourceErrors else { return ledger.historyError }
        return sources.isEmpty ? nil : sources.values.sorted().joined(separator: "\n")
    }
    /// Build presentation evidence without changing counters, cursors or admission.
    func readDiagnostics(now: Date? = nil) -> [UsageDiagnostic] {
        var sources = ledger.sourceErrors ?? [:]
        if ledger.sourceErrors == nil, let legacy = ledger.historyError { sources["Saved history"] = legacy }
        var issues = sources.keys.sorted().flatMap { key in
            UsageDiagnostic.decodeLegacy(scope: key, message: sources[key]!)
        }
        for index in issues.indices {
            if let source = issues[index].source {
                let cursor = issues[index].scope == .history ? ledger.historyCursors?[source] : ledger.cursors[source]
                if let cursor {
                    issues[index].recovery = cursor.reconciliation != nil ? .unresolved :
                        cursor.admittedBoundary != nil ? .resumed : .unknown
                }
            }
            let id = issues[index].id
            if let now {
                let old = ledger.diagnosticObservations?[id]
                let observation = DiagnosticObservation(firstChecked: old?.firstChecked ?? now, lastChecked: now)
                if ledger.diagnosticObservations == nil { ledger.diagnosticObservations = [:] }
                ledger.diagnosticObservations?[id] = observation
                // A repeated poll timestamp alone does not force a disk write.
                if old == nil { markMetadataDirty() }
            }
            issues[index].firstChecked = ledger.diagnosticObservations?[id]?.firstChecked
            issues[index].lastChecked = ledger.diagnosticObservations?[id]?.lastChecked
        }
        if let loadError { issues += UsageDiagnostic.decodeLegacy(scope: "Storage", message: loadError) }
        return issues
    }
}
