import SwiftUI

struct UsageInsightsView: View {
    var summary: UsageInsightsSummary
    @Bindable var monitor: LiveMonitor
    @Bindable var notices: ProvenanceNotices
    /// Records held back from the totals on this screen.
    var integrity: IntegrityReport?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Changes and evidence").font(PageStyle.sectionTitle)
            Text("Last 30 days · all locally recorded tools · independent of History and Cost filters. Today is still in progress.").font(.callout).foregroundStyle(.secondary)
            if let integrity, !integrity.isClean {
                IntegrityBanner(report: integrity)
            }
            if summary.report.entries.isEmpty {
                Text("No usage records in the last 30 days. Patterns will appear when local usage is available.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recorded output change").font(.headline)
                    if case .changed = summary.outputChangeClaim {
                        Text(summary.outputChangeHeadline(compactTokens: compact)).font(.title2).monospacedDigit()
                        if let evidence = summary.outputChangeEvidence(compactTokens: compact) {
                            Text(evidence)
                        }
                    } else {
                        Text(summary.outputChangeHeadline(compactTokens: compact))
                    }
                    Text("Two complete seven-day periods ending yesterday. This compares recorded output, not productivity or quota burn. Missing logs and changes in source coverage can affect the comparison.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Context utilization evidence").font(.headline)
                    if case .measured = summary.peakContextClaim {
                        Text(summary.peakContextHeadline).font(.title3).monospacedDigit()
                        if let evidence = summary.peakContextEvidence { Text(evidence) }
                    } else {
                        Text(summary.peakContextHeadline)
                    }
                    Text("Last 30 days. Records without measurable context remain in usage totals; they cannot establish context occupancy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Explore usage over time and task, model, account, tool or project contributions in History; pricing assumptions and unpriced usage in Cost.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DetailSheet("How usage is counted") {
                VStack(alignment: .leading, spacing: 16) {
                    if let first = summary.earliest {
                        Text("Available records begin " + first.formatted(date: .abbreviated, time: .omitted) + ".")
                    }
                    if let caption = summary.cacheShareCaption { Text(caption) }
                    ProvenanceNotice(provenance: .deduplicated, notices: notices)
                    ProvenanceNotice(provenance: .converted, notices: notices)
                    Text("Usage totals count processing passes, not unique written text. Cached input is part of input and reasoning is part of output.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }
        }
    }
}
