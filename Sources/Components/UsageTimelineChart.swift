import SwiftUI
import Charts

struct UsageTimelineChart: View {
    var timeline: UsageTimeline
    var metric: UsageMetric = .output
    var tools: [ToolUsageTimeline] = []
    @Environment(\.toolPalette) private var palette
    @Environment(\.appAccent) private var accent
    private var series: [ToolUsageTimeline] {
        tools.isEmpty ? [ToolUsageTimeline(tool: .other, totals: Tokens(), timeline: timeline)] : tools
    }
    private func color(_ tool: HistoryTool) -> Color {
        tools.isEmpty ? accent : tool.color(in: palette)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(series) { series in
                    ForEach(series.timeline.points) { point in
                        if timeline.minuteResolution {
                            LineMark(x: .value("Minute", point.date), y: .value("Recorded tokens", metric.amount(point.tokens)), series: .value("Tool", series.id))
                                .interpolationMethod(.stepEnd).foregroundStyle(color(series.tool))
                                .lineStyle(by: .value("Tool", series.id))
                            PointMark(x: .value("Minute", point.date), y: .value("Recorded tokens", metric.amount(point.tokens)))
                                .symbolSize(12).foregroundStyle(color(series.tool)).symbol(by: .value("Tool", series.id))
                        } else {
                            BarMark(x: .value("Day", point.date, unit: .day), y: .value("Tokens", metric.amount(point.tokens)))
                                .foregroundStyle(color(series.tool)).position(by: .value("Tool", series.id))
                        }
                    }
                }
            }.chartForegroundStyleScale(domain: series.map(\.id), range: series.map { color($0.tool) })
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(date: timeline.minuteResolution ? .omitted : .abbreviated,
                                                time: timeline.minuteResolution ? .shortened : .omitted))
                        }
                    }
                }
            }.chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Int.self) { Text(compact(amount)) } }
                }
            }.frame(height: 200)
                .overlay { if timeline.points.isEmpty { Text("No timestamped usage available in this selection.").foregroundStyle(.secondary) } }
            Text(timeline.minuteResolution ? "Cumulative recorded tokens · minute resolution · local time" : "Daily recorded tokens · local time")
                .font(.caption).foregroundStyle(.secondary)
            if timeline.dailyOnly.total > 0 {
                Text(UsageTimeline.dailyOnlyCaption(compact(metric.amount(timeline.dailyOnly)), additionalTokens: true))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
