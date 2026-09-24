import SwiftUI

/// One provider module family for the popover and every host of live readings.
struct LiveToolPanels: View {
    var model: UsageModel
    @Bindable var codex: Tachometer
    @Bindable var claude: Tachometer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.presentationClock) private var clock
    @Environment(\.appAccent) private var accent
    @State private var expanded: LiveTool?
    @State private var activityTool: LiveTool?

    init(model: UsageModel, codex: Tachometer, claude: Tachometer, initiallyExpanded: LiveTool? = nil) {
        self.model = model; self.codex = codex; self.claude = claude
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let now = model.referenceDate ?? clock.now
        let tools = LiveTool.modules(known: model.accountTools, codex: codex, claude: claude, grok: model.grokMeter,
                                     quota: { model.quota(for: $0) }, now: now)
        VStack(alignment: .leading, spacing: 10) {
            if tools.isEmpty {
                Text("Use Codex, Claude Code or Grok to see its readings here.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(tools) { tool in
                let quota = model.quota(for: tool)
                let allowance = AccountAllowancePresentation(quota: quota, now: now)
                let warning = model.quotaGuard.decisions.first { $0.tool == tool && $0.risk != .none }
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            expanded = expanded == tool ? nil : tool
                        }
                    } label: {
                        CompactToolRate(tool: tool, meter: model.meter(for: tool), quota: quota, now: now,
                                        expanded: expanded == tool, warning: warning.map { warningCopy($0, now: now) })
                    }.buttonStyle(.plain)
                    if expanded == tool {
                        Divider().padding(.horizontal, 12)
                        VStack(alignment: .leading, spacing: 12) {
                            providerDetails(tool, allowance: allowance, now: now)
                            if let warning {
                                HStack {
                                    Button("View allowance") { model.quotaGuard.view(warning) }
                                    Button(model.quotaGuard.isSnoozed(warning) ? "Snoozed" : "Snooze 30 min") { model.quotaGuard.snooze(warning) }
                                        .disabled(model.quotaGuard.isSnoozed(warning))
                                }.controlSize(.small)
                            }
                        }.padding(12)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(warning == nil ? Color.primary.opacity(0.08) : .orange.opacity(0.5), lineWidth: 1))
            }
        }
        .sheet(item: $activityTool) { tool in
            VStack(alignment: .trailing, spacing: 0) {
                SheetDoneButton { activityTool = nil }.padding(PageStyle.related)
                RunningDetails(snapshot: model.meter(for: tool).activity, unit: model.meter(for: tool).unit)
            }.frame(width: 560, height: 450).onExitCommand { activityTool = nil }
        }
    }

    @ViewBuilder private func providerDetails(_ tool: LiveTool, allowance: AccountAllowancePresentation, now: Date) -> some View {
        let meter = model.meter(for: tool)
        HStack {
            Text("Output speed").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Rate unit", selection: Binding(get: { meter.unit }, set: { meter.unit = $0 })) {
                ForEach(RateUnit.allCases) { Text("tok/" + $0.rawValue).tag($0) }
            }.labelsHidden().fixedSize().accessibilityLabel(tool.label + " rate unit")
        }
        if let reading = allowance.reading {
            LabeledContent("Provider allowance", value: reading.windowLabel)
            LabeledContent("Reset", value: reading.resetWhen ?? "Unavailable")
            if let zero = allowance.estimate?.exhaustion {
                LabeledContent("Projected exhaustion", value: Runway.clockLabel(zero, now: now))
            }
            ReadAgeCaption(date: reading.date, prefix: "Allowance read").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(allowance.detail).font(.caption).foregroundStyle(.secondary)
        }
        if let label = model.quota(for: tool).accountLabel {
            Text(label).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        HStack {
            Button { activityTool = tool } label: { Text("Chats & agents").foregroundStyle(accent) }.buttonStyle(.plain)
            Spacer()
            Text(meter.models.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        if let error = meter.activity.error { ErrorNotice(message: error) }
    }

    private func warningCopy(_ decision: QuotaGuardDecision, now: Date) -> String {
        if decision.risk == .observedExhaustion { return "Allowance exhausted" }
        if let forecast = decision.forecast { return "May run out " + Runway.clockLabel(forecast, now: now) }
        return "Allowance warning · " + (decision.remaining.map { CompactLiveCopy.percent($0) + " remaining" } ?? "reading unavailable")
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
