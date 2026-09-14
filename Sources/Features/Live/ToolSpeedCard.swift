import SwiftUI

struct ToolSpeedCard: View {
    var tool: LiveTool
    var embedded = false
    var quota: ToolQuotaState
    var now: Date
    @Bindable var meter: Tachometer
    var connection: ClaudeConnectionModel? = nil
    @State private var showActivity = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tool.label).font(PageStyle.sectionTitle)
                Spacer()
            }
            Button { showActivity = true } label: {
                Label(meter.activity.error == nil ? meter.status : "Inspect activity read failure", systemImage: meter.runningCount > 0 ? "waveform" : "pause.circle")
                    .font(.callout).foregroundStyle(.primary)
            }.buttonStyle(.plain).help("Inspect observed chats and agents")
            RateReadout(measured: meter.rawRate, hasRate: meter.hasRate, unit: $meter.unit, size: 29)
            Text(meter.hasRate ? "Estimated · \(meter.reportingCount) of \(meter.runningCount) reporting" : "Speed unavailable")
                .font(.caption).foregroundStyle(.secondary)
            if let date = meter.lastReport {
                Text("Rate report " + date.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No current rate report").font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
            ToolQuotaSummary(tool: tool, quota: quota, now: now, embedded: true, connection: connection)
            RPMGauge(value: meter.rate, minimum: meter.minimum, maximum: meter.scale,
                measured: meter.rawRate, hasRate: meter.hasRate, unit: $meter.unit,
                compactLayout: true, showsReadout: false).frame(height: 190)
            if !meter.models.isEmpty {
                Text(meter.models.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = meter.activity.error { ErrorNotice(message: error) }
        }.padding(embedded ? 0 : 18).frame(maxWidth: .infinity, alignment: .topLeading)
            .sheet(isPresented: $showActivity) {
                VStack(alignment: .trailing, spacing: 0) {
                    SheetDoneButton { showActivity = false }.padding(16)
                    RunningDetails(snapshot: meter.activity, unit: meter.unit)
                }.frame(width: 560, height: 450).onExitCommand { showActivity = false }
            }
    }
}
