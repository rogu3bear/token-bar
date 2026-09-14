import Foundation

/// A dated comparison tariff, never an invoice or a claim about historical rates.
struct CostRateCard {
    let id: String
    let observedOn: String
    let source: URL
    let rules: [CostRateRule]
    static let reference = CostRateCard(id: "openai-text-2026-09-09", observedOn: "2026-09-09",
        source: URL(string: "https://developers.openai.com/api/docs/pricing")!, rules: [
            .modern("gpt-6-astra", input: "10", cached: "1", output: "50"),
            .modern("gpt-5.6-sol", input: "4", cached: "0.4", output: "20"),
            .modern("gpt-5.6", input: "4", cached: "0.4", output: "20"),
            .modern("gpt-5.6-terra", input: "2", cached: "0.2", output: "12"),
            .modern("gpt-5.6-luna", input: "0.2", cached: "0.02", output: "1.2"),
            CostRateRule(provider: "openai", model: "gpt-5.5", input: 5, cached: Decimal(string: "0.5")!, output: 30,
                         cacheWriteMultiplier: nil, contextScope: .session, fastMultiplier: nil),
            CostRateRule(provider: "openai", model: "gpt-5.3-codex", input: Decimal(string: "1.75")!, cached: Decimal(string: "0.175")!, output: 14,
                         cacheWriteMultiplier: nil, contextScope: .none, fastMultiplier: nil)
        ])
}
struct CostRateRule {
    enum ContextScope: String { case none, request, session }
    var provider: String
    var model: String
    var input: Decimal
    var cached: Decimal
    var output: Decimal
    var cacheWriteMultiplier: Decimal?
    var contextScope: ContextScope
    var fastMultiplier: Decimal?
    static func modern(_ model: String, input: String, cached: String, output: String) -> Self {
        Self(provider: "openai", model: model, input: Decimal(string: input)!, cached: Decimal(string: cached)!, output: Decimal(string: output)!,
             cacheWriteMultiplier: Decimal(string: "1.25")!, contextScope: .request, fastMultiplier: 2)
    }
}
enum CostService: String, CaseIterable { case standard = "Standard", fast = "Fast", observed = "Recorded tier" }
struct CostAmounts {
    var input: Decimal = 0
    var cached: Decimal = 0
    var cacheWrite: Decimal = 0
    var reasoning: Decimal = 0
    var answer: Decimal = 0
    var total: Decimal { input + cached + cacheWrite + reasoning + answer }
    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, cached: a.cached + b.cached, cacheWrite: a.cacheWrite + b.cacheWrite,
             reasoning: a.reasoning + b.reasoning, answer: a.answer + b.answer)
    }
}
struct CostEstimate {
    var amounts: CostAmounts?
    var unavailable: String?
    var effectiveContextBand: String?
    var contextScope: String?
    var rateCardID: String?
    var rateSource: String?
    var verifiedOn: String?
    var effectiveFrom: String?
    var effectiveUntil: String?
    var appliedService: String?
    var priceBasis: String?
    static func missing(_ message: String) -> Self { Self(unavailable: message) }
}
enum CostPricing {
    static let threshold = 272_000
    static func appliedService(_ selection: CostService, entry: Entry) -> CostService? {
        if selection != .observed { return selection }
        switch entry.observedService {
        case "default", "standard": return .standard
        case "priority", "fast": return .fast
        default: return nil
        }
    }
    static func estimate(_ entry: Entry, card: CostRateCard = .reference, service: CostService = .standard,
                         sessionBand: String? = nil) -> CostEstimate {
        guard let provider = entry.provider else { return .missing("Provider not recorded") }
        guard let rate = card.rules.first(where: { $0.provider == provider && $0.model == entry.model }) else {
            return .missing("No verified rate for this provider/model")
        }
        guard entry.hasField("input_tokens"), entry.hasField("cached_input_tokens"), entry.hasField("output_tokens"), entry.hasField("reasoning_output_tokens") else {
            return .missing("Token-field availability needs recovery")
        }
        let t = entry.tokens
        guard t.input >= 0, t.output >= 0, t.cached >= 0, t.reasoning >= 0,
              t.cached <= t.input, t.reasoning <= t.output else { return .missing("Inconsistent token subsets") }
        let writes: Int
        if let value = t.cacheWrite { writes = value }
        else if rate.cacheWriteMultiplier == nil { writes = 0 }
        else { return .missing("Cache-write usage not recorded") }
        guard writes >= 0, writes <= t.input - t.cached else { return .missing("Inconsistent cache-write subset") }
        if writes > 0 && rate.cacheWriteMultiplier == nil { return .missing("Cache-write rate not verified") }
        let band: String?
        switch rate.contextScope {
        case .none: band = "short"
        case .request: band = entry.contextBand
        case .session: band = sessionBand
        }
        guard band == "short" || band == "long" else { return .missing("Request context size not recoverable") }
        let serviceMultiplier: Decimal
        guard let applied = appliedService(service, entry: entry) else { return .missing("Usage service tier not recorded or unsupported") }
        if applied == .standard { serviceMultiplier = 1 }
        else if let fast = rate.fastMultiplier { serviceMultiplier = fast }
        else { return .missing("Fast reference rate not verified") }
        let inputRate = rate.input * (band == "long" ? 2 : 1) * serviceMultiplier / 1_000_000
        let cacheRate = rate.cached * (band == "long" ? 2 : 1) * serviceMultiplier / 1_000_000
        let outputRate = rate.output * (band == "long" ? Decimal(string: "1.5")! : 1) * serviceMultiplier / 1_000_000
        return CostEstimate(amounts: CostAmounts(input: Decimal(t.input - t.cached - writes) * inputRate,
            cached: Decimal(t.cached) * cacheRate, cacheWrite: Decimal(writes) * inputRate * (rate.cacheWriteMultiplier ?? 1),
            reasoning: Decimal(t.reasoning) * outputRate, answer: Decimal(t.output - t.reasoning) * outputRate),
            effectiveContextBand: band, contextScope: rate.contextScope.rawValue,
            rateCardID: card.id, rateSource: card.source.absoluteString, verifiedOn: card.observedOn,
            appliedService: applied.rawValue, priceBasis: CostPriceBasis.reference.rawValue)
    }
    static func decimal(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func dollars(_ value: Decimal) -> String {
        let format = NumberFormatter(); format.numberStyle = .currency; format.currencyCode = "USD"
        format.maximumFractionDigits = value > 0 && value < Decimal(string: "0.01")! ? 6 : 2
        return format.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }
}
