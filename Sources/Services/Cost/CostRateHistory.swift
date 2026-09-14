import Foundation

enum CostPriceBasis: String, CaseIterable { case historical = "Historical rates", reference = "Reference rates" }
struct CostRateVersion {
    var id: String
    var effectiveFrom: String
    var effectiveUntil: String?
    var verifiedOn = "2026-09-09"
    var source: URL
    var rule: CostRateRule
    var transitionDays: Set<String> = []
    var fastFrom: String?
    // Historical base prices are documented; do not backdate today's context surcharge without evidence.
    var longContextVerifiedFrom = "2026-09-09"
    func includes(_ day: String) -> Bool { day >= effectiveFrom && (effectiveUntil.map { day < $0 } ?? true) }
}
enum CostRateHistory {
    static let changelog = URL(string: "https://developers.openai.com/api/docs/changelog")!
    static let launch = URL(string: "https://openai.com/index/gpt-5-6/")!
    static let reductions = URL(string: "https://openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/")!
    static let versions: [CostRateVersion] = {
        var values: [CostRateVersion] = []
        func add(_ model: String, from: String, until: String? = nil, input: String, cached: String, output: String, source: URL) {
            let rule = CostRateRule.modern(model, input: input, cached: cached, output: output)
            values.append(CostRateVersion(id: "\(model)-\(from)", effectiveFrom: from, effectiveUntil: until, source: source, rule: rule,
                                          transitionDays: [from], fastFrom: "2026-07-31"))
        }
        for model in ["gpt-5.6-sol", "gpt-5.6"] {
            add(model, from: "2026-07-09", until: "2026-08-21", input: "5", cached: "0.5", output: "30", source: launch)
            add(model, from: "2026-08-21", input: "4", cached: "0.4", output: "20", source: changelog)
        }
        add("gpt-5.6-terra", from: "2026-07-09", until: "2026-07-30", input: "2.5", cached: "0.25", output: "15", source: launch)
        add("gpt-5.6-terra", from: "2026-07-30", input: "2", cached: "0.2", output: "12", source: reductions)
        add("gpt-5.6-luna", from: "2026-07-09", until: "2026-07-30", input: "1", cached: "0.1", output: "6", source: launch)
        add("gpt-5.6-luna", from: "2026-07-30", input: "0.2", cached: "0.02", output: "1.2", source: reductions)
        add("gpt-6-astra", from: "2026-09-03", input: "10", cached: "1", output: "50", source: changelog)
        // Earlier complete schedules are not established by the launch post's input/output prices alone.
        // Keep the dated observation instead of manufacturing a retrospective cache/context tariff.
        for rule in CostRateCard.reference.rules where ["gpt-5.5", "gpt-5.3-codex"].contains(rule.model) {
            values.append(CostRateVersion(id: "\(rule.model)-observed-2026-09-09", effectiveFrom: "2026-09-09", source: CostRateCard.reference.source, rule: rule))
        }
        return values
    }()
    static func estimate(_ entry: Entry, service: CostService, sessionBand: String?, versions: [CostRateVersion] = versions) -> CostEstimate {
        guard let day = entry.pricingDay ?? (entry.bucket == "day" ? nil : UsageMetadata.day(entry.date)) else { return .missing("Historical UTC pricing date needs recovery") }
        let matches = versions.filter { $0.rule.provider == entry.provider && $0.rule.model == entry.model && $0.includes(day) }
        guard matches.count == 1, let version = matches.first else { return .missing(matches.isEmpty ? "No verified historical rate for this date/model" : "Historical rate intervals overlap") }
        guard !version.transitionDays.contains(day) else { return .missing("Price changed on this day; cutover time is not verified") }
        let applied = CostPricing.appliedService(service, entry: entry)
        if applied == .fast {
            guard let from = version.fastFrom, day >= from else { return .missing("Historical Fast/Priority rate not verified") }
        }
        let band = version.rule.contextScope == .session ? sessionBand : entry.contextBand
        if band == "long" && day < version.longContextVerifiedFrom { return .missing("Historical long-context tariff not verified") }
        let card = CostRateCard(id: version.id, observedOn: version.verifiedOn, source: version.source, rules: [version.rule])
        var result = CostPricing.estimate(entry, card: card, service: service, sessionBand: sessionBand)
        result.rateCardID = version.id; result.rateSource = version.source.absoluteString; result.verifiedOn = version.verifiedOn
        result.effectiveFrom = version.effectiveFrom; result.effectiveUntil = version.effectiveUntil
        result.priceBasis = CostPriceBasis.historical.rawValue
        return result
    }
}
