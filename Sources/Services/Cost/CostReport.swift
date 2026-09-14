import Foundation

struct CostLine {
    var entry: Entry
    var estimate: CostEstimate
}
struct CostRow: Identifiable {
    var id: String
    var title: String
    var amounts = CostAmounts()
    var pricedTokens = 0
    var unpricedTokens = 0
    var records = 0
    var hasPricedRecords = false
}
struct CostDay: Identifiable {
    var date: Date
    var amounts = CostAmounts()
    var unpricedTokens = 0
    var id: Date { date }
}
struct CostContextIndex {
    var bands: [String: String] = [:]
    var uncertainSessions = Set<String>()
    init(_ source: [Entry]) {
        for entry in source {
            if entry.provider == nil || entry.model == "Unknown model" { uncertainSessions.insert(entry.session) }
            let key = CostReport.sessionKey(entry), previous = bands[key], next = entry.contextBand ?? "unknown"
            if previous == "long" || next == "long" { bands[key] = "long" }
            else if previous == "unknown" || next == "unknown" { bands[key] = "unknown" }
            else { bands[key] = "short" }
        }
    }
}

struct CostReport {
    var calculatedAt: Date?
    var lines: [CostLine] = []
    var completeness = CostCoverage()
    var amounts = CostAmounts()
    var pricedTokens = 0
    var unpricedTokens = 0
    var unknownEffortTokens = 0
    var models: [CostRow] = []
    var efforts: [CostRow] = []
    var days: [CostDay] = []
    var timeline: [CostDay] = []
    var minuteResolution = false
    var dailyOnlyAmount = CostAmounts()
    var issues: [String: Int] = [:]
    var totalTokens: Int { pricedTokens + unpricedTokens }
    var coverage: Double? { totalTokens > 0 ? Double(pricedTokens) / Double(totalTokens) : nil }
    var hasPricedRecords: Bool { lines.contains { $0.estimate.amounts != nil } }
    var availabilityMessage: String {
        guard calculatedAt != nil else { return "Cost results are not available yet." }
        if lines.isEmpty { return "No usage matches this selection." }
        if totalTokens == 0 { return "Selected records contain zero processed tokens. Pricing coverage has no token denominator." }
        if !hasPricedRecords { return "Estimate unavailable. Selected usage has no supported price." }
        if unpricedTokens > 0 { return "Partial estimate. Unpriced usage is excluded from the amount." }
        return "All selected processed tokens have a supported price."
    }
    func statusMessage(sourceAvailable: Bool) -> String {
        sourceAvailable ? availabilityMessage : "Cost estimate unavailable. No successful usage read is available."
    }
    static func sessionKey(_ entry: Entry) -> String { "\(entry.provider ?? "unknown")|\(entry.model)|\(entry.session)" }
    static func build(source: [Entry], query: UsageQuery, catalog: [String: TaskInfo], effort: String = "All levels",
                      service: CostService = .standard, basis: CostPriceBasis = .reference, card: CostRateCard = .reference, now: Date = Date(), context: CostContextIndex? = nil, prefiltered: Bool = false) -> Self {
        let context = context ?? CostContextIndex(source)
        let bands = context.bands, uncertainSessions = context.uncertainSessions
        var result = Self(), models: [String: CostRow] = [:], efforts: [String: CostRow] = [:], days: [Date: CostDay] = [:]
        result.calculatedAt = now
        func add(_ rows: inout [String: CostRow], key: String, title: String, entry: Entry, estimate: CostEstimate) {
            var row = rows[key] ?? CostRow(id: key, title: title)
            if let value = estimate.amounts { row.amounts = row.amounts + value; row.pricedTokens += entry.tokens.total; row.hasPricedRecords = true }
            else { row.unpricedTokens += entry.tokens.total }
            row.records += entry.eventCount; rows[key] = row
        }
        let bounds = query.timeBounds(now: now)
        for entry in source where (prefiltered || query.matches(entry, catalog: catalog, bounds: bounds)) && (effort == "All levels" || (entry.effort ?? "Unknown") == effort) {
            let observedBand = bands[sessionKey(entry)]
            let sessionBand = observedBand == "long" ? "long" : (uncertainSessions.contains(entry.session) ? nil : observedBand)
            var estimate = basis == .historical ? CostRateHistory.estimate(entry, service: service, sessionBand: sessionBand) : CostPricing.estimate(entry, card: card, service: service, sessionBand: sessionBand)
            if estimate.priceBasis == nil { estimate.priceBasis = basis.rawValue }
            result.completeness.add(entry)
            result.lines.append(CostLine(entry: entry, estimate: estimate))
            let date = Calendar.current.startOfDay(for: entry.date)
            var day = days[date] ?? CostDay(date: date)
            if let value = estimate.amounts {
                result.amounts = result.amounts + value; result.pricedTokens += entry.tokens.total
                day.amounts = day.amounts + value
            } else {
                result.unpricedTokens += entry.tokens.total; day.unpricedTokens += entry.tokens.total
                result.issues[estimate.unavailable ?? "Unknown pricing", default: 0] += entry.tokens.total
            }
            if entry.effort == nil { result.unknownEffortTokens += entry.tokens.total }
            days[date] = day
            add(&models, key: "\(entry.provider ?? "Unknown")|\(entry.model)", title: "\(entry.model) · \(entry.provider ?? "Unknown provider")", entry: entry, estimate: estimate)
            add(&efforts, key: entry.effort ?? "Unknown", title: entry.effort ?? "Unknown", entry: entry, estimate: estimate)
        }
        let order: (CostRow, CostRow) -> Bool = { a, b in a.amounts.total == b.amounts.total ? a.id < b.id : a.amounts.total > b.amounts.total }
        result.models = models.values.sorted(by: order); result.efforts = efforts.values.sorted(by: order)
        result.days = days.values.sorted { $0.date < $1.date }
        result.minuteResolution = UsageTimeline.build(entries: result.lines.map(\.entry), query: query, now: now).minuteResolution
        if result.minuteResolution {
            var minutes: [Date: CostAmounts] = [:]
            for line in result.lines {
                guard let amounts = line.estimate.amounts else { continue }
                guard line.entry.bucket != "day" else { result.dailyOnlyAmount = result.dailyOnlyAmount + amounts; continue }
                let minute = Calendar.current.dateInterval(of: .minute, for: line.entry.date)!.start
                minutes[minute] = (minutes[minute] ?? CostAmounts()) + amounts
            }
            var cumulative = CostAmounts()
            result.timeline = minutes.keys.sorted().map { date in
                cumulative = cumulative + minutes[date]!
                return CostDay(date: date, amounts: cumulative)
            }
        } else { result.timeline = result.days }
        return result
    }
    func csv(card: CostRateCard = .reference, service: CostService = .standard) -> String {
        func quote(_ value: String) -> String { RequestExport.quote(value) }
        let header = "timestamp,session,provider,model,reasoning_level,input,cached_input,cache_write_input,output,reasoning_subset,granularity,record_count,context_band,effective_context_band,context_scope,reference_rate_card,reference_service,currency,estimated_usd,input_usd,cached_usd,cache_write_usd,reasoning_usd,answer_usd,unpriced_reason,schema_version,rate_card,service_selection,applied_service,observed_service,requested_service,price_basis,effective_from,effective_until,verified_on,rate_source"
        let iso = ISO8601DateFormatter()
        let rows = lines.map { line -> String in
            let e = line.entry, a = line.estimate.amounts
            var values: [String] = [iso.string(from: e.date), e.session, e.provider ?? "Unknown", e.model, e.effort ?? "Unknown"]
            values += [e.hasField("input_tokens") ? String(e.tokens.input) : "", e.hasField("cached_input_tokens") ? String(e.tokens.cached) : "", e.tokens.cacheWrite.map { String($0) } ?? "", e.hasField("output_tokens") ? String(e.tokens.output) : "", e.hasField("reasoning_output_tokens") ? String(e.tokens.reasoning) : ""]
            let reference = line.estimate.priceBasis == CostPriceBasis.reference.rawValue
            values += [e.bucket ?? "event", String(e.eventCount), e.contextBand ?? "Unknown", line.estimate.effectiveContextBand ?? "Unknown", line.estimate.contextScope ?? "Unknown", reference ? (line.estimate.rateCardID ?? card.id) : "", reference ? service.rawValue : "", "USD"]
            let amounts: [Decimal?] = [a?.total, a?.input, a?.cached, a?.cacheWrite, a?.reasoning, a?.answer]
            values += amounts.map { $0.map(CostPricing.decimal) ?? "" }
            values.append(line.estimate.unavailable ?? "")
            values += ["2", line.estimate.rateCardID ?? (reference ? card.id : ""), service.rawValue, line.estimate.appliedService ?? "", e.observedService ?? "", e.requestedService ?? "", line.estimate.priceBasis ?? "", line.estimate.effectiveFrom ?? "", line.estimate.effectiveUntil ?? "", line.estimate.verifiedOn ?? (reference ? card.observedOn : ""), line.estimate.rateSource ?? (reference ? card.source.absoluteString : "")]
            return values.map(quote).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }
}
