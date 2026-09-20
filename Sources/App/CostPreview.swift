import SwiftUI
import SQLite3

/// Native verification uses synthetic usage in an isolated temporary profile only.
private final class CostPreviewClose: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: true)
        }
    }
}
enum CostPreview {
    @MainActor static func run(destination: URL?, navigation: Bool = false) throws {
        PreviewFixture.prepare()
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-cost-preview-" + UUID().uuidString)
        let suite = "local.token-bar.cost-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try PreviewModelScope.run(root: root, defaults: defaults) { model in
            try run(model, root: root, destination: destination, navigation: navigation)
        }
    }

    @MainActor private static func run(_ model: UsageModel, root: URL, destination: URL?, navigation: Bool) throws {
        model.appearance.websitePreset()
        model.period = 2
        model.costBasis = .reference
        let interactive = navigation && CommandLine.arguments.contains("--preview-native-interaction")
        let sampleAccount = Account(id: "synthetic-account", label: "Sample account", plan: "pro")
        model.signIns.observations = [SignInObservation(date: PreviewFixture.date.addingTimeInterval(-2 * 86400), account: nil, reason: "Synthetic sign-in", status: "Login complete")]
        let now = PreviewFixture.date
        let names = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna"]
        var entries: [Entry] = []
        for day in 0..<6 {
            for (index, name) in names.enumerated() {
                var e = Entry(date: Calendar.current.date(byAdding: .day, value: -day, to: now)!, session: "sample-task-\(index)", model: name,
                    tokens: Tokens(["input_tokens": 100_000 + day * 5_000, "cached_input_tokens": 50_000, "cache_write_input_tokens": 10_000,
                                    "output_tokens": 15_000 + index * 2_000, "reasoning_output_tokens": 10_000]), account: nil)
                e.tokenFields = UsageMetadata.fields; e.pricingDay = UsageMetadata.day(e.date); e.firstObserved = e.date
                e.provider = "openai"; e.effort = ["high", "medium", "low"][index]; e.contextBand = "short"; e.costMetadataVersion = 1
                e.harness = index == 0 ? "Codex CLI" : "Codex Desktop"
                if interactive && index == 0 { e.account = sampleAccount }
                entries.append(e)
            }
        }
        var missing = entries[0]; missing.model = "sample-unpriced-model"; missing.effort = nil
        if CommandLine.arguments.contains("partial") { entries.append(missing) }
        for index in entries.indices {
            entries[index].recordID = "preview-\(index)"
            entries[index].requestInputTokens = entries[index].tokens.input
            try model.scanner.requestArchive?.record(entries[index], admitted: true)
        }
        model.retainedRequests = try model.scanner.requestArchive?.count
        model.live.currentID = "synthetic-account"
        model.live.state.usage = ["synthetic-account": ProviderUsage(accountID: "synthetic-account", observed: now, lifetimeTokens: 9_000_000,
            days: Dictionary(uniqueKeysWithValues: (0..<6).map { day in (UsageMetadata.day(now.addingTimeInterval(Double(-day) * 86400)), 400_000) }))]
        if CommandLine.arguments.contains("--sample-metering") {
            var samples: [QuotaReading] = []
            for index in 0..<7 {
                let date = now.addingTimeInterval(Double(index - 6) * 300)
                samples.append(QuotaReading(accountID: sampleAccount.id, bucket: "codex", name: "Codex", window: "primary", minutes: 300,
                    used: Double(20 + index * (index + 1) / 2), reset: now.addingTimeInterval(3600), date: date))
                if index > 0 {
                    var entry = entries[index % 3]
                    entry.date = date.addingTimeInterval(-150); entry.firstObserved = entry.date
                    entry.pricingDay = UsageMetadata.day(entry.date); entry.account = sampleAccount
                    entry.session = "sample-metering-\(index)"; entry.recordID = entry.session
                    entries.append(entry)
                }
            }
            model.live.state.accounts[sampleAccount.id] = LiveAccount(id: sampleAccount.id, email: "sample@example.com", plan: "pro", observed: now, quotas: [samples.last!])
            model.live.state.quotaHistory = samples
        }
        model.snapshot = Snapshot(entries: entries, updated: now)
        model.snapshot.historyImportedAt = now
        model.availableModels = Array(Set(entries.map(\.model))).sorted()
        model.availableTools = Array(Set(entries.compactMap(\.harness))).sorted()
        model.availableEfforts = ["high", "medium", "low", "Unknown"]
        if interactive { model.availableAccounts = [sampleAccount] }
        model.costReport = CostReport.build(source: entries, query: UsageQuery(period: 2), catalog: [:], now: now)
        model.costRecoveryMessage = "Sample data only. No real account or usage records were read."
        model.detailedReporting = true
        model.rebuild()
        if navigation { try verifyScope(model, root: root) }
        if navigation { try configurePageState(model, root: root, entries: entries) }
        if interactive && destination == nil {
            var integrity = IntegrityReport()
            integrity.record([.negativeCounter])
            model.snapshot.integrity = integrity
            runInteractive(model)
            return
        }
        if navigation, let destination {
            try renderPages(model, directory: destination)
            return
        }
        let deadline = Date().addingTimeInterval(15)
        while model.filtering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !model.filtering else { throw CocoaError(.coderInvalidValue) }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-history-navigation") {
            guard CommandLine.arguments.indices.contains(index + 1) else { throw CocoaError(.fileWriteInvalidFileName) }
            try HistoryNavigationPreview.verify(model, directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        let page: Destination = CommandLine.arguments.contains("--sample-history") ? .history : navigation ? .now : .cost
        let view = AppearanceHost(preferences: model.appearance) {
            DashboardRoot(model: model, initialDestination: page).frame(minWidth: 900, minHeight: 700)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        let host = NSHostingView(rootView: view.transaction { if destination != nil { $0.animation = nil; $0.disablesAnimations = true } })
        host.frame = NSRect(x: 0, y: 0, width: 1064, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: destination == nil ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless], backing: .buffered, defer: false)
        let closer = CostPreviewClose()
        if destination == nil { window.delegate = closer }
        window.title = "Token Bar · Synthetic page preview"
        window.minSize = NSSize(width: 900, height: 728)
        window.isReleasedWhenClosed = false
        defer { PreviewModelScope.close(window) }
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
        if let destination {
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            AppearanceRendering.capture(host, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: destination)
        } else {
            NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
        }
    }

    /// Use shipping callbacks with a disposable model, never the monitoring lifecycle.
    @MainActor private static func runInteractive(_ model: UsageModel) {
        let delegate = AppDelegate()
        delegate.model = model
        delegate.configureNavigationActions()
        let quick = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let closer = CostPreviewClose()
        quick.delegate = closer
        quick.isReleasedWhenClosed = false
        quick.title = "Token Bar · Synthetic controls"
        let host = NSHostingController(rootView: AppearanceHost(preferences: model.appearance, clock: model.clock) {
            QuickLiveView(model: model, monitor: model.live, meter: model.tachometer)
        })
        host.sizingOptions = [.preferredContentSize]
        quick.contentViewController = host
        defer {
            PreviewModelScope.close(delegate.detailWindow)
            PreviewModelScope.close(delegate.settingsWindow)
            PreviewModelScope.close(quick)
        }
        NSApp.setActivationPolicy(.regular)
        model.showHistory?()
        quick.center()
        quick.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Deliberately do not install AppDelegate as NSApp.delegate: that starts real monitoring.
        withExtendedLifetime(delegate) { NSApp.run() }
    }

    @MainActor private static func renderPages(_ model: UsageModel, directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let matrix = CommandLine.arguments.contains("--layout-matrix")
        let sizes = matrix ? [CGSize(width: 900, height: 700), CGSize(width: 1200, height: 900)] : [CGSize(width: 1064, height: 900)]
        for mode in matrix ? ["Light", "Dark"] : ["Dark"] {
            model.appearance.mode = mode
            NSApp.appearance = NSAppearance(named: mode == "Light" ? .aqua : .darkAqua)
            for size in sizes {
                for reduced in [NSWorkspace.shared.accessibilityDisplayShouldReduceMotion] {
                    for page in Destination.allCases {
                        let host = NSHostingView(rootView: AppearanceHost(preferences: model.appearance) {
                            DashboardRoot(model: model, initialDestination: page).frame(width: size.width, height: size.height)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }.previewStill())
                        host.frame = NSRect(origin: .zero, size: size)
                        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.contentView = host
                        defer { PreviewModelScope.close(window) }
                        window.appearance = NSApp.appearance
                        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded()
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                        AppearanceRendering.capture(host, to: bitmap)
                        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                        let name = matrix ? "\(page)-\(mode)-\(Int(size.width))-\(reduced ? "reduced" : "motion").png" : "\(page).png"
                        try data.write(to: directory.appendingPathComponent(name))
                    }
                }
            }
        }
        print("Rendered native pages: " + directory.path)
    }

    /// Page-state fixtures use real readers and only this preview's disposable paths.
    @MainActor private static func configurePageState(_ model: UsageModel, root: URL, entries: [Entry]) throws {
        let arguments = CommandLine.arguments
        let state: String
        if let index = arguments.firstIndex(of: "--sample-state") {
            guard arguments.indices.contains(index + 1), ["populated", "empty", "partial", "failed"].contains(arguments[index + 1]) else {
                throw NSError(domain: "PagePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose populated, empty, partial, or failed"])
            }
            state = arguments[index + 1]
        } else { state = "populated" }
        let source = state == "empty" ? [] : state == "partial" ? entries : entries.filter { $0.model != "sample-unpriced-model" }
        model.snapshot.entries = source
        if arguments.contains("--sample-tool-filter") { model.toolFilter = "Codex CLI" }
        model.rebuild()
        model.usageInsights.refresh(entries: source, catalog: [:])
        let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        func sql(_ statement: String) throws {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
        try sql("CREATE TABLE threads(id TEXT, rollout_path TEXT, thread_source TEXT, updated_at INTEGER)")
        if state != "empty" {
            let path = root.appendingPathComponent("sample-prompt.jsonl")
            let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": PreviewFixture.date.ISO8601Format(), "payload": ["type": "user_message", "message": "Please review the Swift build"]])
            try data.write(to: path)
            try sql("INSERT INTO threads VALUES('sample', '\(path.path)', 'user', \(Int(PreviewFixture.date.timeIntervalSince1970)))")
            if state == "partial" { try sql("INSERT INTO threads VALUES('missing', '\(root.path)/missing.jsonl', 'user', \(Int(PreviewFixture.date.timeIntervalSince1970)))") }
        }
        model.insights.refresh(home: root, force: true)
        try PreviewFixture.settle("page reports and insights") {
            !model.insights.busy && !model.filtering && !model.usageInsights.busy && model.usageInsights.hasResult
        }
        if state == "failed" {
            try sql("DROP TABLE threads")
            model.snapshot.error = "Synthetic usage refresh failed."
            model.live.error = "Synthetic Codex account read failed."
            model.tachometer.activity.error = "Synthetic activity read failed."
            model.usageInsights.refresh(entries: [], catalog: [:], sourceAvailable: false)
            model.insights.refresh(home: root, force: true)
            try PreviewFixture.settle("failed prompt read") { !model.insights.busy }
        }
        if arguments.contains("--sample-many-diagnostics") {
            model.snapshot.error = PreviewFixture.sourceDiagnostics
            // Exercise other consumers of the same shared notice without a live provider.
            model.live.error = "Synthetic account service unavailable."
        }
        if state != "empty" {
            let observed = PreviewFixture.date.addingTimeInterval(state == "failed" ? -600 : 0)
            let quota = QuotaReading(accountID: "synthetic-account", bucket: "sample", name: "Codex", window: "primary", minutes: 300, used: 36, reset: PreviewFixture.date.addingTimeInterval(3600), date: observed)
            model.live.state.accounts["synthetic-account"] = LiveAccount(id: "synthetic-account", email: "sample@example.com", plan: "pro", observed: observed, quotas: [quota])
            if arguments.contains("--sample-spark-accounts") {
                var spark = quota; spark.bucket = "codex_bengalfox"; spark.name = "GPT-5.3-Codex-Spark"
                var weekly = spark; weekly.window = "secondary"; weekly.minutes = 10080
                model.live.state.accounts["synthetic-account"]?.quotas += [spark, weekly]
                spark.accountID = "synthetic-previous"; weekly.accountID = spark.accountID
                model.live.state.accounts[spark.accountID] = LiveAccount(id: spark.accountID, email: "previous@example.com",
                    plan: "plus", observed: observed.addingTimeInterval(-86400), quotas: [spark, weekly])
            }
            if arguments.contains("--sample-account-history") {
                model.live.state.plans = (0..<8).map { index in
                    let date = observed.addingTimeInterval(Double(index - 8) * 86400)
                    return LivePlan(id: "synthetic-plan-\(index)", accountID: quota.accountID, email: "sample@example.com",
                        plan: index.isMultiple(of: 2) ? "plus" : "pro", firstSeen: date, lastSeen: date.addingTimeInterval(3600))
                }
            }
            if state != "failed" {
                model.tachometer.activity.turns["sample"] = TaskActivity(turn: "sample", started: observed, observed: observed, running: true, kind: .chat, session: "sample")
                model.tachometer.rawRate = 72; model.tachometer.rate = 72; model.tachometer.hasRate = true; model.tachometer.reportingCount = 1
                model.tachometer.models = ["sample-model"]
            }
        }
        if state == "partial" {
            var integrity = IntegrityReport()
            integrity.record([.negativeCounter])
            model.snapshot.integrity = integrity
        }
        model.busy = false; model.progress = nil
        model.tachometer.activity.readAt = PreviewFixture.date
        model.tachometer.activity.referenceDate = PreviewFixture.date
        model.costRecoveryMessage = "Synthetic page state: " + state + ". No real account or usage records were read."
        print("Native page state: " + state)
    }

    /// Exercise the actual asynchronous model and exports using this preview's disposable records.
    @MainActor private static func verifyScope(_ model: UsageModel, root: URL) throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "ReportScopePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle() throws {
            let deadline = Date().addingTimeInterval(15)
            while model.filtering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try require(!model.filtering, "Report rebuild timed out")
        }
        try settle()
        let original = model.snapshot
        model.toolFilter = "Codex CLI"
        try settle()
        let selected = original.entries.filter { $0.harness == "Codex CLI" }
        let total = selected.reduce(0) { $0 + $1.tokens.total }
        try require(model.report.entries.count == selected.count && model.report.totals.total == total,
                    "History must use selected Tool")
        try require(model.costReport.lines.count == selected.count && model.costReport.totalTokens == total,
                    "Cost must share History's selected Tool")
        try require(model.report.days.reduce(0) { $0 + $1.tokens.total } == total
                    && model.report.models.reduce(0) { $0 + $1.total } == total
                    && model.report.harnesses.reduce(0) { $0 + $1.total } == total,
                    "History charts and breakdowns must reconcile")
        try require(model.costReport.models.reduce(Decimal.zero) { $0 + $1.amounts.total } == model.costReport.amounts.total
                    && model.costReport.timeline.reduce(Decimal.zero) { $0 + $1.amounts.total } == model.costReport.amounts.total,
                    "Cost charts and breakdowns must reconcile")
        try require(model.report.csv().split(separator: "\n").count == selected.count + 1
                    && model.costReport.csv().split(separator: "\n").count == selected.count + 1,
                    "Published-report exports must share selected records")
        let archive = try RequestArchive(url: model.scanner.requestArchiveURL, readOnly: true)
        let exportURL = root.appendingPathComponent("scope.csv")
        let count = try RequestExport.write(archive: archive, destination: exportURL, query: model.costQuery, catalog: [:], effort: model.costEffort, now: PreviewFixture.date)
        try require(count == selected.count, "Request export must share Tool selection")
        model.costEffort = "high"
        model.modelFilter = "gpt-6-astra"
        model.accountFilter = DimensionReport.unattributed
        model.search = "sample-task-0"
        model.costService = .fast
        try settle()
        model.clearReportFilters(includesCost: true)
        try settle()
        try require(model.toolFilter == "All tools" && model.modelFilter == "All models"
                    && model.accountFilter == "All accounts" && model.search.isEmpty && model.costEffort == "All levels",
                    "Cost clear must remove all applicable record restrictions")
        try require(model.period == 2 && model.costService == .fast && model.costBasis == .reference,
                    "Clear must preserve period and pricing assumptions")
        try require(model.report.entries.count == original.entries.count && model.costReport.lines.count == original.entries.count,
                    "Returning to History must share the cleared scope")
        let allCount = try RequestExport.write(archive: archive, destination: root.appendingPathComponent("all.csv"), query: model.costQuery, catalog: [:], effort: model.costEffort, now: PreviewFixture.date)
        try require(allCount == original.entries.count && model.report.csv().split(separator: "\n").count == allCount + 1,
                    "Cleared export must match cleared report")

        // Change away and back before the main queue can publish; also replace the source.
        var publishedTotals: [Int] = []
        model.reportPublished = { publishedTotals.append($0.totals.total) }
        defer { model.reportPublished = nil }
        model.toolFilter = "Codex CLI"
        var additional = selected[0]; additional.session = "new-synthetic-task"
        model.snapshot.entries.append(additional)
        model.rebuild()
        model.toolFilter = "Codex Desktop"
        model.toolFilter = "Codex CLI"
        try settle()
        model.reportPublished = nil
        try require(publishedTotals == [total + additional.tokens.total],
                    "Obsolete generations must never publish, even when selection returns to the same value")
        // Source-only updates must not starve visible reports while work continues.
        publishedTotals = []
        model.reportPublished = { publishedTotals.append($0.totals.total) }
        model.snapshot.entries.append(additional); model.rebuild()
        model.snapshot.entries.append(additional); model.rebuild()
        try settle()
        try require(publishedTotals.count >= 2 && publishedTotals.last == total + additional.tokens.total * 3,
                    "Completed reports remain visible while newer usage is coalesced")
        model.reportPublished = nil
        model.snapshot = original
        model.clearReportFilters(includesCost: false)
        model.costService = .standard
        try settle()
        print("PASS: native shared Tool scope, charts, breakdowns, CSV and request exports; clear preserves period/pricing; obsolete generations rejected")
    }
}
