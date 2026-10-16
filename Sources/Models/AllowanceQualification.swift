import Foundation

/// Shared eligibility for a current allowance number. Historical observations
/// and arithmetic helpers do not carry this permission. Adapters supply the
/// account/authentication witnesses; receipt time cannot authenticate a relay.
enum AllowanceRejection: String {
    case invalidValue, unsupportedSource, identityMismatch, providerError, restored
    case future, expiredReset, stale
}
enum AllowanceQualification {
    case qualified(QuotaReading)
    case refused(AllowanceRejection)

    var reading: QuotaReading? { if case .qualified(let value) = self { return value }; return nil }

    static func assess(_ reading: QuotaReading, accountID: String?, authenticated: Bool,
                       failed: Bool = false, relay: Bool = false, now: Date, horizon: TimeInterval) -> Self {
        guard now.timeIntervalSince1970.isFinite, reading.used.isFinite, (0...100).contains(reading.used),
              reading.minutes > 0, reading.date.timeIntervalSince1970.isFinite else { return .refused(.invalidValue) }
        guard !relay else { return .refused(.unsupportedSource) }
        guard !reading.bucket.isEmpty, !reading.window.isEmpty else { return .refused(.invalidValue) }
        guard !reading.accountID.isEmpty, accountID == reading.accountID else { return .refused(.identityMismatch) }
        guard !failed else { return .refused(.providerError) }
        guard authenticated else { return .refused(.restored) }
        guard reading.date <= now else { return .refused(.future) }
        if let reset = reading.reset {
            guard reset.timeIntervalSince1970.isFinite else { return .refused(.invalidValue) }
            guard reset > now else { return .refused(.expiredReset) }
        }
        guard horizon.isFinite, horizon > 0, now.timeIntervalSince(reading.date) < horizon else { return .refused(.stale) }
        return .qualified(reading)
    }
}

extension ToolQuotaState {
    func qualification(_ reading: QuotaReading, now: Date) -> AllowanceQualification {
        AllowanceQualification.assess(reading, accountID: guardAccountID, authenticated: guardAuthenticated,
            failed: guardFailed, now: now, horizon: horizon)
    }
}
