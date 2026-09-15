import SwiftUI

/// Shipping surfaces with disposable preferences, files and a fixed synthetic clock.
/// Never starts AppDelegate's monitoring lifecycle or creates a notification adapter.
private final class QuotaGuardPreviewClose: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: true)
        }
    }
}
enum QuotaGuardPreview {
    @MainActor static func run(destination: URL?) throws {
        PreviewFixture.prepare()
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-quota-preview-" + UUID().uuidString)
        let suite = "local.token-bar.quota-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try PreviewModelScope.run(root: root, defaults: defaults) { model in
            try run(model, destination: destination)
        }
    }

    @MainActor private static func run(_ model: UsageModel, destination: URL?) throws {
        let now = PreviewFixture.date
        model.appearance.websitePreset()
        let arguments = CommandLine.arguments
        let light = arguments.contains("--sample-light")
        if light { model.appearance.mode = "Light" }
        if let index = arguments.firstIndex(of: "--sample-accent"), arguments.indices.contains(index + 1) {
            model.appearance.hex = arguments[index + 1].uppercased()
        }
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        var samples: [QuotaReading] = []
        for seconds in [-120.0, -60, 0] {
            samples.append(QuotaReading(accountID: "synthetic-codex", bucket: "general", name: "Primary account allowance", window: "primary", minutes: 300,
                used: 80 + (seconds + 120) / 12, reset: now.addingTimeInterval(7200), date: now.addingTimeInterval(seconds)))
        }
        let latest = samples.last!
        var weekly = latest; weekly.window = "weekly"; weekly.minutes = 10080; weekly.used = 96
        weekly.reset = now.addingTimeInterval(86400)
        if arguments.contains("--sample-long-label") { weekly.name = "A synthetic model-specific allowance with a deliberately long descriptive provider label" }
        model.live.currentID = latest.accountID
        model.live.state.accounts[latest.accountID] = LiveAccount(id: latest.accountID, email: "synthetic@example.invalid", plan: "sample", observed: now, quotas: [latest, weekly])
        model.live.state.samples = samples + [weekly]
        model.live.lastQuotaRefresh = now
        var claude = latest; claude.accountID = "synthetic-claude"; claude.bucket = "claude"; claude.name = "Model allowance"
        claude.date = now.addingTimeInterval(-180); claude.used = 95
        model.claudeQuota.quota = ToolQuotaState(readings: [claude], samples: [claude], horizon: 1800,
            guardAccountID: claude.accountID, guardAuthenticated: true)
        model.grokQuota.quota = ToolQuotaState(unavailable: "No supported account quota available")
        if arguments.contains("--sample-unavailable") {
            model.live.lastQuotaRefresh = nil
            model.live.state.accounts = [:]
        }
        if arguments.contains("--sample-stale") {
            model.live.lastQuotaRefresh = now.addingTimeInterval(-180)
            model.live.state.accounts[latest.accountID]?.quotas = [latest, weekly].map { value in
                var value = value; value.date = now.addingTimeInterval(-180); return value
            }
        }
        if arguments.contains("--sample-active") {
            let count = arguments.contains("--sample-single-tool") ? 1 : arguments.contains("--sample-two-tools") ? 2 : 3
            for tool in Array(LiveTool.allCases.prefix(count)) {
                let meter = model.meter(for: tool)
                let id = "synthetic-" + tool.rawValue
                var activity = ActivitySnapshot(readAt: now, referenceDate: now)
                activity.turns[id] = TaskActivity(turn: id, started: now.addingTimeInterval(-30), observed: now, running: true, kind: .chat, session: id, tool: tool)
                activity.measurements[id] = RateMeasurement(turn: id, date: now, duration: 2, output: 160, model: "synthetic-model")
                meter.activity = activity; meter.tick(now: now)
            }
        }
        model.quotaGuard.update(model.guardInputs())
        let delegate = AppDelegate(); delegate.model = model; delegate.configureNavigationActions()
        guard QuotaGuardNotifications.constructionCount == 0 else { throw CocoaError(.coderInvalidValue) }
        print("PASS: synthetic model and navigation construct zero system notification adapters")
        defer { PreviewModelScope.close(delegate.detailWindow); PreviewModelScope.close(delegate.settingsWindow) }
        if arguments.contains("--verify-quota-navigation") {
            guard let target = model.quotaGuard.decisions.first(where: { $0.risk != .none }) else { throw CocoaError(.coderInvalidValue) }
            model.quotaGuard.view(target)
            let window = delegate.detailWindow; let host = window?.contentViewController
            guard window != nil, delegate.dashboardSelection.destination == .now, model.quotaGuard.selected?.id == target.id else { throw CocoaError(.coderInvalidValue) }
            model.quotaGuard.selected = nil
            delegate.dashboardSelection.destination = .accounts
            window?.orderOut(nil)
            model.quotaGuard.view(target)
            guard delegate.detailWindow === window, delegate.detailWindow?.contentViewController === host,
                  delegate.dashboardSelection.destination == .now else { throw CocoaError(.coderInvalidValue) }
            model.quotaGuard.selected = nil
            window?.orderOut(nil)
            print("PASS: View quota opens Now with exact allowance and reuses the dashboard window/controller")
        }
        let compact = arguments.contains("--sample-compact")
        let width: CGFloat = arguments.contains("--sample-default-size") ? 1120 : 900
        let height: CGFloat = arguments.contains("--sample-default-size") ? 800 : 700
        let settings = arguments.contains("--sample-settings")
        let view = AppearanceHost(preferences: model.appearance, clock: model.clock) {
            Group {
                if compact { QuickLiveView(model: model, monitor: model.live, meter: model.tachometer) }
                else { DetailRoot(model: model, initialDestination: settings ? .menuBar : .now) }
            }.frame(width: compact ? 440 : width, height: compact ? nil : height)
                .background(Color(nsColor: .windowBackgroundColor))
        }.previewStill()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: compact ? 440 : width, height: compact ? host.fittingSize.height : height)
        let window = NSWindow(contentRect: host.frame, styleMask: destination == nil ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
        let closer = QuotaGuardPreviewClose()
        if destination == nil { window.delegate = closer }
        window.isReleasedWhenClosed = false; window.title = "Token Bar · Synthetic Quota Guard"
        window.appearance = NSApp.appearance; window.contentView = host
        defer { PreviewModelScope.close(window) }
        if let destination {
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            AppearanceRendering.capture(host, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination)
            print("Rendered Quota Guard synthetic surface \(host.frame.size): " + destination.path)
        } else {
            NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            withExtendedLifetime(delegate) { NSApp.run() }
        }
    }
}
