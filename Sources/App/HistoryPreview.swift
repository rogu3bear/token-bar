import SwiftUI

/// Exercises the saved-data startup path without using a real ledger or monitor.
enum HistoryPreview {
    @MainActor static func render(to destination: URL) throws {
        PreviewFixture.prepare()
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "local.tokenbar.history-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let today = Calendar.current.startOfDay(for: PreviewFixture.date.addingTimeInterval(-86400))
        try PreviewModelScope.run(root: root, defaults: defaults, prepare: { try seed(root: root, today: today) }) { model in
            try render(model, to: destination, today: today)
        }
    }

    private static func seed(root: URL, today: Date) throws {
        let support = root.appendingPathComponent("CodexTokenBar")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var ledger = Ledger()
        ledger.started = today
        ledger.costMetadataVersion = 2
        for (minute, output) in [(1, 100), (2, 250), (4, 150), (7, 400)] {
            ledger.entries.append(Entry(date: today.addingTimeInterval(Double(minute * 60)), session: "sample", model: "Sample model",
                                        tokens: Tokens(["input_tokens": output * 2, "output_tokens": output])))
        }
        for index in ledger.entries.indices {
            ledger.entries[index].harness = index < 2 ? "Claude Code" : "Codex Desktop"
            ledger.entries[index].provider = index < 2 ? "anthropic" : "openai"
        }
        try JSONEncoder().encode(ledger).write(to: support.appendingPathComponent("ledger.json"))
    }

    @MainActor private static func render(_ model: UsageModel, to destination: URL, today: Date) throws {
        model.appearance.websitePreset()
        precondition(model.snapshot.entries.count == 4, "Saved usage must be available before a scan")
        model.period = 4; model.startDate = today; model.endDate = today
        model.detailedReporting = true
        model.busy = true
        model.progress = .codex(completed: 25, total: 100)
        model.rebuild()
        let deadline = Date().addingTimeInterval(10)
        while model.filtering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(model.report.totals.output == 900 && model.busy, "Saved totals must render while import is busy")
        var incoming = Entry(date: today.addingTimeInterval(10 * 60), session: "sample", model: "Sample model",
                             tokens: Tokens(["input_tokens": 200, "output_tokens": 100]))
        incoming.harness = "Codex Desktop"; incoming.provider = "openai"
        incoming.recordID = String(repeating: "a", count: 64)
        model.scanner.persistAdmitted(incoming, fingerprint: incoming.recordID!, date: incoming.date)
        let updateDeadline = Date().addingTimeInterval(10)
        while model.report.totals.output != 1000 && Date() < updateDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(model.report.totals.output == 1000 && model.busy, "Incoming usage must appear before import finishes")
        try PreviewFixture.settle("history publication") { !model.filtering }
        model.snapshot.updated = PreviewFixture.date
        precondition(model.report.timeline.points.count == 5, "The new minute must extend the line")
        let host = NSHostingView(rootView: AppearanceHost(preferences: model.appearance) {
            DashboardRoot(model: model, initialDestination: .history).frame(width: 1064, height: 1200)
                .background(Color(nsColor: .windowBackgroundColor))
        }.previewStill())
        host.frame = NSRect(x: 0, y: 0, width: 1064, height: 1200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { PreviewModelScope.close(window) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        AppearanceRendering.capture(host, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: destination, options: .atomic)
        print("PASS: saved usage visible during import; native minute timeline rendered")
    }
}
