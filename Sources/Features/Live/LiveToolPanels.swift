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
            HStack(alignment: .top, spacing: 12) {
                ForEach(tools) { tool in
                    if tool != tools.first { Divider() }
                    VStack(spacing: 12) {
                        ToolSpeedCard(tool: tool, embedded: true, quota: model.quota(for: tool),
                                      now: model.referenceDate ?? clock.now, meter: model.meter(for: tool),
                                      connection: tool == .claude ? model.claudeConnection : nil)
                    }.padding(16).frame(maxWidth: 620)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                if tools.isEmpty {
                    Text("No tools working right now").foregroundStyle(.secondary).padding(16)
                }
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .top)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: tools)
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
