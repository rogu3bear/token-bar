import Observation
import AppKit
import SwiftUI
import ServiceManagement

@Observable final class UsageModel {
    let usageStore: UsageStore
    let reporting = ReportState()
    let comparisons = UsageComparisonStore()
    let quotaGuard: QuotaGuardCoordinator
    let clock = PresentationClock()
    private var sourceRevision: UInt64 { usageStore.revision }
    private var catalogRevision: UInt64 { reporting.catalogRevision }
    private let reportEngine: ReportEngine
    var snapshot: Snapshot { get { usageStore.snapshot } set { usageStore.snapshot = newValue } }
    var lastSuccessfulUsageRead: Date? { get { usageStore.lastSuccessfulUsageRead } set { usageStore.lastSuccessfulUsageRead = newValue } }
    var busy: Bool { get { usageStore.busy } set { usageStore.busy = newValue } }
    var period: Int { get { reporting.period } set { reporting.period = newValue } }
    var toolFilter: String { get { reporting.toolFilter } set { reporting.toolFilter = newValue } }
    var availableTools: [String] { get { reporting.availableTools } set { reporting.availableTools = newValue } }
    var modelFilter: String { get { reporting.modelFilter } set { reporting.modelFilter = newValue } }
    var accountFilter: String { get { reporting.accountFilter } set { reporting.accountFilter = newValue } }
    var search: String { get { reporting.search } set { reporting.search = newValue } }
    var startDate: Date { get { reporting.startDate } set { reporting.startDate = newValue } }
    var endDate: Date { get { reporting.endDate } set { reporting.endDate = newValue } }
    var report: UsageReport { get { reporting.report } set { reporting.report = newValue } }
    var costReport: CostReport { get { reporting.costReport } set { reporting.costReport = newValue } }
    var costEffort: String { get { reporting.costEffort } set { reporting.costEffort = newValue } }
    var costService: CostService { get { reporting.costService } set { reporting.costService = newValue } }
    var costBasis: CostPriceBasis { get { reporting.costBasis } set { reporting.costBasis = newValue } }
    var retainedRequests: Int? { get { usageStore.retainedRequests } set { usageStore.retainedRequests = newValue } }
    var exportingRequests: Bool { get { reporting.exportingRequests } set { reporting.exportingRequests = newValue } }
    var availableEfforts: [String] { get { reporting.availableEfforts } set { reporting.availableEfforts = newValue } }
    var costRecoveryMessage: String? { get { usageStore.costRecoveryMessage } set { usageStore.costRecoveryMessage = newValue } }
    var progress: ImportProgress? { get { usageStore.progress } set { usageStore.progress = newValue } }
    var filtering: Bool { get { reporting.filtering } set { reporting.filtering = newValue } }
    var detailedReporting = false
    @ObservationIgnored private var cachedCatalog: [String: TaskInfo] = [:]
    @ObservationIgnored private var catalogUpdated = Date.distantPast
    var availableModels: [String] { get { reporting.availableModels } set { reporting.availableModels = newValue } }
    var availableAccounts: [Account] { get { reporting.availableAccounts } set { reporting.availableAccounts = newValue } }
    var catalog: [String: TaskInfo] { get { reporting.catalog } set { reporting.catalog = newValue } }
    var showDetails: (() -> Void)?
    var showHistory: (() -> Void)?
    var showMenuBarSettings: (() -> Void)?
    var referenceDate: Date?
    let allowsSystemSettings: Bool
    let menuBarPreferences: MenuBarPreferences
    let appearance: AppearancePreferences
    let provenanceNotices: ProvenanceNotices
    private let reportQueue = DispatchQueue(label: "local.codex-token-bar.report", qos: .utility, autoreleaseFrequency: .workItem)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reportPending = false
    var message: String? { get { usageStore.message } set { usageStore.message = newValue } }
    var changed: (() -> Void)?
    var scanner: UsageScanner { usageStore.scanner }
    let claudeQuota: ClaudeQuotaMonitor
    let claudeConnection: ClaudeConnectionModel
    let grokQuota: GrokQuotaMonitor
    let live: LiveMonitor
    let signIns: SignInTimeline
    let tachometer: Tachometer
    let claudeMeter: Tachometer
    let grokMeter: Tachometer
    var accountRelevance = AccountToolRelevance()
    var accountTools: [LiveTool] { accountRelevance.tools }
    /// Watches existing in-memory evidence. No provider or filesystem work in presentation.
    private func observeAccountTools() {
        let refresh: @MainActor @Sendable () -> Void = { [weak self] in self?.observeAccountTools() }
        let evidence = withObservationTracking {
            LiveTool.allCases.map { tool in
                let state = quota(for: tool)
                let meter = meter(for: tool)
                return (tool, (tool == .codex && (live.currentID != nil || !live.state.accounts.isEmpty)) || state.guardAccountID != nil,
                        !state.readings.isEmpty || !state.samples.isEmpty,
                        meter.hasRate || !meter.activity.turns.isEmpty,
                        tool == .claude && claudeConnection.status != .notConnected)
            }
        } onChange: {
            DispatchQueue.main.async { refresh() }
        }
        for (tool, account, quota, activity, configured) in evidence {
            accountRelevance.observe(tool, discovered: configured, account: account, quota: quota, activity: activity)
        }
    }
    var menuTool: LiveTool { (menuBarPreferences.configuration.tool ?? .auto).resolve(codex: tachometer, claude: claudeMeter, grok: grokMeter) }
    var menuMeter: Tachometer { meter(for: menuTool) }
    func meter(for tool: LiveTool) -> Tachometer { tool == .grok ? grokMeter : tool == .claude ? claudeMeter : tachometer }
    let insights: InsightsModel
    let usageInsights: UsageInsightsModel
    @ObservationIgnored lazy var activityFeed = ActivityFeed(home: scanner.home, grokHome: scanner.grokHome, claudeHome: scanner.claudeHome) { [weak self] snapshot in
        self?.tachometer.apply(snapshot.filtered(for: .codex))
        self?.claudeMeter.apply(snapshot.filtered(for: .claude))
        self?.grokMeter.apply(snapshot.filtered(for: .grok))
    }
    @ObservationIgnored var sourceRootsChanged: ((URL?, URL?) -> Void)?
    private let discoversSources: Bool
    @ObservationIgnored private var pendingPaths = Set<URL>()
    @ObservationIgnored private var pendingDiscovery = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    func flushUsage() {
        queue.sync {
            saveWork?.cancel()
            do { try scanner.saveIfNeeded(force: true) }
            catch { NSLog("Token Bar could not flush usage history: %@", error.localizedDescription) }
        }
    }
    private func scheduleSave(retrying: Bool = false) {
        guard scanner.needsSave else { return }
        saveWork?.cancel()
        let delay = retrying ? 15 : max(0, 15 - Date().timeIntervalSince(scanner.lastSave))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.scanner.saveIfNeeded(force: true) }
            catch {
                DispatchQueue.main.async { self.message = "Usage history could not be saved: " + error.localizedDescription }
                self.scheduleSave(retrying: true)
            }
        }
        saveWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private let queue = DispatchQueue(label: "local.codex-token-bar.scan", qos: .utility, autoreleaseFrequency: .workItem)
    init(previewRoot: URL? = nil, defaults: UserDefaults = .standard, referenceDate: Date? = nil) {
        precondition(referenceDate == nil || previewRoot != nil, "A fixed clock requires an isolated profile")
        self.referenceDate = referenceDate
        discoversSources = previewRoot == nil
        usageInsights = UsageInsightsModel(clock: { referenceDate ?? Date() })
        allowsSystemSettings = previewRoot == nil
        tachometer = Tachometer(tool: .codex, defaults: defaults)
        claudeMeter = Tachometer(tool: .claude, defaults: defaults)
        grokMeter = Tachometer(tool: .grok, defaults: defaults)
        menuBarPreferences = MenuBarPreferences(defaults: defaults)
        appearance = AppearancePreferences(defaults: defaults)
        provenanceNotices = ProvenanceNotices(defaults: defaults)
        let home = previewRoot ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let grokHome = previewRoot.map { $0.appendingPathComponent("grok") }
            ?? ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        let support = previewRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        quotaGuard = QuotaGuardCoordinator(url: support.appendingPathComponent("CodexTokenBar/quota-guard.json"),
            adapter: previewRoot == nil ? QuotaGuardNotifications() : nil, clock: { referenceDate ?? Date() })
        insights = InsightsModel(clock: { referenceDate ?? Date() }, storageURL: support.appendingPathComponent("CodexTokenBar/prompt-index"), home: home)
        reportEngine = ReportEngine(storageURL: support.appendingPathComponent("CodexTokenBar/report-index.json"))
        // A preview never reads real transcripts. Otherwise each tool is
        // enabled only where it is actually installed.
        let claudeHome = previewRoot == nil ? HarnessDiscovery.claudeCode() : nil
        let openCodeHome = previewRoot == nil ? HarnessDiscovery.openCode() : nil
        usageStore = UsageStore(scanner: UsageScanner(home: home, stateURL: support.appendingPathComponent("CodexTokenBar/ledger.json"),
                               grokHome: grokHome, claudeHome: claudeHome, openCodeHome: openCodeHome), referenceDate: referenceDate)
        signIns = SignInTimeline(home: home, file: support.appendingPathComponent("CodexTokenBar/sign-ins.json"))
        let claudeConfig = previewRoot.map { $0.appendingPathComponent("claude.json") }
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        // The relay file is what claude-statusline-relay.sh writes when the user
        // adds it to Claude Code's status line; absent means cache-only readings.
        let claudeRelay = previewRoot.map { $0.appendingPathComponent("claude-statusline.json") }
            ?? support.appendingPathComponent("CodexTokenBar/claude-statusline.json")
        claudeQuota = ClaudeQuotaMonitor(cacheURL: claudeConfig, relayURL: claudeRelay)
        if previewRoot == nil {
            claudeConnection = ClaudeConnectionModel(settingsURL: ClaudeStatuslineConnection.settingsURL(),
                                                     relayURL: ClaudeStatuslineConnection.stableRelayURL(support: support),
                                                     bundleRelayURL: Bundle.main.url(forResource: "claude-statusline-relay", withExtension: "sh"),
                                                     defaults: defaults)
        } else {
            // Previews show the connected control unless `--claude-connection
            // not-connected|configured` asks for another state; sparse page states start not connected.
            let requested = CommandLine.arguments.firstIndex(of: "--claude-connection").flatMap { index -> ClaudeConnectionModel.Status? in
                guard CommandLine.arguments.indices.contains(index + 1) else { return nil }
                switch CommandLine.arguments[index + 1] {
                case "not-connected": return .notConnected
                case "configured": return .configured
                case "connected": return .connected
                default: return nil
                }
            }
            let sparse = ["empty", "failed", "--sample-no-accounts"].contains { CommandLine.arguments.contains($0) }
            claudeConnection = ClaudeConnectionModel(fixture: requested ?? (sparse ? .notConnected : .connected))
        }
        grokQuota = GrokQuotaMonitor(home: grokHome, enabled: previewRoot == nil)
        live = LiveMonitor(home: home, stateURL: support.appendingPathComponent("CodexTokenBar/live-accounts.json"))
        snapshot = scanner.currentSnapshot()
        snapshot.updated = nil // Loading saved history is not a successful source scan.
        scanner.onSnapshot = { [weak self] result in
            DispatchQueue.main.async { self?.publish(result) }
        }
        if let referenceDate {
            startDate = Calendar.current.date(byAdding: .day, value: -29, to: referenceDate)!
            endDate = referenceDate
        }
        reporting.queryChanged = { [weak self] in
            guard let self else { return }
            self.queryGeneration &+= 1; self.rebuild()
        }
        live.comparisonChanged = { [weak self] in self?.refreshComparisons() }
        publish(snapshot)
        quotaGuard.update(guardInputs())
        if previewRoot == nil {
            accountRelevance.observe(.codex, discovered: CodexInstallation.executable() != nil)
            accountRelevance.observe(.claude, discovered: claudeHome != nil)
            accountRelevance.observe(.grok, discovered: HarnessDiscovery.grok() != nil)
        }
        observeAccountTools()
    }
    func quota(for tool: LiveTool) -> ToolQuotaState {
        if tool == .grok { return grokQuota.quota }
        if tool == .claude { return claudeQuota.quota }
        let account = live.currentID.flatMap { live.state.accounts[$0] }
        return ToolQuotaState(readings: account?.quotas ?? [], samples: live.state.samples, unavailable: "Awaiting fresh Codex quota", accountLabel: account.map { $0.email + " · " + $0.plan.uppercased() },
                              guardAccountID: live.currentID, guardFailed: live.error != nil)
    }
    var periodChoices: [(Int, String)] {
        var choices = [(0, "Today"), (6, "This week"), (2, "Last 7 days"), (3, "Last 30 days"), (1, "All history"), (4, "Custom dates")]
        if signIns.lastSwitchDate != nil || period == 5 { choices.insert((5, "Since sign-in"), at: 3) }
        return choices
    }
    var entries: [Entry] { report.entries }
    var totals: Tokens { report.totals }
    @ObservationIgnored private var queryGeneration: UInt64 = 0
    @ObservationIgnored private(set) var reportPublicationCount = 0
    @ObservationIgnored var reportPublished: ((UsageReport) -> Void)?
    @ObservationIgnored private var reportInputs: ReportRevisionInputs?
    @ObservationIgnored private var inFlightInputs: ReportRevisionInputs?
    @ObservationIgnored private var reportValidity: ReportValidity?
    func rebuild() {
        // Keep the process-owned report warm; navigation only consumes it.
        refreshComparisons()
        let now = referenceDate ?? Date()
        let inputs = ReportRevisionInputs(entries: sourceRevision, catalog: catalogRevision, query: costQuery, effort: costEffort, service: costService, basis: costBasis)
        if !filtering, inputs == reportInputs, reportValidity?.contains(now) == true { return }
        if filtering && inputs == inFlightInputs { return }
        generation += 1
        if filtering { reportPending = true; return }
        reportPending = false
        let version = generation
        let queryVersion = queryGeneration
        let query = costQuery
        let source = snapshot.entries, catalog = catalog
        let sourceID = snapshot.contentID
        let effort = costEffort, service = costService, basis = costBasis
        filtering = true
        inFlightInputs = inputs
        let archiveURL = scanner.requestArchiveURL
        reportQueue.async {
            let (result, costs) = self.reportEngine.build(source: source, inputs: inputs, catalog: catalog, now: now, sourceID: sourceID) { selected in
                guard let archive = try? RequestArchive(url: archiveURL, readOnly: true) else { return nil }
                return try? TimelineDetail.expand(selected, archive: archive)
            }
            let validity = self.reportEngine.validity
            let storageError = self.reportEngine.storageError
            DispatchQueue.main.async {
                if self.queryGeneration == queryVersion && self.costQuery == query && self.costEffort == effort && self.costService == service && self.costBasis == basis {
                    self.report = result; self.costReport = costs
                    if let storageError { self.message = storageError }
                    self.reportPublicationCount += 1
                    self.reportPublished?(result)
                    self.reportInputs = inputs
                    self.reportValidity = validity
                }
                self.filtering = false
                self.inFlightInputs = nil
                if self.reportPending || self.generation != version { self.rebuild() }
            }
        }
    }
    func refreshComparisons() {
        comparisons.refresh(source: snapshot.entries, revision: sourceRevision, quotaRevision: live.comparisonRevision,
                            state: live.state, currentID: live.currentID, query: costQuery, effort: costEffort,
                            now: referenceDate ?? Date(), archiveURL: scanner.requestArchiveURL, archiveCount: retainedRequests)
    }
    @ObservationIgnored private var publishedRevision: UInt64?
    private func publish(_ result: Snapshot) {
        snapshot = result
        if result.error == nil { lastSuccessfulUsageRead = result.updated }
        if publishedRevision != sourceRevision {
            for entry in result.entries {
                switch HistoryTool.recorded(entry) {
                case .codex: accountRelevance.observe(.codex, discovered: true)
                case .claude: accountRelevance.observe(.claude, discovered: true)
                case .grok: accountRelevance.observe(.grok, discovered: true)
                case .other, .unknown: break
                }
            }
            availableTools = Array(Set(result.entries.map { $0.harness ?? "Unattributed" })).sorted()
            availableModels = Array(Set(result.entries.map(\.model))).sorted()
            availableAccounts = Dictionary(result.entries.compactMap { $0.account }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.label < $1.label }
            availableEfforts = Array(Set(result.entries.map { $0.effort ?? "Unknown" })).sorted()
            publishedRevision = sourceRevision
        }
        rebuild()
        if !usageInsights.hasResult {
            usageInsights.refresh(entries: result.entries, catalog: catalog,
                                  sourceAvailable: result.error == nil || !result.entries.isEmpty,
                                  revision: result.contentID, catalogRevision: catalogRevision)
        }
        changed?()
    }
    func refresh(history: Bool = false, paths: Set<URL>? = nil, recoverCosts: Bool = false) {
        guard !busy else { if let paths { pendingPaths.formUnion(paths) } else { pendingDiscovery = true }; return }; busy = true
        if history { progress = .discovering }
        queue.async {
            if history && self.discoversSources {
                let claude = HarnessDiscovery.claudeCode(), openCode = HarnessDiscovery.openCode()
                if self.scanner.configureSources(claudeHome: claude, openCodeHome: openCode) {
                    DispatchQueue.main.async {
                        self.accountRelevance.observe(.claude, discovered: claude != nil)
                        self.activityFeed.configureClaude(home: claude)
                        self.sourceRootsChanged?(claude, openCode)
                    }
                }
            }
            var lastProgress = Date.distantPast
            func showProgress(_ value: ImportProgress, completed: Int, total: Int) {
                guard history else { return }
                let now = Date()
                guard completed == 0 || completed == total || now.timeIntervalSince(lastProgress) >= 0.1 else { return }
                lastProgress = now
                DispatchQueue.main.async { self.progress = value }
            }
            var result = self.scanner.scan(historical: history, changedPaths: paths, toolProgress: { tool, done, total in
                showProgress(.work(title: "Reading \(tool) history", completed: done, total: total,
                                   unit: tool == "OpenCode" ? "records" : "files"), completed: done, total: total)
            }, progress: { done, total in
                showProgress(.codex(completed: done, total: total), completed: done, total: total)
            })
            if history { result = self.scanner.scan() }
            DispatchQueue.main.async { [result] in self.publish(result) }
            var recovery = self.scanner.ledger.costRecoverySummary
            if history && (recoverCosts || ((self.scanner.ledger.costMetadataVersion ?? 0) < 2 && self.scanner.ledger.entries.contains(where: { ($0.costMetadataVersion ?? 0) < 2 }))) {
                DispatchQueue.main.async { self.progress = .costDetails }
                do {
                    recovery = try self.scanner.recoverCostDetails(progress: { done, total in
                        showProgress(.work(title: "Checking Codex cost files", completed: done, total: total, unit: "files"), completed: done, total: total)
                    }, phase: { _ in
                        DispatchQueue.main.async { self.progress = .costDetails }
                    })
                    result.entries = self.scanner.ledger.entries
                    result.contentID = self.scanner.ledger.reportRevision
                } catch { recovery = error.localizedDescription }
            }
            if TaskCatalog.shouldRefresh(home: self.scanner.home, paths: paths, historical: history, lastRead: self.catalogUpdated, now: Date()) {
                if history { DispatchQueue.main.async { self.progress = .catalog } }
                do {
                    self.cachedCatalog = try TaskCatalog.read(home: self.scanner.home)
                    self.catalogUpdated = Date()
                } catch {
                    result.error = [result.error, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")
                }
            }
            self.scheduleSave()
            let catalog = self.cachedCatalog
            let retained = try? self.scanner.requestArchive?.count
            let recoveredMessage = recovery
            DispatchQueue.main.async {
                self.snapshot = result; self.catalog = catalog
                self.retainedRequests = retained; self.costRecoveryMessage = recoveredMessage
                self.busy = false; self.progress = nil; self.publish(result)
                if self.pendingDiscovery {
                    self.pendingDiscovery = false; self.pendingPaths = []
                    self.refresh(history: true)
                } else if !self.pendingPaths.isEmpty {
                    let pending = self.pendingPaths; self.pendingPaths = []
                    self.refresh(paths: pending)
                }
            }
        }
    }
    var costSourceAvailable: Bool { snapshot.error == nil || lastSuccessfulUsageRead != nil || !costReport.lines.isEmpty }
    var costQuery: UsageQuery {
        UsageQuery(period: period, start: period == 5 ? (signIns.lastSwitchDate ?? Date()) : startDate, end: endDate, model: modelFilter, account: accountFilter, search: search, harness: toolFilter)
    }
    /// Clear applicable record restrictions, preserving the shared period and pricing assumptions.
    func clearReportFilters(includesCost: Bool) {
        toolFilter = "All tools"
        modelFilter = "All models"
        accountFilter = "All accounts"
        search = ""
        if includesCost { costEffort = "All levels" }
    }
    func exportRequests() {
        guard !filtering && !busy && !exportingRequests else { return }
        let query = costQuery, catalog = catalog, effort = costEffort, now = Date()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "token-request-details.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportingRequests = true
        queue.async {
            let result: String
            do {
                guard let archive = self.scanner.requestArchive else { throw RequestArchive.failure("Request archive is unavailable") }
                let count = try RequestExport.write(archive: archive, destination: url, query: query, catalog: catalog, effort: effort, now: now)
                result = "Exported \(count.formatted()) retained usage records. Aggregate deltas are identified in the CSV."
            } catch { result = "Request export failed: " + error.localizedDescription }
            DispatchQueue.main.async { self.message = result; self.exportingRequests = false }
        }
    }
    func exportCosts() {
        guard !filtering && !busy else { return }
        let csv = costReport.csv(service: costService)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "token-cost-estimates.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8); message = "Cost estimate CSV exported." }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }
    func export() {
        guard !filtering && !busy else { return }
        let csv = report.csv()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "token-usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            message = "CSV exported."
        } catch { message = "Export failed: \(error.localizedDescription)" }
    }

}
struct QuickLiveView: View {
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    @Bindable var meter: Tachometer
    @Bindable var claude: Tachometer
    @State private var expanded: LiveTool?
    init(model: UsageModel, monitor: LiveMonitor, meter: Tachometer) {
        self.model = model; self.monitor = monitor; self.meter = meter; self.claude = model.claudeMeter
    }
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Now").font(.headline); Spacer(); if monitor.busy { ProgressView().controlSize(.small) } }
                let tools = model.accountTools
                ForEach(tools) { tool in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            expanded = expanded == tool ? nil : tool
                        }
                    } label: {
                        CompactToolRate(tool: tool, meter: model.meter(for: tool), quota: model.quota(for: tool), now: model.referenceDate ?? model.clock.now, expanded: expanded == tool)
                    }.buttonStyle(.plain)
                }
                if tools.isEmpty {
                    Text("No account sources detected yet. Open a supported tool to begin.").foregroundStyle(.secondary)
                }
                QuotaGuardSummary(coordinator: model.quotaGuard, compact: true)
                ToolActivityErrors(model: model)
                CompactUsageBar(packed: model.usageStore.compactUsage, now: model.referenceDate ?? model.clock.now, action: model.showHistory)
                if let error = monitor.error { ErrorNotice(message: error) }
                HStack {
                    Button("Dashboard") { model.showDetails?() }.buttonStyle(.borderedProminent)
                    Button("Menu bar settings") { model.showMenuBarSettings?() }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                    Spacer()
                    Button {
                        if !Feedback.open() { model.message = "Could not open feedback in your browser." }
                    } label: {
                        Text("Feedback").foregroundStyle(accent)
                    }.buttonStyle(.plain).help("Send feedback")
                }
                ImportStatusView(model: model, inset: 0)
            }.padding(16).frame(width: 440).fixedSize(horizontal: false, vertical: true)
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = UsageModel()
    private var monitoringStarted = false
    var item: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    var providerTimer: Timer?
    var stream: LogStream?
    var meterTimer: Timer?
    let dashboardSelection = DashboardSelection()
    var detailWindow: NSWindow?
    var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let firstRun = FirstRunAccess.needsExplanation(.standard)
        if firstRun {
            guard FirstRunWelcome.present() else { NSApp.terminate(nil); return }
            FirstRunAccess.accept(.standard)
        }
        monitoringStarted = true
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◈ …"
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        let quickHost = NSHostingController(rootView: AppearanceHost(preferences: model.appearance, clock: model.clock) { [model] in QuickLiveView(model: model, monitor: model.live, meter: model.tachometer) })
        quickHost.sizingOptions = [.preferredContentSize]
        popover.contentViewController = quickHost
        model.changed = { [weak self] in
            guard let self else { return }
            self.item.button?.toolTip = "Token Bar · click for details and settings"
        }
        configureNavigationActions()
        observeStatusItem()
        model.signIns.observe(start: true)
        model.sourceRootsChanged = { [weak self] claude, openCode in
            self?.watchSources(claudeHome: claude, openCodeHome: openCode)
        }
        watchSources(claudeHome: model.scanner.claudeHome, openCodeHome: model.scanner.openCodeHome)
        model.refresh(history: true)
        model.activityFeed.refresh()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self else { return }
            let now = Date()
            self.model.clock.now = now
            self.model.quotaGuard.tick()
            self.model.usageStore.updateCompactUsage(now: now)
            self.model.tachometer.tick(now: now)
            self.model.claudeMeter.tick(now: now)
            self.model.grokMeter.tick(now: now)
            self.updateStatusItem(now: now)
            if self.detailWindow?.isVisible == true && self.model.detailedReporting { self.model.rebuild() }
            }
        }
        if let meterTimer { RunLoop.main.add(meterTimer, forMode: .common) }

        model.live.refresh()
        model.claudeConnection.installRelay()
        model.claudeQuota.refresh()
        model.claudeConnection.refresh(relayObserved: model.claudeQuota.relayObserved)
        model.grokQuota.refresh()
        providerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.live.refresh(); self.model.claudeQuota.refresh(); self.model.grokQuota.refresh()
                self.model.claudeConnection.refresh(relayObserved: self.model.claudeQuota.relayObserved)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.activityFeed.refresh()
                self?.model.refresh(history: true)
            }
        }
        if let providerTimer { RunLoop.main.add(providerTimer, forMode: .common) }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if firstRun || CommandLine.arguments.contains("--details") { model.period = 1; DispatchQueue.main.async { self.openDetails() } }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() } }
    }
    private var watcherRevision = 0
    private func watchSources(claudeHome: URL?, openCodeHome: URL?) {
        watcherRevision += 1
        let revision = watcherRevision
        stream?.stop()
        stream = LogStream(home: model.scanner.home, grokHome: model.scanner.grokHome,
            claudeHome: claudeHome, openCodeHome: openCodeHome,
            onFiles: { [weak self] paths in
                guard let self, self.watcherRevision == revision else { return }
                self.model.activityFeed.refresh(paths: paths)
                self.model.refresh(paths: paths)
            }, onAccount: { [weak self] in
                guard let self, self.watcherRevision == revision else { return }
                self.model.signIns.observe(); self.model.live.refresh(); self.model.refresh(paths: [])
            })
        stream?.start()
    }
    private let statusAnimator = MenuBarValueAnimator()
    private var statusUpdatePending = false
    func observeStatusItem() {
        withObservationTracking {
            updateStatusItem()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.statusUpdatePending else { return }
                self.statusUpdatePending = true
                DispatchQueue.main.async {
                    self.statusUpdatePending = false
                    self.observeStatusItem()
                }
            }
        }
    }
    func updateStatusItem(now: Date = Date()) {
        let presentation = MenuBarPresentation.combined(model.menuBarPreferences.configuration,
            codex: model.tachometer, claude: model.claudeMeter, grok: model.grokMeter,
            monitor: model.live, now: now, palette: model.appearance.toolPalette,
            claudeQuota: model.claudeQuota.quota, grokQuota: model.grokQuota.quota,
            riskText: model.quotaGuard.menuText(selection: model.menuBarPreferences.configuration.tool))
        guard let button = item.button else { return }
        statusAnimator.update(presentation, in: button, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak button] in
            button?.attributedTitle = $0
        }
        button.setAccessibilityLabel(presentation.string)
        button.toolTip = presentation.string
    }
    func applicationWillTerminate(_ notification: Notification) {
        statusAnimator.cancel()
        guard monitoringStarted else { return }
        model.flushUsage()
        timer?.invalidate(); providerTimer?.invalidate(); meterTimer?.invalidate(); stream?.stop(); model.live.stop(); model.grokQuota.stop()
    }
    func configureNavigationActions() {
        observeQuotaGuard()
        model.quotaGuard.reveal = { [weak self] in self?.openDetails(destination: .now) }
        model.showDetails = { [weak self] in self?.openDetails() }
        model.showHistory = { [weak self] in self?.openDetails(destination: .history) }
        model.showMenuBarSettings = { [weak self] in self?.openMenuBarSettings() }
    }
    func openDetails(destination: Destination? = nil) {
        if let destination { dashboardSelection.destination = destination }
        popover.performClose(nil)
        if detailWindow == nil {
            model.detailedReporting = dashboardSelection.destination.requiresDetailedReporting
            if model.detailedReporting { model.rebuild() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Token Bar — Dashboard"
            window.contentViewController = NSHostingController(rootView: AppearanceHost(preferences: model.appearance, clock: model.clock) { [model, dashboardSelection] in DetailRoot(model: model, selection: dashboardSelection) })
            window.contentMinSize = NSSize(width: 900, height: 700)
            if model.allowsSystemSettings { window.setFrameAutosaveName("UsageDetails") }
            window.isReleasedWhenClosed = false
            window.center()
            detailWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }
    func openMenuBarSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Token Bar — Menu bar settings"
            window.contentViewController = NSHostingController(rootView: AppearanceHost(preferences: model.appearance, clock: model.clock) { [model] in MenuBarSettingsView(allowsSystemSettings: model.allowsSystemSettings, preferences: model.menuBarPreferences, meter: model.tachometer, claudeMeter: model.claudeMeter, grokMeter: model.grokMeter, monitor: model.live, claudeQuota: model.claudeQuota, grokQuota: model.grokQuota, claudeConnection: model.claudeConnection, quotaGuard: model.quotaGuard) })
            window.isReleasedWhenClosed = false
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            let mode = model.appearance.mode
            popover.appearance = mode == "System" ? nil : NSAppearance(named: mode == "Dark" ? .darkAqua : .aqua)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--preview-quota-guard") || CommandLine.arguments.contains("--render-quota-guard") {
            let arguments = CommandLine.arguments
            let destination = arguments.firstIndex(of: "--render-quota-guard").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            if arguments.contains("--render-quota-guard") && destination == nil { print("Missing quota preview output path"); exit(1) }
            do { try QuotaGuardPreview.run(destination: destination) }
            catch { print("Quota Guard preview failed: " + error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--preview-welcome") {
            _ = NSApplication.shared
            print(FirstRunWelcome.present() ? "Preview accepted; no monitoring started or preferences saved." : "Preview dismissed; no monitoring started or preferences saved.")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-welcome") {
            guard CommandLine.arguments.indices.contains(index + 1) else { print("Missing welcome preview path"); exit(1) }
            do { try FirstRunWelcome.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-data-states") {
            guard CommandLine.arguments.indices.contains(index + 1) else { print("Missing data-state preview directory"); exit(1) }
            do { try DataStatePreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print("Data-state preview failed: \(error)"); exit(1) }
            exit(0)
        }
        if CommandLine.arguments.contains("--verify-preview-lifecycle") {
            do { try PreviewModelScope.verify() }
            catch { print("Preview lifecycle failed: \(error)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-pages-preview") {
            guard CommandLine.arguments.indices.contains(index + 1) else { print("Missing page preview directory"); exit(1) }
            do { try CostPreview.run(destination: URL(fileURLWithPath: CommandLine.arguments[index + 1]), navigation: true) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-compact-preview") {
            guard CommandLine.arguments.indices.contains(index + 1) else { print("Missing compact preview output path"); exit(1) }
            do { try ProductPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), compact: true) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--preview-tools") {
            do { try ProductPreview.render(to: nil, compact: CommandLine.arguments.contains("--sample-compact")) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-history-preview") {
            guard CommandLine.arguments.indices.contains(index + 1), !CommandLine.arguments[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--render-history-preview requires an output path\n".utf8)); exit(2)
            }
            do { try HistoryPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--audit-coverage") {
            guard CommandLine.arguments.indices.contains(index + 1) else { print("Missing coverage output path"); exit(1) }
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            do { try CoverageAudit.run(home: home, destination: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--preview-cost-navigation") || CommandLine.arguments.contains("--preview-cost") || CommandLine.arguments.contains("--render-cost-preview") {
            let arguments = CommandLine.arguments
            let destination = arguments.firstIndex(of: "--render-cost-preview").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            if arguments.contains("--render-cost-preview") && destination == nil { print("Missing cost preview output path"); exit(1) }
            do { try CostPreview.run(destination: destination, navigation: arguments.contains("--preview-cost-navigation")) }
            catch { print("Cost preview failed: " + error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-motion-preview") {
            guard CommandLine.arguments.indices.contains(index + 1) else { print("Missing motion preview directory"); exit(1) }
            do { try ProductMotionPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print("Motion preview failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            guard CommandLine.arguments.indices.contains(index + 1), !CommandLine.arguments[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--render-preview requires an output path\n".utf8)); exit(2)
            }
            do { try ProductPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print("Preview failed: " + error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--claude-code") {
            // Headless twin of the Connect/Disconnect control: same code path, no dialog.
            let actions = ["status", "connect", "disconnect"]
            guard CommandLine.arguments.indices.contains(index + 1), actions.contains(CommandLine.arguments[index + 1]) else {
                FileHandle.standardError.write(Data("--claude-code requires status, connect or disconnect\n".utf8)); exit(2)
            }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let connection = ClaudeConnectionModel(settingsURL: ClaudeStatuslineConnection.settingsURL(),
                                                   relayURL: ClaudeStatuslineConnection.stableRelayURL(support: support),
                                                   bundleRelayURL: Bundle.main.url(forResource: "claude-statusline-relay", withExtension: "sh"),
                                                   defaults: .standard)
            let relayFile = support.appendingPathComponent("CodexTokenBar/claude-statusline.json")
            let observed = (try? JSONDecoder().decode(ClaudeStatuslineRelay.self, from: Data(contentsOf: relayFile)))?.statusline.rate_limits != nil
            let action = CommandLine.arguments[index + 1]
            var succeeded = true
            if action == "connect" { succeeded = connection.connect() }
            if action == "disconnect" { succeeded = connection.disconnect() }
            connection.refresh(relayObserved: observed)
            let report: [String: Any] = [
                "action": action, "status": connection.status.label, "settings": connection.settingsURL.path,
                "relay": connection.relayURL.path, "relayInstalled": FileManager.default.isExecutableFile(atPath: connection.relayURL.path),
                "relayObserved": observed, "caveat": connection.caveat ?? NSNull(), "error": connection.error ?? NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            exit(succeeded && connection.error == nil ? 0 : 1)
        }
        if CommandLine.arguments.contains("--diagnose-live") {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            var finished = false
            let feed = ActivityFeed(home: home, grokHome: HarnessDiscovery.grok(), claudeHome: HarnessDiscovery.claudeCode()) { snapshot in
                let now = Date()
                let reports: [[String: Any]] = LiveTool.allCases.map { tool in
                    let selected = snapshot.filtered(for: tool)
                    let samples = selected.freshMeasurements(at: now)
                    return ["tool": tool.rawValue, "active": selected.active(at: now).count,
                            "reporters": samples.count, "estimated_output_tps": samples.isEmpty ? NSNull() : samples.reduce(0.0) { $0 + $1.rate } as Any,
                            "read_error": selected.error != nil]
                }
                if let data = try? JSONSerialization.data(withJSONObject: ["tools": reports], options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
                finished = true
            }
            feed.refresh()
            let deadline = Date().addingTimeInterval(30)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if !finished { print("Live diagnostic timed out"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("token-bar-diagnose-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = UserDefaults(suiteName: "token-bar-diagnose-" + UUID().uuidString)!
            let model = UsageModel(previewRoot: root, defaults: defaults), snapshot = model.scanner.scan()
            let total = snapshot.entries.reduce(Tokens()) { $0 + $1.tokens }
            print("files=\(snapshot.files) events=\(snapshot.entries.reduce(0) { $0 + $1.eventCount }) input=\(total.input) cached=\(total.cached) output=\(total.output) total=\(total.total) quotas=\(snapshot.quotas.count) accountAvailable=\(snapshot.account != nil) error=\(snapshot.error ?? "none")")
            return
        }
        if CommandLine.arguments.contains("--find-duplicates") {
            print(DuplicateScan.report(DuplicateScan.find()))
            return
        }
        // Only the real run takes the lock. The diagnostic and preview modes
        // above use disposable profiles and never touch the installed ledger.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let ledger = support.appendingPathComponent("CodexTokenBar/ledger.json")
        let lock = LedgerLock()
        guard lock.acquire(besideLedger: ledger) else {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let holder = lock.holder()
            let text = DuplicateInstance.message(holder: holder)
            // Always report, so a copy launched from a terminal or by a script
            // explains itself instead of appearing to hang on an unseen dialog.
            FileHandle.standardError.write(Data(("Token Bar: " + text + "\n").utf8))
            // A session with no window server cannot show a dialog, and waiting
            // for a click that can never come is the worst of both outcomes.
            guard NSApp != nil, ProcessInfo.processInfo.environment["TOKENBAR_NO_UI"] == nil,
                  NSWorkspace.shared.frontmostApplication != nil else { exit(0) }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Token Bar is already running"
            alert.informativeText = text
            alert.addButton(withTitle: "Quit")
            if let holder, holder.bundlePath != Bundle.main.bundlePath, !holder.bundlePath.isEmpty {
                alert.addButton(withTitle: "Reveal the running copy")
            }
            if alert.runModal() == .alertSecondButtonReturn, let holder {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: holder.bundlePath)])
            }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { withExtendedLifetime(lock) { app.run() } }
    }
}
