import SwiftUI

/// Canonical live face. The popover and optional larger host use this same tree.
struct LiveOverview: View {
    @Bindable var meter: Tachometer
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    var initiallyExpanded: LiveTool? = nil
    @Environment(\.nativeCommands) private var commands
    @State private var showMethod = false
    @State private var showSources = false

    private var sourceErrors: [String] {
        ([monitor.error, model.quotaGuard.persistenceError] +
         LiveTool.allCases.map { model.meter(for: $0).activity.error }).compactMap { $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Now").font(.headline)
                Spacer()
                if monitor.busy { ProgressView().controlSize(.small).accessibilityLabel("Refreshing allowances") }
                MethodButton(title: "Method") { showMethod = true }
            }
            LiveToolPanels(model: model, codex: meter, claude: model.claudeMeter, initiallyExpanded: initiallyExpanded)
            CompactUsageBar(packed: model.usageStore.compactUsage, now: model.referenceDate ?? model.clock.now, action: { commands.reports(.history) })
            if !sourceErrors.isEmpty || !model.snapshot.readHealth.diagnostics.isEmpty {
                Button { showSources = true } label: {
                    Label("Sources need attention", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }
            ImportStatusView(model: model, inset: 0)
            if let release = model.updateCheck.availableRelease {
                UpdateAvailableNotice(check: model.updateCheck, release: release)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            GlassControlGroup {
                HStack {
                    Button("Reports") { commands.reports(nil) }.keyboardShortcut("r", modifiers: .command)
                    Button("Settings") { commands.settings() }.keyboardShortcut(",", modifiers: .command)
                    Spacer()
                    Menu {
                        Button("Feedback") {
                            if !Feedback.open() { model.message = "Could not open feedback in your browser." }
                        }
                        Button("Quit Token Bar") { NSApplication.shared.terminate(nil) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Token Bar actions")
                }
            }.controlSize(.small)
        }
        .padding(16).frame(maxWidth: 480, alignment: .leading)
        .environment(\.evaluationDate, model.referenceDate)
        .sheet(isPresented: $showMethod) { LiveMethod { showMethod = false } }
        .sheet(isPresented: $showSources) {
            MethodSheet(title: "Data sources", done: { showSources = false }) {
                UsageDiagnosticsView(health: model.snapshot.readHealth)
                ForEach(Array(sourceErrors.enumerated()), id: \.offset) { _, error in
                    ErrorNotice(message: error)
                }
                Text("Available readings remain visible. A source error does not turn missing usage into zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LiveMethod: View {
    var done: () -> Void
    var body: some View {
        MethodSheet(title: "How live readings work", done: done) {
            Text("Output speed").font(.headline)
            Text("Estimated from output-counter changes and elapsed time. Each tool has its own rate and units. Completed tasks stop contributing; missing or expired measurements show —.")
            Text("Provider allowance").font(.headline)
            Text(LiveTool.liveCoverage)
            Text("Remaining is provider allowance, not a token balance. Projected exhaustion uses recent allowance burn, never output speed. Missing reset times stay unavailable. Claude readings remain current for 30 minutes and show their age after two minutes.")
            Text("Activity and recorded usage").font(.headline)
            Text("Task lifecycle and counter observations identify activity. Quiet work becomes unconfirmed after five minutes. Today's chart contains recorded tokens; account associations in history are inferred from stable local sign-in observations.")
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
                                Text(CompactLiveCopy.rate(true, amount: sample.rate * unit.multiplier, unit: unit)).monospacedDigit().font(.caption)
                            } else { Text("Awaiting usage").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.background(ScrollIndicatorSuppression())
            }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
            Text("Local log observations · quiet work may still be running.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
