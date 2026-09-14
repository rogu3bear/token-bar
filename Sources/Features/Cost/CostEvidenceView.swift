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
                        Text(dimension.tokenFraction(total: coverage.totalTokens).map { String(format: "%.2f%%", $0 * 100) } ?? "—")
                        Text("\(dimension.knownRecords.formatted()) / \(coverage.records.formatted())")
                    }
                }
                GridRow {
                    Text("Price available")
                    Text(model.costReport.coverage.map { String(format: "%.2f%%", $0 * 100) } ?? "—")
                    Text("Depends on date, model, fields and chosen service")
                }
            }.font(.callout).monospacedDigit()
            HStack {
                Text(model.retainedRequests.map { "\($0.formatted()) detailed records retained across all history." } ?? "Retained detail count is unavailable until the next scan.")
                Spacer()
                Button(model.exportingRequests ? "Exporting…" : "Export request details") { model.exportRequests() }
                    .disabled(model.busy || model.filtering || model.exportingRequests || model.retainedRequests == nil)
            }.font(.callout)
            Text("A usage record can contain several requests. Only exact single-request deltas receive a request size; timestamps, turn settings, field presence and recorded tiers are retained before daily aggregation. Requested tier and usage-reported tier are separate. Recover details backfills only groups that match existing totals and counts.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Account-reported usage").font(.headline)
                Spacer()
                if monitor.usageBusy { ProgressView().controlSize(.small) }
                Button("Refresh account usage") { monitor.refreshUsage() }.disabled(monitor.busy || monitor.usageBusy)
            }
            if let id = monitor.currentID, let snapshot = monitor.state.usage?[id] {
                let comparison = ProviderComparison.build(snapshot: snapshot, currentID: monitor.currentID, source: model.snapshot.entries,
                                                          query: model.costQuery, effort: model.costEffort)
                Text("\(snapshot.source) · read \(snapshot.observed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if let lifetime = snapshot.lifetimeTokens { Text("Provider lifetime: \(lifetime.formatted()) tokens · \(snapshot.days.count.formatted()) dated buckets available").font(.callout) }
                if let reason = comparison.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if comparison.reportedDays > 0 {
                    Text("\(comparison.reportedDays) / \(comparison.selectedDays) complete UTC days have provider buckets · \(comparison.firstDay ?? "") through \(comparison.lastDay ?? "")").font(.caption)
                    LabeledContent("Provider tokens on matched days", value: comparison.providerTokens.formatted())
                    LabeledContent("Local tokens inferred to this account", value: comparison.localInferredTokens.formatted())
                    LabeledContent("Difference · local minus provider", value: comparison.delta?.formatted() ?? "—")
                    LabeledContent("Unattributed local tokens on those days", value: comparison.localUnattributedTokens.formatted())
                    if comparison.unknownDateTokens > 0 { Text("\(comparison.unknownDateTokens.formatted()) selected local tokens lack a recovered UTC day and cannot be matched.").font(.caption) }
                }
            } else {
                Text("Refresh to read the active account’s token statistics from the installed app. Existing quota percentages and app turn counts measure different things.").font(.callout).foregroundStyle(.secondary)
            }
            if let error = monitor.usageError { ErrorNotice(message: error) }
            Text("This comparison uses complete UTC days with returned provider buckets. Missing days are unknown, never zero. Account attribution in local logs is inferred. Provider counter rules and reporting delay are not verified, so the difference is diagnostic and does not establish missing usage or a billing error. Subscription charges, credits, and amounts paid remain separate from API-equivalent estimates; these statistics provide no invoice amount.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
