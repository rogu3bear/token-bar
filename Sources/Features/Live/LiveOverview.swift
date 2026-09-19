import SwiftUI

struct LiveOverview: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    @Bindable var meter: Tachometer
    @State private var showMethod = false
    @State private var showActivity = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    @Environment(\.presentationClock) private var clock
    var body: some View {
        Group {
            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                PageHeader("Now") {
                    if monitor.busy { ProgressView().controlSize(.small) }
                }
                QuotaGuardSummary(coordinator: model.quotaGuard)
                LiveToolPanels(model: model, codex: meter, claude: model.claudeMeter)
                if let error = monitor.error { ErrorNotice(message: error) }
                MethodButton(title: "How activity and speed are measured") { showMethod = true }
                    .sheet(isPresented: $showMethod) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Activity and speed are separate").font(PageStyle.sectionTitle)
                            Text(LiveTool.liveCoverage)
                            Text("Chat and agent identity comes from the connected app’s task catalog. The latest start, completion or interruption determines each task’s state; copied turns count once. Five minutes without a log update makes activity unconfirmed, shown separately. Select the activity count to inspect the tasks.")
                            Text("Each tool has an independent rate and range. Claude activity comes from transcript user, assistant and completion records; its rate uses increasing message counters and logged elapsed time, including time between messages. Claude quota comes from its account-bound local usage cache. Readings older than two minutes remain unavailable. Each tool’s projected zero uses only its own quota changes, never token speed.")
                            Text("Speed uses output-counter differences divided by the actual time between reports, summed only across currently active tasks. Bootstrap reads existing reports immediately. Measurements stay valid for 30–120 seconds depending on reporting cadence; the reporting coverage and age are shown. Completed tasks stop contributing immediately. Logs are batched, so this remains an estimate.")
                            Text("Quota priority uses the earliest projected exhaustion. Without a projection, it shows the allowance with least remaining. Runway assumes the recent account burn continues; it is not computed from token speed.")
                            SheetDoneButton { showMethod = false }
                        }.padding(PageStyle.gutter).frame(width: 500).onExitCommand { showMethod = false }
                    }
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
            }
        }
        .sheet(isPresented: $showActivity) {
            VStack(alignment: .trailing, spacing: 0) {
                SheetDoneButton { showActivity = false }.padding(PageStyle.related)
                RunningDetails(snapshot: meter.activity, unit: meter.unit)
            }.frame(width: 560, height: 450).onExitCommand { showActivity = false }
        }
    }

}
struct RunningDetails: View {
    @Environment(\.presentationClock) private var clock
    @Environment(\.evaluationDate) private var evaluationDate
    var snapshot: ActivitySnapshot
    var unit: RateUnit = .second
    var body: some View {
        let now = evaluationDate ?? clock.now
        let tasks = snapshot.turns.values.filter(\.running).sorted { a, b in
            if a.kind != b.kind { return a.kind == .chat }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Chats & agents").font(.headline)
            if tasks.isEmpty { Text("No running tasks observed.").foregroundStyle(.secondary) }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(tasks, id: \.session) { task in
                        let age = max(0, Int(now.timeIntervalSince(task.observed)))
                        HStack(alignment: .top) {
                            Text(task.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.name.isEmpty ? String(task.session.prefix(8)) : task.name).lineLimit(2)
                                Text(age >= 300 ? "Unconfirmed · last log \(age / 60)m ago" : "Running · last log \(age)s ago")
                                    .font(.caption).foregroundStyle(age >= 300 ? Color.orange : Color.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if let sample = snapshot.measurements[task.session], now.timeIntervalSince(sample.date) < sample.lifetime, age < 300 {
                                Text(String(format: "~%.0f tok/", sample.rate * unit.multiplier) + unit.rawValue).monospacedDigit().font(.caption)
                            } else { Text("Awaiting usage").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.background(ScrollIndicatorSuppression())
            }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
            Text("Local log observations · quiet work may still be running.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
