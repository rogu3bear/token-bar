import SwiftUI
import Charts

struct CostMeteringView: View {
    var model: UsageModel
    var monitor: LiveMonitor
    @State private var selected = ""
    @Environment(\.appAccent) private var accent
    private var windows: [QuotaReading] { monitor.currentID.flatMap { monitor.state.accounts[$0]?.quotas } ?? [] }
    private var windowID: String { windows.contains { $0.id == selected } ? selected : windows.first?.id ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare the same account and allowance window over the selected Cost dates. Local tokens are inferred to this account; allowance observations can include activity this Mac cannot see.")
                .font(.callout).foregroundStyle(.secondary)
            if windows.isEmpty { Text("No retained window for the active Codex account. Claude and Grok historical comparisons are unavailable.") }
            else {
                Picker("Allowance window", selection: Binding(get: { windowID }, set: { selected = $0 })) {
                    ForEach(windows) { window in Text("\(window.name) · \(window.minutes) minutes · \(window.window)").tag(window.id) }
                }
            }
            if model.comparisons.busy { ProgressView("Preparing retained observations…") }
            if let calculated = model.comparisons.calculatedAt {
                Text("Calculated " + calculated.formatted(date: .abbreviated, time: .standard) + (model.comparisons.busy ? " · previous result while updating" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let report = model.comparisons.metering[windowID] {
                if let reason = report.reason { Text(reason).foregroundStyle(.secondary) }
                Text("\(report.intervals.count) matched intervals · \(report.excludedIntervals) resets, decreases or gaps excluded · \(report.coarseRecords) records still have daily timing only")
                    .font(.caption).foregroundStyle(.secondary)
                Chart(report.intervals) { interval in
                    if let ratio = interval.tokensPerPoint {
                        PointMark(x: .value("Observed", interval.end), y: .value("Local tokens / allowance point", ratio))
                            .foregroundStyle(accent)
                            .accessibilityLabel(interval.start.formatted(date: .abbreviated, time: .shortened) + " to " + interval.end.formatted(date: .omitted, time: .shortened))
                            .accessibilityValue(ratio.formatted(.number.precision(.fractionLength(1))) + " local tokens per percentage point")
                    }
                }.chartXScale(range: .plotDimension(padding: 8))
                    .chartYAxisLabel("Local tokens / percentage point").frame(height: 140)
                    .overlay {
                        if !report.intervals.contains(where: { $0.tokensPerPoint != nil }) {
                            Text("No ratio with sufficient local evidence").foregroundStyle(.secondary)
                        }
                    }
                Text("Ratios are diagnostic, not subscription prices. Unattributed usage, unresolved timing, missing counters or a zero denominator leave the ratio unavailable. Even a single observed model cannot establish a model-specific subscription multiplier.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(report.intervals.suffix(50).reversed()) { interval in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(interval.start.formatted(date: .abbreviated, time: .shortened) + " → " + interval.end.formatted(date: .omitted, time: .shortened))
                            .font(.callout.bold())
                        Text(String(format: "Allowance used +%.2f percentage points", interval.usedPoints))
                        Text("Local input \(interval.input.formatted()) · output \(interval.output.formatted()) · cache reads \(interval.cached.formatted()) (within input)")
                        Text("Local tokens / point: " + (interval.tokensPerPoint.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Unavailable"))
                        Text("Observed models: " + (interval.models.isEmpty ? "Unavailable" : interval.models.sorted().joined(separator: ", ")))
                        if interval.unattributedRecords > 0 || interval.missingFields > 0 {
                            Text("\(interval.unattributed.formatted()) tokens in \(interval.unattributedRecords) unattributed records · \(interval.missingFields) records lack Codex identity, exact request timing or counters")
                        }
                    }.font(.caption).padding(.vertical, 6)
                }
                if report.intervals.count > 50 { Text("Showing the most recent 50 intervals; the plot includes all eligible intervals.").font(.caption) }
            }
            Text("Readings are retained for up to 90 days, generally five minutes apart. Intervals longer than ten minutes, resets, changed windows and decreases are excluded. Only exact timestamped single-request records enter the token mix; matching archived details are reused when available. Reporting lag and unseen usage can explain a divergence; this does not prove a billing error.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
