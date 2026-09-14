import SwiftUI

struct CostRateHistoryView: View {
    var selectedModel: String
    @State private var model = "gpt-5.6-sol"
    @Environment(\.appAccent) private var accent
    private var models: [String] { Set(CostRateHistory.versions.map { $0.rule.model }).sorted() }
    private var activeModel: String { selectedModel == "All models" ? model : selectedModel }
    private var versions: [CostRateVersion] {
        CostRateHistory.versions.filter { $0.rule.model == activeModel }.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Published standard API base prices · USD per million tokens. These are the shipped historical sources, separate from your usage and subscription allowance. The last verification was September 9, 2026; later market changes may be absent.")
                .font(.callout).foregroundStyle(.secondary)
            if selectedModel == "All models" {
                Picker("Model", selection: $model) { ForEach(models, id: \.self) { Text($0).tag($0) } }
            } else { Text(activeModel).font(.headline) }
            if versions.isEmpty { Text("No verified price history for this model. Missing rates remain unavailable.") }
            ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                VStack(alignment: .leading, spacing: 8) {
                    Text(version.effectiveFrom + " → " + (version.effectiveUntil.map { $0 + " (exclusive)" } ?? (version.qualification == nil ? "onward in shipped schedule" : "temporary reduction")))
                        .font(.headline)
                    Text("Input " + CostPricing.dollars(version.rule.input) + " · cache read " + CostPricing.dollars(version.rule.cached) + " · output " + CostPricing.dollars(version.rule.output))
                        .monospacedDigit()
                    if index > 0 {
                        let previous = versions[index - 1].rule
                        Text("Change from previous: input " + change(previous.input, version.rule.input)
                             + " · cache read " + change(previous.cached, version.rule.cached)
                             + " · output " + change(previous.output, version.rule.output))
                    }
                    Text("Verified " + version.verifiedOn + (version.transitionDays.isEmpty ? " · earlier rates are not established here" : " · change-day cutover time unknown; that day stays unpriced"))
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Published source", destination: version.source).foregroundStyle(accent)
                    if let qualification = version.qualification {
                        Text(qualification).font(.caption).foregroundStyle(.secondary)
                        if let source = version.qualificationSource { Link("Promotion duration source", destination: source).foregroundStyle(accent) }
                    }
                }
                Divider()
            }
            Text("These are base rates. Cache writes, Fast service and long context may alter a request's modeled cost; their historical evidence gates still apply. Reference pricing is a fixed comparison card, not a historical observation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func change(_ old: Decimal, _ new: Decimal) -> String {
        guard old > 0 else { return "Unavailable" }
        return String(format: "%+.1f%%", NSDecimalNumber(decimal: (new - old) / old * 100).doubleValue)
    }
}
