import SwiftUI

/// Generates the website product image from the shipping view and synthetic data.
/// It never launches monitoring, reads real usage data, or touches normal preferences.
private final class ProductPreviewClose: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
    }
}
enum ProductPreview {
    @MainActor static func render(to destination: URL?, compact: Bool = false) throws {
        PreviewFixture.prepare()
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "local.codex-token-bar.preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try PreviewModelScope.run(root: root, defaults: defaults) { model in
            try render(model, to: destination, compact: compact)
        }
    }

    @MainActor private static func render(_ model: UsageModel, to destination: URL?, compact: Bool) throws {
        model.appearance.websitePreset()
        let light = CommandLine.arguments.contains("--sample-light")
        if light { model.appearance.mode = "Light"; NSApp.appearance = NSAppearance(named: .aqua) }
        if let index = CommandLine.arguments.firstIndex(of: "--sample-accent") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  AppearancePreferences.valid(CommandLine.arguments[index + 1]) else { throw CocoaError(.validationMissingMandatoryProperty) }
            model.appearance.hex = CommandLine.arguments[index + 1].uppercased()
        }
        let now = PreviewFixture.date
        var activity = ActivitySnapshot(readAt: now, referenceDate: now)
        for index in 0..<6 {
            let id = "sample-\(index)"
            activity.turns[id] = TaskActivity(turn: id, started: now.addingTimeInterval(-120), observed: now, running: true, kind: index < 4 ? .chat : .agent, session: id, name: "Sample task \(index + 1)")
        }
        model.tachometer.activity = activity
        model.tachometer.rate = 128; model.tachometer.rawRate = 128
        model.tachometer.minimum = 80; model.tachometer.scale = 180
        model.tachometer.hasRate = true; model.tachometer.lastReport = now
        model.tachometer.reportingCount = 6; model.tachometer.models = ["sample-model"]
        var claude = ActivitySnapshot(readAt: now, referenceDate: now)
        claude.turns["claude-sample"] = TaskActivity(turn: "claude-sample", started: now.addingTimeInterval(-30), observed: now, running: true, kind: .chat, session: "claude-sample", tool: .claude)
        claude.measurements["claude-sample"] = RateMeasurement(turn: "claude-sample", date: now, duration: 2, output: 164, model: "sample-claude")
        model.claudeMeter.activity = claude; model.claudeMeter.tick(now: now)
        let quota = QuotaReading(accountID: "sample-account", bucket: "sample", name: "Account quota", window: "primary", minutes: 10080, used: 36, reset: now.addingTimeInterval(86400 * 4), date: now)
        var first = quota; first.used = 34; first.date = now.addingTimeInterval(-300)
        model.live.currentID = "sample-account"
        model.live.state.accounts["sample-account"] = LiveAccount(id: "sample-account", email: "developer@example.com", plan: "pro", observed: now, quotas: [quota])
        model.live.state.samples = [first, quota]
        var claudeQuota = quota
        claudeQuota.accountID = "claude:sample-account"
        claudeQuota.name = ClaudeQuotaSource.name
        claudeQuota.bucket = ClaudeQuotaSource.bucket
        claudeQuota.minutes = 300
        claudeQuota.used = 58
        claudeQuota.reset = now.addingTimeInterval(14400)
        var claudeFirst = claudeQuota
        claudeFirst.used = 53
        claudeFirst.date = now.addingTimeInterval(-300)
        model.claudeQuota.quota = ToolQuotaState(readings: [claudeQuota], samples: [claudeFirst, claudeQuota], horizon: ClaudeQuotaSource.horizon)
        var grokActivity = ActivitySnapshot(readAt: now, referenceDate: now)
        grokActivity.turns["grok-sample"] = TaskActivity(turn: "grok-sample", started: now.addingTimeInterval(-45), observed: now, running: true, kind: .chat, session: "grok-sample", tool: .grok)
        grokActivity.measurements["grok-sample"] = RateMeasurement(turn: "grok-sample", date: now, duration: 2, output: 96, model: "sample-grok")
        model.grokMeter.activity = grokActivity; model.grokMeter.tick(now: now)
        var grokQuota = quota
        grokQuota.accountID = "grok:sample"
        grokQuota.name = "X Premium+"
        grokQuota.bucket = "grok"
        grokQuota.window = "weekly"
        grokQuota.used = 49
        grokQuota.reset = now.addingTimeInterval(86400 * 5)
        var grokFirst = grokQuota; grokFirst.used = 47; grokFirst.date = now.addingTimeInterval(-300)
        model.grokQuota.quota = ToolQuotaState(readings: [grokQuota], samples: [grokFirst, grokQuota], accountLabel: "X Premium+")
        precondition(LiveTool.allCases.allSatisfy { model.meter(for: $0).hasRate }, "Hero requires healthy synthetic rates")
        precondition(LiveTool.allCases.allSatisfy { tool in
            let state = model.quota(for: tool)
            return Runway.priority(state.readings, samples: state.samples, now: now, horizon: state.horizon).flatMap {
                Runway.estimate($0, samples: state.samples, now: now, horizon: state.horizon).exhaustion
            } != nil
        }, "Hero requires supported synthetic quota projections")
        var snap = model.snapshot
        for hour in 0..<8 {
            let stamp = now.addingTimeInterval(TimeInterval(-1800 * (7 - hour)))
            var row = Entry(date: stamp, session: "sample-\(hour)", model: "sample-model", tokens: Tokens(["output_tokens": 400 + hour * 120, "input_tokens": 200]))
            row.harness = hour % 2 == 0 ? Harness.grok : "codex-desktop"
            snap.entries.append(row)
        }
        // Synthetic additions are a new snapshot, not the scanner's old content identity.
        snap.contentID = nil
        model.snapshot = snap
        precondition(model.usageStore.compactUsage.timeline.points.contains { $0.tokens.total > 0 },
                     "Recorded synthetic Today history must survive activity changes")
        if destination == nil || compact {
            model.tachometer.unit = .minute
            model.claudeMeter.unit = .hour
        }
        if CommandLine.arguments.contains("--sample-two-tools") {
            model.grokMeter.activity = ActivitySnapshot(readAt: now, referenceDate: now); model.grokMeter.tick(now: now)
        }
        if CommandLine.arguments.contains("--sample-single-tool") {
            model.claudeMeter.activity = ActivitySnapshot(readAt: now, referenceDate: now); model.claudeMeter.tick(now: now)
            model.grokMeter.activity = ActivitySnapshot(readAt: now, referenceDate: now); model.grokMeter.tick(now: now)
        }
        precondition(model.tachometer.runningCount == 6 && model.tachometer.activity.uncertain == 0, "Hero activity must be fresh at the fixture clock")
        if CommandLine.arguments.contains("--sample-idle") {
            for tool in LiveTool.allCases {
                model.meter(for: tool).activity = ActivitySnapshot(readAt: now, referenceDate: now)
                model.meter(for: tool).tick(now: now)
            }
        }
        if CommandLine.arguments.contains("--sample-claude-error") {
            model.claudeMeter.activity = ActivitySnapshot(readAt: now,
                error: "Synthetic transcript read failed", referenceDate: now)
            model.claudeMeter.tick(now: now)
        }
        if CommandLine.arguments.contains("--sample-zero") {
            model.live.state.accounts["sample-account"]?.quotas[0].used = 100
            model.claudeQuota.quota.readings[0].used = 100; model.grokQuota.quota.readings[0].used = 100
        }
        if CommandLine.arguments.contains("--sample-expired") {
            model.live.state.accounts["sample-account"]?.quotas[0].reset = now
            model.claudeQuota.quota.readings[0].reset = now; model.grokQuota.quota.readings[0].reset = now
        }
        var fixtureActivities = LiveTool.allCases.map { model.meter(for: $0).activity }
        for (id, task) in fixtureActivities[0].turns {
            fixtureActivities[0].measurements[id] = RateMeasurement(turn: task.turn, date: now, duration: 6, output: 128, model: "sample-model")
        }
        if CommandLine.arguments.contains("--sample-stale") {
            for id in model.live.state.accounts.keys { model.live.state.accounts[id]?.quotas[0].date = now.addingTimeInterval(-7200) }
            model.claudeQuota.quota.readings[0].date = now.addingTimeInterval(-7200)
            model.grokQuota.quota.readings[0].date = now.addingTimeInterval(-7200)
        }
        if CommandLine.arguments.contains("--sample-no-accounts") {
            model.live.currentID = nil; model.live.state.accounts = [:]; model.live.state.samples = []
            model.claudeQuota.quota = ToolQuotaState(); model.grokQuota.quota = ToolQuotaState()
            model.snapshot.entries = []
            for tool in LiveTool.allCases {
                model.meter(for: tool).activity = ActivitySnapshot(readAt: now, referenceDate: now)
                model.meter(for: tool).tick(now: now)
            }
        }
        if CommandLine.arguments.contains("--sample-failed") {
            model.claudeQuota.quota = ToolQuotaState(unavailable: "Synthetic quota read failed", guardFailed: true)
        }
        if CommandLine.arguments.contains("--sample-codex-failed") {
            model.live.error = "Synthetic Codex quota read failed"
            precondition(model.quota(for: .codex).guardFailed)
            precondition(AccountAllowancePresentation(quota: model.quota(for: .codex), now: now).reading == nil)
            print("PASS: shipping Codex model failure invalidates allowance presentation")
        }
        if CommandLine.arguments.contains("--sample-switched-account") {
            model.live.currentID = "sample-second"
            model.live.state.accounts["sample-second"] = LiveAccount(id: "sample-second", email: "second@example.com", plan: "pro", observed: now, quotas: [quota])
            precondition(model.quota(for: .codex).guardAccountID == "sample-second")
            precondition(AccountAllowancePresentation(quota: model.quota(for: .codex), now: now).reading == nil)
            print("PASS: shipping Codex model rejects old allowance under a switched account")
        }
        if CommandLine.arguments.contains("--sample-working-no-rate") {
            model.tachometer.tick(now: now)
            precondition(model.tachometer.runningCount > 0 && !model.tachometer.hasRate)
            precondition(model.tachometer.rate == 0 && model.tachometer.rawRate == 0)
        }
        if CommandLine.arguments.contains("--sample-asymmetric-headers") {
            model.tachometer.activity.error = "Synthetic activity catalog temporarily unavailable; previously observed work remains visible."
            model.tachometer.models = ["synthetic-model-with-a-long-context-and-reasoning-variant"]
            model.claudeMeter.activity.measurements = [:]
            model.claudeMeter.tick(now: now)
        }
        if CommandLine.arguments.contains("--sample-update") {
            let successor = ReleaseManifest(version: "9.9.9", available: true,
                url: UpdateCheck.downloadPrefix + "v9.9.9/TokenBar-9.9.9-arm64.pkg", sha256: nil, notarized: true)
            model.updateCheck.adopt(.available(successor), at: now)
            precondition(model.updateCheck.availableRelease?.version == "9.9.9")
        }
        // Flush the model's observation callbacks before constructing shipping consumers.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if !CommandLine.arguments.contains("--sample-no-accounts") {
            precondition(model.accountTools == LiveTool.allCases, "Account allowances must outlive fixture activity")
        } else { precondition(model.accountTools.isEmpty, "Empty fixture must not invent detected tools") }
        let previewWidth: CGFloat = CommandLine.arguments.firstIndex(of: "--sample-width").flatMap {
            CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil
        }.map { CGFloat(min(1800, max(900, $0))) } ?? 1064
        let previewHeight: CGFloat = CommandLine.arguments.firstIndex(of: "--sample-height").flatMap {
            CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil
        }.map { CGFloat(min(1200, max(700, $0))) } ?? 900
        let view = AppearanceHost(preferences: model.appearance) {
            VStack(spacing: 0) {
                if destination == nil {
                    HStack {
                        Text("Synthetic allowance fixture").font(.caption)
                        Button("Stop all tools") {
                            let before = model.accountTools.map { AccountAllowancePresentation(quota: model.quota(for: $0), now: now).detail }
                            for tool in LiveTool.allCases {
                                model.meter(for: tool).activity = ActivitySnapshot(readAt: now, referenceDate: now)
                                model.meter(for: tool).tick(now: now)
                            }
                            precondition(before == model.accountTools.map { AccountAllowancePresentation(quota: model.quota(for: $0), now: now).detail })
                            print("PASS: active-to-idle preserves account allowance content at unchanged account and clock")
                        }
                        ForEach(LiveTool.allCases) { tool in
                            Button("Toggle " + tool.label) {
                                let meter = model.meter(for: tool)
                                meter.activity = meter.runningCount > 0
                                    ? ActivitySnapshot(readAt: now, referenceDate: now)
                                    : fixtureActivities[LiveTool.allCases.firstIndex(of: tool)!]
                                meter.tick(now: now)
                            }
                        }
                        Button("Start tools") {
                            for (tool, activity) in zip(LiveTool.allCases, fixtureActivities) {
                                model.meter(for: tool).activity = activity
                                model.meter(for: tool).tick(now: now)
                            }
                        }
                    }.padding(8)
                }
                Group {
                    if compact { QuickLiveView(model: model, monitor: model.live, meter: model.tachometer) }
                    else { DashboardRoot(model: model) }
                }.frame(width: compact ? 440 : previewWidth, height: compact ? nil : previewHeight)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }.transaction { if destination != nil { $0.animation = nil; $0.disablesAnimations = true } }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: compact ? 440 : previewWidth, height: compact ? host.fittingSize.height : previewHeight + (destination == nil ? 44 : 0))
        if compact { print("Compact native fitting size: \(host.frame.size)") }
        let window = NSWindow(contentRect: host.frame, styleMask: destination == nil ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let closer = ProductPreviewClose()
        if destination == nil { window.delegate = closer }
        window.title = "Token Bar · Synthetic allowance preview"
        defer { PreviewModelScope.close(window) }
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        if destination == nil {
            // Reuse shipping navigation with only the disposable model; never install
            // AppDelegate as NSApp.delegate or start its monitoring lifecycle.
            let delegate = AppDelegate()
            delegate.model = model; delegate.configureNavigationActions()
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.preferredContentSize]
            window.contentViewController = controller
            defer { PreviewModelScope.close(delegate.detailWindow); PreviewModelScope.close(delegate.settingsWindow) }
            NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            withExtendedLifetime(delegate) { NSApp.run() }; return
        }
        guard let destination else { return }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        AppearanceRendering.capture(host, to: bitmap)
        guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
        print("Rendered native dashboard with synthetic data: " + destination.path)
    }
}
