import SwiftUI

/// Shared by the real dashboard and its isolated native recording.
struct LiveToolPanels: View {
    var model: UsageModel
    @Bindable var codex: Tachometer
    @Bindable var claude: Tachometer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    @Environment(\.presentationClock) private var clock
    var body: some View {
        Group {
            let tools = LiveTool.active(codex: codex, claude: claude, grok: model.grokMeter)
            VStack(alignment: .leading, spacing: 12) {
            if tools.isEmpty {
                Text("No tools working right now").foregroundStyle(.secondary).padding(16)
            } else {
                ProviderColumnsLayout(columns: tools.count) {
                    ForEach(tools) { tool in
                        ToolSpeedHeader(tool: tool, rateSize: tools.count > 2 ? 29 : 34, meter: model.meter(for: tool))
                    }
                    ForEach(tools) { _ in Divider() }
                    ForEach(tools) { tool in
                        ToolQuotaSummary(tool: tool, quota: model.quota(for: tool),
                                         now: model.referenceDate ?? clock.now, embedded: true,
                                         connection: tool == .claude ? model.claudeConnection : nil)
                    }
                    ForEach(tools) { tool in
                        let meter = model.meter(for: tool)
                        RPMGauge(value: meter.rate, minimum: meter.minimum, maximum: meter.scale,
                                 measured: meter.rawRate, hasRate: meter.hasRate, unit: Binding(get: { meter.unit }, set: { meter.unit = $0 }),
                                 compactLayout: true, showsReadout: false)
                            .frame(height: tools.count > 2 ? 210 : 260)
                    }
                    ForEach(tools) { tool in
                        VStack(alignment: .leading) {
                            Text(model.meter(for: tool).models.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let error = model.meter(for: tool).activity.error { ErrorNotice(message: error) }
                        }
                    }
                }.overlay {
                    GeometryReader { geometry in
                        ForEach(1..<tools.count, id: \.self) { column in
                            Path { path in
                                let x = geometry.size.width * CGFloat(column) / CGFloat(tools.count)
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }.stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                    }.allowsHitTesting(false)
                }.padding(16)
            }
            ToolActivityErrors(model: model, excluding: tools)
            }
        }
    }
}

/// Failures remain visible without presenting an inactive tool as working.
struct ToolActivityErrors: View {
    var model: UsageModel
    var excluding: [LiveTool] = []
    var body: some View {
        ForEach(LiveTool.allCases.filter { !excluding.contains($0) }) { tool in
            if let error = model.meter(for: tool).activity.error {
                ErrorNotice(message: tool.label + ": " + error)
            }
        }
    }
}

/// Equal provider widths and shared row heights keep separators and gauges aligned,
/// including when one provider has additional connection or unavailable text.
struct ProviderColumnsLayout: Layout {
    var columns: Int
    var horizontalSpacing: CGFloat = 48
    var verticalSpacing: CGFloat = 12
    private func dimensions(_ width: CGFloat, subviews: Subviews) -> (CGFloat, [CGFloat]) {
        let cell = max(0, (width - horizontalSpacing * CGFloat(columns - 1)) / CGFloat(columns))
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            }.max() ?? 0
        }
        return (cell, heights)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let (_, heights) = dimensions(width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * verticalSpacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (cell, heights) = dimensions(bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { continue }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + horizontalSpacing), y: y),
                                     anchor: .topLeading, proposal: ProposedViewSize(width: cell, height: height))
            }
            y += height + verticalSpacing
        }
    }
}
