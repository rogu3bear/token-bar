import SwiftUI

struct UsageInsightsView: View {
    var summary: UsageInsightsSummary
    @Bindable var monitor: LiveMonitor
    @Bindable var notices: ProvenanceNotices
    /// Records held back from the totals on this screen.
    var integrity: IntegrityReport?
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.section) {
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
                    if let change = summary.outputChangePercent {
                        Text(change == 0 ? "Unchanged between recorded periods" :
                                String(format: "%.1f%% %@ the prior period", abs(change), change > 0 ? "above" : "below"))
                            .font(.title2).monospacedDigit()
                        Text("\(compact(summary.recentOutput)) output tokens in the last seven full days · \(compact(summary.previousOutput)) in the preceding seven.")
                    } else if summary.recentRecords == 0 || summary.previousRecords == 0 {
                        Text("Comparison unavailable: one or both periods have no local records.")
                    } else if summary.comparisonMissingOutput > 0 {
                        Text("Comparison unavailable: \(summary.comparisonMissingOutput.formatted()) records lack explicit output counters.")
                    } else {
                        Text("\(compact(summary.recentOutput)) recorded output tokens after a prior period with zero recorded output. A percentage change is undefined.")
                    }
                    Text("Two complete seven-day periods ending yesterday. This compares recorded output, not productivity or quota burn. Missing logs and changes in source coverage can affect the comparison.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Context utilization evidence").font(.headline)
                    if let peak = summary.peakContext {
                        Text(String(format: "Highest measured request occupancy: %.0f%%", peak * 100))
                            .font(.title3).monospacedDigit()
                        Text("\(summary.contextSamples.formatted()) of \(summary.report.entries.count.formatted()) records contain measurable request context. This is a recorded maximum, not an anomaly threshold or a forecast.")
                    } else {
                        Text("Context utilization unavailable: no records contain both request input and a known context window.")
                    }
                    Text("Last 30 days. Records without measurable context remain in usage totals; they cannot establish context occupancy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Explore usage over time and task, model, account, tool or project contributions in History; pricing assumptions and unpriced usage in Cost.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DetailSheet("How usage is counted") {
                VStack(alignment: .leading, spacing: PageStyle.related) {
                    if let first = summary.earliest {
                        Text("Available records begin " + first.formatted(date: .abbreviated, time: .omitted) + ".")
                    }
                    if let share = summary.cacheShare {
                        Text(String(format: "%.1f%% of recorded input was cached. Cached input is included in input; this is not a cost-savings estimate.", share * 100))
                    }
                    ProvenanceNotice(provenance: .deduplicated, notices: notices)
                    ProvenanceNotice(provenance: .converted, notices: notices)
                    Text("Usage totals count processing passes, not unique written text. Cached input is part of input and reasoning is part of output.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }
        }
    }
}
