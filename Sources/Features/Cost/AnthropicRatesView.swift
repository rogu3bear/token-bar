import SwiftUI

struct AnthropicRatesView: View {
    private let models = [("Fable 5.1", "claude-fable-5-1"), ("Opus 5.5", "claude-opus-5-5"),
                          ("Sonnet 5.5", "claude-sonnet-5-5"), ("Haiku 5.5", "claude-haiku-5-5")]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anthropic API rates").font(.headline)
            Text("USD per million tokens · Standard · checked October 19, 2026")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow { Text("Model"); Text("Input"); Text("Cache read"); Text("Output") }.font(.caption.bold())
                ForEach(models, id: \.1) { name, model in
                    if let rate = ProviderCostRates.rules.first(where: { $0.model == model }) {
                        GridRow {
                            Text(name)
                            Text(CostPricing.dollars(rate.input))
                            Text(CostPricing.dollars(rate.cached))
                            Text(CostPricing.dollars(rate.output))
                        }
                    }
                }
            }.font(.callout).monospacedDigit()
            Text("Cache writes: 1.25× input for 5 minutes; 2× for 1 hour. Haiku 5.5 is 5× above 100K prompt tokens. API comparisons, not subscription charges.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Anthropic pricing source", destination: ProviderCostRates.anthropicSource)
                .font(.caption)
        }
    }
}
