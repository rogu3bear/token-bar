import Foundation
import CryptoKit

struct QuotaGuardPolicy: Codable, Equatable {
    var lowPercent: Double = 10
    var leadMinutes: Double = 30
    static let freshness: TimeInterval = 120
    static let maximumGap: TimeInterval = 120
    static let resetJitter: TimeInterval = 60
    static let escalationPercent = 5.0
    static let escalationLead: TimeInterval = 600
    static let confirmations = 2
    static let recoveryMargin = 3.0
    static let recoveryLead: TimeInterval = 300
    static let snooze: TimeInterval = 1800
    static let retention: TimeInterval = 35 * 86400
    static let capacity = 256
    static let retryDelay: TimeInterval = 60
    static let maximumAttempts = 2
    var valid: Bool { lowPercent.isFinite && (5...50).contains(lowPercent) && leadMinutes.isFinite && (10...120).contains(leadMinutes) }
}
enum QuotaEvidence: String, Codable { case current, insufficient, stale, unavailable, invalid }
enum QuotaRisk: String, Codable { case none, low, projectedExhaustion, observedExhaustion }
enum QuotaReason: String, Codable {
    case fresh, learning, flat, gap, adjustment, duplicate, outOfOrder, future, invalidValue
    case expiredReset, identityMismatch, sourceUnavailable, providerError, restored, stale, unsupportedSource
    var label: String {
        switch self {
        case .fresh: return "Fresh account observation"
        case .learning: return "Forecast needs 2+ minutes of distinct observations"
        case .flat: return "No positive quota burn observed"
        case .gap: return "Forecast paused after a gap over 2 minutes"
        case .adjustment: return "Forecast paused after a quota or reset adjustment"
        case .duplicate: return "Conflicting readings at one source time"
        case .outOfOrder: return "Out-of-order source observation"
        case .future: return "Source observation is in the future"
        case .invalidValue: return "Invalid quota observation"
        case .expiredReset: return "Reset passed; awaiting a new observation"
        case .identityMismatch: return "Account identity does not match"
        case .sourceUnavailable: return "No supported account quota available"
        case .providerError: return "Provider refresh failed"
        case .restored: return "Awaiting a successful quota refresh"
        case .stale: return "Too old for Quota Guard (2-minute maximum)"
        case .unsupportedSource: return "This source cannot authenticate quota"
        }
    }
}
/// Explicit adapter evidence; display readings retain their existing horizons.
struct QuotaGuardInput {
    var tool: LiveTool
    var accountID: String?
    var readings: [QuotaReading]
    var samples: [QuotaReading]
    var horizon: TimeInterval = 120
    var authenticated = false
    var failed = false
    var relay = false
}
struct QuotaGuardDecision: Identifiable, Equatable, Codable {
    var tool: LiveTool
    var accountID: String
    var reading: QuotaReading?
    var evidence: QuotaEvidence
    var reason: QuotaReason
    var risk: QuotaRisk = .none
    var remaining: Double?
    var forecast: Date?
    var evaluated: Date
    var id: String { Self.key(tool, accountID, reading?.bucket ?? "", reading?.window ?? "") }
    static func key(_ tool: LiveTool, _ account: String, _ bucket: String, _ window: String) -> String {
        let data = try! JSONEncoder().encode([tool.rawValue, account, bucket, window])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var windowLabel: String {
        guard let r = reading else { return "Account allowance" }
        return r.minutes % 1440 == 0 ? "\(r.minutes / 1440)-day" : r.minutes % 60 == 0 ? "\(r.minutes / 60)-hour" : "\(r.minutes)-minute"
    }
    var title: String { tool.label + " · " + windowLabel + (reading.map { " · " + $0.name } ?? "") }
    var riskLabel: String {
        switch risk {
        case .none: return evidence == .current ? "No warning" : "Assessment unavailable"
        case .low: return "Low allowance"
        case .projectedExhaustion: return "Projected exhaustion"
        case .observedExhaustion: return "Observed exhaustion"
        }
    }
    var level: Int {
        guard risk != .none else { return 0 }
        if risk == .observedExhaustion { return 3 }
        return (remaining ?? 100) <= QuotaGuardPolicy.escalationPercent || forecast.map { $0.timeIntervalSince(evaluated) <= QuotaGuardPolicy.escalationLead } == true ? 2 : 1
    }
}
enum QuotaGuardEvaluator {
    static func evaluate(_ input: QuotaGuardInput, now: Date, policy: QuotaGuardPolicy) -> [QuotaGuardDecision] {
        if input.readings.isEmpty {
            return [QuotaGuardDecision(tool: input.tool, accountID: input.accountID ?? "", evidence: .unavailable,
                                       reason: input.failed ? .providerError : .sourceUnavailable, evaluated: now)]
        }
        return input.readings.map { reading in
            var d = QuotaGuardDecision(tool: input.tool, accountID: reading.accountID, reading: reading,
                                       evidence: .current, reason: .fresh, evaluated: now)
            func reject(_ evidence: QuotaEvidence, _ reason: QuotaReason) -> QuotaGuardDecision {
                d.evidence = evidence; d.reason = reason; return d
            }
            guard policy.valid, now.timeIntervalSince1970.isFinite, reading.used.isFinite,
                  (0...100).contains(reading.used), reading.minutes > 0,
                  reading.date.timeIntervalSince1970.isFinite else { return reject(.invalid, .invalidValue) }
            guard !input.relay else { return reject(.unavailable, .unsupportedSource) }
            guard !reading.bucket.isEmpty, !reading.window.isEmpty else { return reject(.invalid, .invalidValue) }
            guard !reading.accountID.isEmpty, input.accountID == reading.accountID else { return reject(.invalid, .identityMismatch) }
            guard !input.failed else { return reject(.unavailable, .providerError) }
            guard input.authenticated else { return reject(.insufficient, .restored) }
            guard reading.date <= now else { return reject(.invalid, .future) }
            if let reset = reading.reset {
                guard reset.timeIntervalSince1970.isFinite else { return reject(.invalid, .invalidValue) }
                guard reset > now else { return reject(.unavailable, .expiredReset) }
            }
            guard input.horizon.isFinite, input.horizon > 0,
                  now.timeIntervalSince(reading.date) < min(input.horizon, QuotaGuardPolicy.freshness) else { return reject(.stale, .stale) }
            d.remaining = 100 - reading.used
            if reading.used == 100 { d.risk = .observedExhaustion; return d }
            if reading.reset == nil { return d }
            if d.remaining! <= policy.lowPercent { d.risk = .low }
            func sameAllowance(_ value: QuotaReading) -> Bool {
                value.accountID == reading.accountID && value.bucket == reading.bucket && value.window == reading.window
            }
            if input.samples.contains(where: { sameAllowance($0) && (!$0.date.timeIntervalSince1970.isFinite || !$0.used.isFinite || !(0...100).contains($0.used) || $0.date > reading.date) }) {
                d.evidence = .insufficient; d.reason = .invalidValue; return d
            }
            let history = input.samples.filter { sameAllowance($0) && $0.date >= reading.date.addingTimeInterval(-Runway.lookback) }
            var segment: [QuotaReading] = []
            var reason: QuotaReason = .learning
            for sample in history + [reading] {
                guard sample.used.isFinite, (0...100).contains(sample.used), sample.date.timeIntervalSince1970.isFinite,
                      sample.reset != nil, sample.date <= reading.date else {
                    segment = []; reason = .invalidValue; continue
                }
                guard sample.reset == reading.reset else { segment = []; reason = .adjustment; continue }
                if let last = segment.last {
                    if sample.date == last.date {
                        if sample != last { segment = []; reason = .duplicate }
                        continue
                    }
                    if sample.date < last.date { segment = []; reason = .outOfOrder; continue }
                    else if sample.used < last.used { segment = []; reason = .adjustment }
                    else if sample.date.timeIntervalSince(last.date) > QuotaGuardPolicy.maximumGap { segment = []; reason = .gap }
                }
                segment.append(sample)
            }
            guard let first = segment.first, reading.date.timeIntervalSince(first.date) >= 120 else {
                d.evidence = .insufficient; d.reason = reason; return d
            }
            // One canonical burn formula. Qualification above never parses Runway copy.
            let runway = Runway.estimate(reading, samples: segment, now: now,
                                         horizon: min(input.horizon, QuotaGuardPolicy.freshness))
            d.reason = runway.percentPerHour == 0 ? .flat : .fresh
            d.forecast = runway.exhaustion
            if let forecast = d.forecast, let reset = reading.reset, forecast < reset,
               forecast.timeIntervalSince(now) <= policy.leadMinutes * 60 { d.risk = .projectedExhaustion }
            return d
        }
    }
    static func prioritized(_ decisions: [QuotaGuardDecision]) -> [QuotaGuardDecision] {
        decisions.sorted {
            if ($0.risk == .observedExhaustion) != ($1.risk == .observedExhaustion) { return $0.risk == .observedExhaustion }
            if $0.forecast != $1.forecast { return ($0.forecast ?? .distantFuture) < ($1.forecast ?? .distantFuture) }
            if ($0.risk != .none) != ($1.risk != .none) { return $0.risk != .none }
            if $0.remaining != $1.remaining { return ($0.remaining ?? 101) < ($1.remaining ?? 101) }
            return $0.id < $1.id
        }
    }
}
