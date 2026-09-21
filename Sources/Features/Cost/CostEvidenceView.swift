import SwiftUI

struct CostEvidenceView: View {
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    private var coverage: CostCoverage { model.costReport.completeness }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Evidence completeness").font(.headline)
            Text("Each percentage uses the same selected processed-token denominator: \(coverage.totalTokens.formatted()) input + output tokens across \(coverage.records.formatted()) usage records. This describes available local evidence; it cannot measure logs that are absent.")
                .font(.callout).foregroundStyle(.secondary)
            if let first = coverage.first, let last = coverage.last {
                Text("Observed range: \(first.formatted(date: .abbreviated, time: .shortened)) – \(last.formatted(date: .abbreviated, time: .shortened)). Legacy daily buckets have approximate boundaries.").font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { Text("Field"); Text("Tokens with evidence"); Text("Records with evidence") }.font(.caption.bold())
                ForEach(coverage.dimensions) { dimension in
                    GridRow {
                        Text(dimension.title)
                        Text(CostPricing.percent(dimension.tokenFraction(total: coverage.totalTokens)))
                        Text("\(dimension.knownRecords.formatted()) / \(coverage.records.formatted())")
                    }
                }
                GridRow {
                    Text("Price available")
                    Text(model.costReport.coverageText)
                    Text("Depends on date, model, fields and chosen service")
                }
            }.font(.callout).monospacedDigit()
            if !model.costReport.lines.isEmpty && model.costReport.unknownEffortTokens > 0 {
                Text(compact(model.costReport.unknownEffortTokens) + " tokens have no recorded reasoning level.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(model.retainedRequests.map { "\($0.formatted()) detailed records retained across all history." } ?? "Retained detail count is unavailable until the next scan.")
                Spacer()
                Button(model.exportingRequests ? "Exporting…" : "Export request details") { model.exportRequests() }
                    .disabled(model.busy || model.filtering || model.exportingRequests || model.retainedRequests == nil)
            }.font(.callout)
            Text("A usage record can contain several requests. Only exact single-request deltas receive a request size; timestamps, turn settings, field presence and recorded tiers are retained before daily aggregation. Requested tier and usage-reported tier are separate. Recover details backfills only groups that match existing totals and counts.")
                .font(.caption).foregroundStyle(.secondary)

        }
    }
}
