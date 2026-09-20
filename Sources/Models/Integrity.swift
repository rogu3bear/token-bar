import Foundation
import CryptoKit

/// A defect found in a record.
///
/// Two outcomes, chosen by what the defect actually threatens. A defect that
/// makes the whole record untrustworthy holds it out of the totals. A defect
/// confined to a subordinate field, where `input + output` is unaffected, is
/// repaired to the nearest consistent value and the record is still counted:
/// dropping real usage to avoid an inconsistent breakdown would make the total
/// wrong in order to keep a detail tidy.
///
/// Why a record was refused admission to the totals.
///
/// A refusal is never silent and never a deletion. The record is counted and
/// named so the interface can say how many were held back and why, which is the
/// difference between a number that is trustworthy and a number that is merely
/// confident.
enum IntegrityViolation: String, Codable, CaseIterable {
    case negativeCounter
    case cachedExceedsInput
    case reasoningExceedsOutput
    case emptyUsage
    case malformedIdentity
    case unboundIdentity
    case duplicateIdentity
    case implausibleDate
    case malformedProject
    case malformedLabel

    /// True when the defect is confined to a subordinate field and the record's
    /// own total is still sound.
    var isRepairable: Bool {
        switch self {
        case .cachedExceedsInput, .reasoningExceedsOutput: return true
        default: return false
        }
    }

    var explanation: String {
        switch self {
        case .negativeCounter: return "A token counter was negative, which cannot describe real usage."
        case .cachedExceedsInput: return "The tool reported more cached input than input. The record's total is unaffected, so it is counted with the cached figure reduced to the input it cannot exceed."
        case .reasoningExceedsOutput: return "The tool reported more reasoning tokens than output tokens. The record's total is unaffected, so it is counted with reasoning reduced to the output it cannot exceed."
        case .emptyUsage: return "The record claimed no tokens at all."
        case .malformedIdentity: return "The record had no usable identity, so it could not be deduplicated."
        case .unboundIdentity: return "The record's stored identity did not match the identity it was admitted under."
        case .duplicateIdentity: return "The same record was already counted."
        case .implausibleDate: return "The timestamp fell outside the range a real session can occupy."
        case .malformedProject: return "The working directory was not an absolute path."
        case .malformedLabel: return "A tool or provider name was empty or implausibly long."
        }
    }
}

/// The one gate every admitted record passes. Readers differ; this does not.
enum Integrity {
    /// Nothing before this could be a real local agent session.
    static let earliest = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 UTC
    /// A record may not claim to be from the future beyond ordinary clock skew.
    static let futureTolerance: TimeInterval = 86_400
    static let maximumLabel = 200

    /// Every violation an entry commits, in a stable order. Empty means the
    /// entry is admissible.
    static func violations(_ entry: Entry, fingerprint: String, now: Date = Date()) -> [IntegrityViolation] {
        var found: [IntegrityViolation] = []
        let tokens = entry.tokens
        if tokens.input < 0 || tokens.output < 0 || tokens.cached < 0
            || tokens.reasoning < 0 || (tokens.cacheWrite ?? 0) < 0 {
            found.append(.negativeCounter)
        }
        // The canonical form places cached inside input for every harness.
        if tokens.cached > tokens.input { found.append(.cachedExceedsInput) }
        if tokens.reasoning > tokens.output { found.append(.reasoningExceedsOutput) }
        if tokens.total <= 0 { found.append(.emptyUsage) }
        if fingerprint.count != EventIdentity.hexLength || fingerprint.contains(where: { !$0.isHexDigit }) {
            found.append(.malformedIdentity)
        }
        // The identity travelling with the record must be the identity it is
        // deduplicated under. Otherwise the archive and the ledger can disagree
        // about what was counted, which is how a total drifts unnoticed.
        if entry.recordID != fingerprint { found.append(.unboundIdentity) }
        if entry.date < earliest || entry.date > now.addingTimeInterval(futureTolerance) {
            found.append(.implausibleDate)
        }
        if let path = entry.projectPath, Project.path(path) == nil { found.append(.malformedProject) }
        for label in [entry.harness, entry.provider] {
            guard let label else { continue }
            if label.isEmpty || label.count > maximumLabel { found.append(.malformedLabel); break }
        }
        return found
    }
}

extension Integrity {
    /// Bring a record's subordinate fields back inside what its own totals allow.
    /// Only ever reduces a field; never invents or increases one.
    static func repair(_ entry: inout Entry, violations: [IntegrityViolation]) {
        for violation in violations where violation.isRepairable {
            switch violation {
            case .cachedExceedsInput: entry.tokens.cached = entry.tokens.input
            case .reasoningExceedsOutput: entry.tokens.reasoning = entry.tokens.output
            default: break
            }
        }
    }
}

/// What was held back, so the interface can report it rather than imply a clean
/// ledger. Counts only; no held record is ever shown as usage.
struct IntegrityReport: Codable, Equatable {
    var quarantined: [String: Int] = [:]
    /// Records counted after a subordinate field was brought back in range.
    var repaired: [String: Int] = [:]
    var total: Int { quarantined.values.reduce(0, +) }
    var repairedTotal: Int { repaired.values.reduce(0, +) }
    var isClean: Bool { total == 0 && repairedTotal == 0 }

    mutating func record(_ violations: [IntegrityViolation]) {
        // A record is counted once, under its most serious violation, so these
        // are records affected and not violations observed.
        guard let first = violations.first else { return }
        quarantined[first.rawValue, default: 0] += 1
    }

    mutating func recordRepair(_ violations: [IntegrityViolation]) {
        guard let first = violations.first(where: \.isRepairable) else { return }
        repaired[first.rawValue, default: 0] += 1
    }

    /// Plain sentences, most frequent first.
    var explanations: [String] {
        sentences(quarantined, prefix: "not counted") + sentences(repaired, prefix: "counted with a corrected detail")
    }

    private func sentences(_ counts: [String: Int], prefix: String) -> [String] {
        counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .compactMap { key, count in
                guard let violation = IntegrityViolation(rawValue: key) else { return nil }
                return "\(count.formatted()) \(prefix): " + violation.explanation
            }
    }
}

/// Ledger, quota, and checkpoint identity share one lowercase SHA-256 hex face.
/// A different encoding would make two copies of the same event look distinct.
enum EventIdentity {
    static let hexLength = 64
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}
