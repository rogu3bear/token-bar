import SwiftUI
import Charts

struct CostOutputComparison: View {
    var report: CostReport
    var basis: CostPriceBasis
    @Environment(\.appAccent) private var accent
    private var output: CostOutput { report.output }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost relative to output").font(PageStyle.sectionTitle)
            HStack(alignment: .top, spacing: PageStyle.related) {
                SummaryMetric(title: "USD PER 1M OUTPUT TOKENS",
                              value: output.usdPerMillionOutput.map(CostPricing.dollars) ?? "—",
                              detail: "Full request cost · priced records")
                SummaryMetric(title: "INPUT PER OUTPUT TOKEN",
                              value: output.inputPerOutput.map { NSDecimalNumber(decimal: $0).doubleValue.formatted(.number.precision(.fractionLength(2))) + "×" } ?? "—",
                              detail: "Includes cached input · same records")
            }
            Text("\(compact(output.output)) output tokens priced · \(compact(output.unpricedOutput)) output tokens unpriced · \(output.outputCoverage.map { String(format: "%.1f%%", $0 * 100) } ?? "—") of recorded output priced")
                .font(.caption).foregroundStyle(.secondary)
            if output.missingOutputRecords > 0 {
                Text("\(output.missingOutputRecords.formatted()) records have no output counter and are excluded from output coverage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart(report.days) { day in
                if let rate = day.output.usdPerMillionOutput {
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("USD per 1M output", NSDecimalNumber(decimal: rate).doubleValue))
                        .foregroundStyle(accent)
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(CostPricing.dollars(rate) + " per million output tokens")
                }
            }.chartYAxisLabel("USD / 1M output").frame(height: 150)
                .overlay {
                    if !report.days.contains(where: { $0.output.usdPerMillionOutput != nil }) {
                        Text("No priced output in this selection").foregroundStyle(.secondary)
                    }
                }
            Text("Daily comparison · local time. Each bar divides the full estimated request cost, including input and cache, by output from those same priced records. Zero output and unpriced days have no bar. Output includes reasoning; it does not measure answer quality or completed work.")
                .font(.caption).foregroundStyle(.secondary)
            Text(basis == .historical
                 ? "Historical rates combine changes in rates and how you used the models. Use Reference rates to hold the rate card fixed; filter to one model or task for a closer comparison."
                 : "Reference rates hold the rate card fixed across days. Differences still reflect model mix, input, caching and context size; they do not prove a change in output quality.")
                .font(.caption).foregroundStyle(.secondary)
            DetailSheet("Daily comparison details") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Day"); Text("USD / 1M output"); Text("Output priced"); Text("Output coverage")
                    }.font(.caption.bold())
                    ForEach(report.days) { day in
                        GridRow {
                            Text(day.date.formatted(date: .abbreviated, time: .omitted))
                            Text(day.output.usdPerMillionOutput.map(CostPricing.dollars) ?? "—")
                            Text(compact(day.output.output))
                            Text(day.output.outputCoverage.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                        }
                    }
                }.font(.callout).monospacedDigit().padding(.top, 8)
                Text("Coverage uses recorded output only. Missing output counters are excluded; see report details for field completeness.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
