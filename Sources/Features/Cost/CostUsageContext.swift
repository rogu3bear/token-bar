import SwiftUI

/// Local evidence and account-wide observations keep their own scopes.
struct CostUsageContext: View {
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What this usage covers").font(PageStyle.sectionTitle)
            Text("These reports use records available on this Mac. The originating host is not retained, so copied logs cannot establish where work ran. Remote and cloud activity without local records is not measured here.")
                .font(.callout).foregroundStyle(.secondary)
            DetailSheet("Compare with Codex account totals") {
                accountComparison.padding(.top, 10)
            }
            DetailSheet("Allowance changes and observed tokens") {
                CostMeteringView(model: model, monitor: monitor)
            }
        }
    }
    private var accountComparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex account totals").font(.headline)
                Spacer()
                if monitor.usageBusy { ProgressView().controlSize(.small) }
                Button("Refresh account usage") { monitor.refreshUsage() }.disabled(monitor.busy || monitor.usageBusy)
            }
            if let snapshot = model.comparisons.providerSnapshot {
                Text("\(snapshot.source) · read \(snapshot.observed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if let lifetime = snapshot.lifetimeTokens { Text("Provider lifetime: \(lifetime.formatted()) tokens · \(snapshot.days.count.formatted()) dated buckets available").font(.callout) }
                if model.comparisons.busy { ProgressView("Preparing comparison…") }
                if let caption = model.comparisons.calculatedCaption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                if let comparison = model.comparisons.provider {
                if let reason = comparison.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if comparison.reportedDays > 0 {
                    Text("\(comparison.reportedDays) / \(comparison.selectedDays) complete UTC days have provider buckets · \(comparison.firstDay ?? "") through \(comparison.lastDay ?? "")").font(.caption)
                    LabeledContent("Provider tokens on matched days", value: comparison.providerTokens.formatted())
                    LabeledContent("Tokens on this Mac inferred to this account", value: comparison.localInferredTokens.formatted())
                    LabeledContent("Difference · local minus provider", value: comparison.delta?.formatted() ?? "—")
                    LabeledContent("Unattributed tokens on this Mac · all tools", value: comparison.localUnattributedTokens.formatted())
                    if comparison.unknownDateTokens > 0 { Text("\(comparison.unknownDateTokens.formatted()) selected local tokens lack a recovered UTC day and cannot be matched.").font(.caption) }
                }
                }
            } else {
                Text("Refresh to read the active account’s token statistics from the installed app. Existing quota percentages and app turn counts measure different things.").font(.callout).foregroundStyle(.secondary)
            }
            if let error = monitor.usageError { ErrorNotice(message: error) }
            Text("Account totals do not identify a host. A difference may reflect other hosts, unavailable logs, attribution, counter rules or reporting delay; it cannot tell those causes apart. This comparison uses complete UTC days with returned provider buckets. Missing days are unknown, never zero. Account attribution in local logs is inferred. Provider counter rules and reporting delay are not verified, so the difference is diagnostic and does not establish missing usage or a billing error. Subscription charges, credits, and amounts paid remain separate from API-equivalent estimates; these statistics provide no invoice amount.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
