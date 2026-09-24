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
            let now = model.referenceDate ?? clock.now
            let remaining: (LiveTool) -> Double? = { tool in
                AccountAllowancePresentation(quota: model.quota(for: tool), now: now).estimate.map(\.remaining)
            }
            let unconfirmed: (LiveTool) -> Bool = { tool in
                AccountAllowancePresentation(quota: model.quota(for: tool), now: now).unconfirmedChair
            }
            let tools = LiveTool.active(codex: codex, claude: claude, grok: model.grokMeter)
            let seats = LiveTool.nowOccupied(codex: codex, claude: claude, grok: model.grokMeter, remaining: remaining, unconfirmed: unconfirmed)
            VStack(alignment: .leading, spacing: PageStyle.related) {
            if tools.isEmpty {
                AccountAllowanceSection(tools: seats, quota: { model.quota(for: $0) },
                                        now: now, connection: model.claudeConnection,
                                        sourcesKnown: !model.accountTools.isEmpty)
                if let empty = NowOccupancyCopy.noneWorkingLine(sourcesKnown: !model.accountTools.isEmpty, occupied: !seats.isEmpty) {
                    Text(empty).foregroundStyle(.secondary).padding(16)
                }
            } else {
                NowOccupancyStack(working: tools, remaining: { tool in
                    AccountAllowanceDisclosure(tool: tool, quota: model.quota(for: tool), now: now,
                                               connection: tool == .claude ? model.claudeConnection : nil,
                                               showsIdentity: false)
                }, header: { tool in
                    ToolSpeedHeader(tool: tool, rateSize: tools.count > 2 ? 29 : 34, meter: model.meter(for: tool))
                }, gauge: { tool in
                    let meter = model.meter(for: tool)
                    RPMGauge(value: meter.rate, minimum: meter.minimum, maximum: meter.scale,
                             measured: meter.rawRate, hasRate: meter.hasRate, unit: Binding(get: { meter.unit }, set: { meter.unit = $0 }),
                             compactLayout: true, showsReadout: false)
                        .frame(height: 180)
                }, footer: { tool in
                    VStack(alignment: .leading) {
                        Text(model.meter(for: tool).models.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let error = model.meter(for: tool).activity.error { ErrorNotice(message: error) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(tool.label + " model and activity details")
                }).overlay {
                    GeometryReader { geometry in
                        ForEach(ProviderColumnsLayout(columns: tools.count).separatorPositions(width: geometry.size.width), id: \.self) { x in
                            Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }.stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                    }.allowsHitTesting(false)
                }.padding(PageStyle.related)
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
