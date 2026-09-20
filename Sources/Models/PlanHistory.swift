import Foundation

/// Local calendar day used as a durable aggregation key. Plan observations,
/// historical usage buckets, and cost-recovery groups share this boundary.
enum LedgerDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> TimeInterval {
        calendar.startOfDay(for: date).timeIntervalSince1970
    }
}

struct PlanObservation: Codable, Identifiable, Equatable {
    var id: String
    var plan: String
    var firstSeen: Date
    var lastSeen: Date
    var account: Account?
    var evidence: String
    var models: [String]
}
extension UsageScanner {
    func recordPlan(_ plan: String, date: Date, account: Account?, evidence: String, model: String?) {
        guard !plan.isEmpty else { return }
        let day = LedgerDay.key(date)
        let key = "\(day)|\(account?.id ?? "unknown")|\(plan)|\(evidence)"
        if ledger.plans == nil { ledger.plans = [:] }
        if var existing = ledger.plans?[key] {
            existing.firstSeen = min(existing.firstSeen, date)
            existing.lastSeen = max(existing.lastSeen, date)
            if let model, !existing.models.contains(model) { existing.models.append(model) }
            if ledger.plans?[key] != existing { ledger.plans?[key] = existing; markMetadataDirty() }
        } else {
            markMetadataDirty()
            ledger.plans?[key] = PlanObservation(id: key, plan: plan, firstSeen: date, lastSeen: date,
                account: account, evidence: evidence, models: model.map { [$0] } ?? [])
        }
    }
    func recordAccount(_ account: Account) {
        if ledger.accounts == nil { ledger.accounts = [:] }
        if ledger.accounts?[account.id] != account { ledger.accounts?[account.id] = account; markMetadataDirty() }
        if let plan = account.plan, let issued = account.planIssuedAt {
            recordPlan(plan, date: issued, account: account, evidence: "Account credential claim", model: nil)
        }
    }
}
