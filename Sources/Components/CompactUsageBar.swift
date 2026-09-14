import SwiftUI
import Charts

/// Recorded token totals for today. Missing days stay absent; nothing is drawn as zero.
struct CompactUsageBar: View {
    var packed: CompactUsage
    var now: Date
    var action: (() -> Void)?
    @Environment(\.toolPalette) private var palette
    var body: some View {
        let domain = CompactUsage.plotDomain(now: now)
        let series = packed.tools.isEmpty ? [ToolUsageTimeline(tool: .other, totals: Tokens(), timeline: packed.timeline)] : packed.tools
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if packed.timeline.points.contains(where: { $0.tokens.total > 0 }) {
                        Text(compact(packed.tools.reduce(0) { $0 + $1.totals.total })).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(series) { series in
                        ForEach(series.timeline.plotPoints(in: domain)) { point in
                            if packed.timeline.minuteResolution {
                                LineMark(x: .value("Minute", point.date), y: .value("Recorded tokens", point.tokens.output), series: .value("Tool", series.id))
                                    .interpolationMethod(.stepEnd).foregroundStyle(series.tool.color(in: palette))
                                    .lineStyle(by: .value("Tool", series.id))
                            } else {
                                BarMark(x: .value("Day", point.date, unit: .day), y: .value("Tokens", point.tokens.output))
                                    .foregroundStyle(series.tool.color(in: palette)).position(by: .value("Tool", series.id))
                            }
                        }
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartPlotStyle { $0.padding(.vertical, 2) }
                .frame(height: 56)
                .accessibilityHidden(true)
                HStack {
                    Text(domain.lowerBound, format: .dateTime.hour().minute())
                    Spacer()
                    Text("Now")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(packed.timeline.points.isEmpty ? "Today, no recorded usage" : "Today, " + compact(packed.tools.reduce(0) { $0 + $1.totals.total }) + " recorded tokens")
        .accessibilityHint(action == nil ? "" : "Opens History")
    }
}
