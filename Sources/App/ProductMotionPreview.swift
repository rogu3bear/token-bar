import SwiftUI

/// Captures the real dashboard and menu presentation on an isolated synthetic
/// measurement stream. No production monitor, ledger, or preference is used.
enum ProductMotionPreview {
    @MainActor static func render(to directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        PreviewFixture.prepare()
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "local.codex-token-bar.motion-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try PreviewModelScope.run(root: root, defaults: defaults) { model in
            try render(model, to: directory)
        }
    }

    @MainActor private static func render(_ model: UsageModel, to directory: URL) throws {
        model.appearance.websitePreset()
        let now = PreviewFixture.date
        var quota = QuotaReading(accountID: "sample-account", bucket: "sample", name: "Account quota", window: "primary", minutes: 10080, used: 36, reset: now.addingTimeInterval(86400 * 4), date: now)
        var first = quota
        first.used = 34
        first.date = now.addingTimeInterval(-300)
        model.live.currentID = "sample-account"
        model.live.state.accounts["sample-account"] = LiveAccount(id: "sample-account", email: "developer@example.com", plan: "pro", observed: now, quotas: [quota])
        model.live.state.samples = [first, quota]
        var claudeQuota = quota
        claudeQuota.accountID = "claude:sample-account"
        claudeQuota.name = "Claude"
        claudeQuota.bucket = "claude"
        claudeQuota.minutes = 300
        claudeQuota.used = 58
        claudeQuota.reset = now.addingTimeInterval(14400)
        var claudeFirst = claudeQuota
        claudeFirst.used = 53
        claudeFirst.date = now.addingTimeInterval(-300)
        // This fixture introduces Claude's account and activity together. A
        // quota-only companion must not reserve Claude's panel before it joins.
        model.claudeMeter.unit = .minute

        let dashboard = NSHostingView(rootView: AppearanceHost(preferences: model.appearance) {
            DashboardRoot(model: model)
                .frame(width: 1064, height: 800, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        }.environment(\.colorScheme, .dark))
        dashboard.frame = NSRect(x: 0, y: 0, width: 1064, height: 800)
        let window = NSWindow(contentRect: dashboard.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = dashboard
        // An offscreen hosting window retains SwiftUI's own animation state.
        // It is never ordered on screen or installed as the user's app.
        let settings = MenuBarConfiguration()
        func menuView(now: Date) -> some View {
            AppearanceHost(preferences: model.appearance) {
                MenuBarPreview(value: MenuBarPresentation.combined(settings, codex: model.tachometer,
                    claude: model.claudeMeter, grok: model.grokMeter, monitor: model.live, now: now,
                    palette: model.appearance.toolPalette, claudeQuota: model.claudeQuota.quota,
                    grokQuota: model.grokQuota.quota))
                    .padding(.horizontal, 16).frame(width: 560, height: 40)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        let menuHost = NSHostingView(rootView: menuView(now: now))
        menuHost.frame = NSRect(x: 0, y: 0, width: 560, height: 40)
        let menuWindow = NSWindow(contentRect: menuHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        menuWindow.isReleasedWhenClosed = false
        menuWindow.appearance = NSAppearance(named: .darkAqua)
        menuWindow.contentView = menuHost
        defer { PreviewModelScope.close(window); PreviewModelScope.close(menuWindow) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        model.menuBarPreferences.configuration = settings
        if CommandLine.arguments.contains("--sample-idle") {
            for meter in [model.tachometer, model.claudeMeter, model.grokMeter] {
                meter.activity = ActivitySnapshot(readAt: now, referenceDate: now)
                meter.tick(now: now)
            }
            model.claudeQuota.quota.samples = [claudeFirst]
            model.claudeQuota.quota.readings = [claudeQuota]
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            menuHost.rootView = menuView(now: now)
            dashboard.layoutSubtreeIfNeeded()
            menuHost.layoutSubtreeIfNeeded()
            try capture(menuHost, to: directory.appendingPathComponent("menu-idle.png"))
            try capture(dashboard, to: directory.appendingPathComponent("now-idle.png"))
            let remaining = MenuBarPresentation.combined(settings, codex: model.tachometer, claude: model.claudeMeter,
                grok: model.grokMeter, monitor: model.live, now: now, palette: model.appearance.toolPalette,
                claudeQuota: model.claudeQuota.quota, grokQuota: model.grokQuota.quota)
            precondition(remaining.string.contains("Codex") && remaining.string.contains("remaining"), remaining.string)
            precondition(remaining.string.contains("Claude") && remaining.string.contains("remaining"), remaining.string)
            precondition(!remaining.string.contains("tok/"), remaining.string)
            let receipt: [String: Any] = ["synthetic": true, "idle": true, "fixtureDate": now.ISO8601Format(),
                "dashboard": "DashboardRoot / LiveToolPanels", "menu": "MenuBarPresentation.combined",
                "appearance": "Dark", "accent": AppearancePreferences.marketingAccent,
                "statusItem": remaining.string]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("capture.json"))
            print("Evaluated idle remaining on the status item; native raster capture: true; output: \(directory.path)")
            return
        }
        // Independent synthetic workloads and quota observations; never production conversion.
        // The website dissolves the settled sample replay while retaining both faces.
        let codexCycle = [128, 131, 127, 130, 125, 129, 132, 128, 126, 130]
        let claudeCycle = [78, 83, 80, 76, 82, 85, 79, 81]
        let codexWorking: [Int] = (0..<28).map { codexCycle[$0 % 10] }
        var claudeWorking: [Int] = (0..<28).map { claudeCycle[$0 % 8] }
        claudeWorking[0] = 40; claudeWorking[1] = 72
        let samples = [0, 48, 96, 128] + codexWorking
        let claudeSamples = [0, 0, 0, 0] + claudeWorking
        var rows: [[String: Any]] = []
        var previousSample = -1
        var previousClaude = -1
        let receiptsOnly = CommandLine.arguments.contains("--sample-receipts-only")
        let start = Date()
        let frames = samples.count * 60
        for frame in 0..<frames {
            let target = start.addingTimeInterval(Double(frame) / 30)
            if !receiptsOnly { RunLoop.main.run(until: max(target, Date().addingTimeInterval(0.001))) }
            let elapsed = Double(frame) / 30
            let tickDate = now.addingTimeInterval(elapsed)
            model.referenceDate = tickDate
            let sample = min(samples.count - 1, Int(elapsed / 2))
            if sample != previousSample {
                var activity = ActivitySnapshot(readAt: tickDate, referenceDate: tickDate)
                for index in 0..<(samples[sample] > 0 ? 6 : 0) {
                    let id = "sample-\(index)"
                    activity.turns[id] = TaskActivity(turn: id, started: now.addingTimeInterval(-120), observed: tickDate, running: true, kind: index < 4 ? .chat : .agent, session: id, name: "Sample task \(index + 1)")
                    activity.measurements[id] = RateMeasurement(turn: id, date: tickDate, duration: 6, output: samples[sample], model: "sample-model")
                }
                model.tachometer.activity = activity; model.tachometer.tick(now: tickDate)
                quota.used += Double(samples[sample]) * 0.0018
                quota.date = tickDate
                model.live.state.accounts["sample-account"]?.quotas = [quota]
                model.live.state.samples.append(quota)
                previousSample = sample
            }
            let claudeSample = min(claudeSamples.count - 1, max(0, Int((elapsed + 2) / 2.5)))
            if claudeSample != previousClaude {
                var claude = ActivitySnapshot(readAt: tickDate, referenceDate: tickDate)
                if claudeSamples[claudeSample] > 0 {
                    let id = "sample-claude"
                    claude.turns[id] = TaskActivity(turn: id, started: now, observed: tickDate, running: true, kind: .chat, session: id, name: "Sample Claude task", tool: .claude)
                    claude.measurements[id] = RateMeasurement(turn: id, date: tickDate, duration: 2, output: claudeSamples[claudeSample] * 2, model: "sample-claude")
                }
                model.claudeMeter.activity = claude; model.claudeMeter.tick(now: tickDate)
                claudeQuota.used += Double(claudeSamples[claudeSample]) * 0.0035
                claudeQuota.date = tickDate
                if claudeSamples[claudeSample] > 0 {
                    if model.claudeQuota.quota.samples.isEmpty {
                        model.claudeQuota.quota.samples = [claudeFirst]
                    }
                    model.claudeQuota.quota.readings = [claudeQuota]
                    model.claudeQuota.quota.samples.append(claudeQuota)
                }
                previousClaude = claudeSample
            }
            // The same formatter and attachment renderer update the real status item.
            if !receiptsOnly {
            menuHost.rootView = menuView(now: tickDate)
            dashboard.layoutSubtreeIfNeeded()
            menuHost.layoutSubtreeIfNeeded()
            try capture(dashboard, to: directory.appendingPathComponent(String(format: "dashboard-%04d.png", frame)))
            try capture(menuHost, to: directory.appendingPathComponent(String(format: "menu-%04d.png", frame)))
            }
            rows.append(["frame": frame, "seconds": elapsed, "codexQuotaRemaining": 100 - quota.used, "claudeQuotaRemaining": 100 - claudeQuota.used, "codexProjectedZero": Runway.estimate(quota, samples: model.live.state.samples, now: tickDate).exhaustion.map { $0.timeIntervalSince1970 as Any } ?? NSNull(), "claudeProjectedZero": Runway.estimate(claudeQuota, samples: model.claudeQuota.quota.samples, now: tickDate).exhaustion.map { $0.timeIntervalSince1970 as Any } ?? NSNull(), "codexOutputTokensPerSecond": model.tachometer.rawRate, "claudeOutputTokensPerSecond": model.claudeMeter.rawRate, "codexAvailable": model.tachometer.hasRate, "claudeAvailable": model.claudeMeter.hasRate, "menuTool": model.menuTool.rawValue, "visibleTools": LiveTool.visible(codex: model.tachometer, claude: model.claudeMeter).map(\.rawValue)])
        }
        let receipt: [String: Any] = ["synthetic": true, "fixtureDate": now.ISO8601Format(), "sampleClock": "frame / 30", "loopStartSeconds": 45.3, "loopEndSeconds": 63.8, "dashboard": "DashboardRoot / LiveToolPanels / ToolSpeedCard / RPMGauge", "menu": "MenuBarPresentation.combined", "appearance": "Dark", "accent": AppearancePreferences.marketingAccent, "frames": rows]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("capture.json"))
        print("Evaluated \(frames) synthetic motion samples; native raster capture: \(!receiptsOnly); output: \(directory.path)")
    }

    @MainActor private static func capture(_ view: NSView, to path: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        AppearanceRendering.capture(view, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: path)
    }
}
