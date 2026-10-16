import Foundation

/// First-party standard comparison tariffs, checked against official provider
/// documentation on October 2, 2026. Exact IDs only; Build IDs do not become API aliases.
enum ProviderCostRates {
    static let anthropicSource = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    static let xaiSource = URL(string: "https://docs.x.ai/developers/pricing")!
    static let rules: [CostRateRule] = [
        claude("claude-fable-5-1", input: "10", cached: "0.25", output: "50"),
        claude("claude-opus-5-5", input: "4", cached: "0.2", output: "20", fast: 2),
        claude("claude-sonnet-5-5", input: "2", cached: "0.2", output: "10"),
        claude("claude-haiku-4-5-20251001", input: "1", cached: "0.1", output: "5"),
        claude("claude-fable-5", input: "10", cached: "1", output: "50"),
        claude("claude-opus-5", input: "5", cached: "0.5", output: "25", fast: 2),
        claude("claude-opus-4-8", input: "5", cached: "0.5", output: "25", fast: 2),
        claude("claude-sonnet-5", input: "2", cached: "0.2", output: "10"),
        grok("grok-4.7", input: "2", cached: "0.5", output: "6"),
        grok("grok-4.6", input: "2", cached: "0.5", output: "6"),
        grok("grok-build-0.1", input: "1", cached: "0.2", output: "2")
    ]
    private static func claude(_ model: String, input: String, cached: String, output: String, fast: Decimal? = nil) -> CostRateRule {
        CostRateRule(provider: "anthropic", model: model, input: Decimal(string: input)!, cached: Decimal(string: cached)!, output: Decimal(string: output)!,
            cacheWriteMultiplier: Decimal(string: "1.25")!, contextScope: .none, fastMultiplier: fast, source: anthropicSource,
            cacheWrite1hMultiplier: 2, requiresOutputSplit: false, longOutputMultiplier: 1)
    }
    private static func grok(_ model: String, input: String, cached: String, output: String) -> CostRateRule {
        CostRateRule(provider: "xai", model: model, input: Decimal(string: input)!, cached: Decimal(string: cached)!, output: Decimal(string: output)!,
            cacheWriteMultiplier: nil, contextScope: .providerRequest, fastMultiplier: nil, source: xaiSource, requiresOutputSplit: false, longOutputMultiplier: 2)
    }
}
