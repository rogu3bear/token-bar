import SwiftUI

struct ToolSpeedHeader: View {
    var tool: LiveTool
    var rateSize: Double = 34
    @Bindable var meter: Tachometer
    @State private var showActivity = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(tool.label).font(PageStyle.sectionTitle)
                    activityButton
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tool.label).font(PageStyle.sectionTitle)
                    activityButton
                }
            }
            RateReadout(measured: meter.rawRate, hasRate: meter.hasRate, unit: $meter.unit, size: rateSize)
            Text(meter.hasRate ? "Estimated · \(meter.reportingCount) of \(meter.runningCount) reporting" : "Speed unavailable")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                if let date = meter.lastReport {
                    HStack(spacing: 4) {
                        Text("Rate report")
                        RelativeAgeText(date: date)
                        Text("ago")
                    }
                } else {
                    Text(RateReportCopy.missing)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(tool.label + " activity and speed")
            .sheet(isPresented: $showActivity) {
                VStack(alignment: .trailing, spacing: 0) {
                    SheetDoneButton { showActivity = false }.padding(16)
                    RunningDetails(snapshot: meter.activity, unit: meter.unit)
                }.frame(width: 560, height: 450).onExitCommand { showActivity = false }
            }
    }
    private var activityButton: some View {
        Button { showActivity = true } label: {
            Label(meter.activity.error == nil ? meter.status : "Inspect activity read failure", systemImage: meter.runningCount > 0 ? "waveform" : "pause.circle")
                .font(.callout).foregroundStyle(.primary)
        }.buttonStyle(.plain).help("Inspect observed chats and agents")
    }

}
