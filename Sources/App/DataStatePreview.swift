import SwiftUI

/// Exercises the actual prompt and cost sections with disposable synthetic reads.
enum DataStatePreview {
    @MainActor static func render(to directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PreviewFixture.prepare()
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let suite = "local.tokenbar.data-state-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearancePreferences(defaults: defaults)
        appearance.websitePreset()
        let now = PreviewFixture.date, earlier = PreviewFixture.date.addingTimeInterval(-600)
        var sample = InsightAnalysis.build([PromptRecord(text: "Please review the Swift build", date: earlier, task: "sample")])
        sample.files = 1; sample.readAt = earlier
        var zero = InsightAnalysis.build([]); zero.readAt = now
        func entry(_ output: Int, priced: Bool = true) -> Entry {
            var entry = Entry(date: now, session: "sample", model: priced ? "gpt-6-astra" : "sample-unpriced", tokens: Tokens(), account: nil)
            entry.tokens = Tokens.canonical(input: 0, cacheRead: 0, cacheWrite: 0, output: output, reasoning: 0, convention: .cachedWithinInput)
            entry.tokens.cacheWrite = 0
            entry.provider = "openai"; entry.effort = "high"; entry.contextBand = "short"
            entry.tokenFields = UsageMetadata.fields; entry.costMetadataVersion = 1
            return entry
        }
        func report(_ entries: [Entry]) -> CostReport {
            CostReport.build(source: entries, query: UsageQuery(period: 1), catalog: [:], now: now)
        }
        for name in ["unavailable", "loading", "first-failure", "zero", "empty-selection", "partial", "refreshing", "stale-failure"] {
            var state = PromptReadState(), cost = CostReport()
            var refreshing = false
            var error: String?
            switch name {
            case "loading": state.begin(); refreshing = true
            case "first-failure": state.begin(); state.fail(); error = "Synthetic source unavailable."
            case "zero": state.succeed(zero); cost = report([entry(0)])
            case "empty-selection": state.succeed(zero); cost = report([])
            case "partial":
                var partial = sample; partial.skipped = 1
                state.succeed(partial); cost = report([entry(100), entry(100, priced: false)])
            case "refreshing": state.succeed(sample); state.begin(); cost = report([entry(100)]); refreshing = true
            case "stale-failure": state.succeed(sample); state.begin(); state.fail(); cost = report([entry(100)]); error = "Synthetic refresh failed."
            default: break
            }
            for surface in ["cost", "insights"] {
            let host = NSHostingView(rootView: AppearanceHost(preferences: appearance) {
                VStack(alignment: .leading, spacing: PageStyle.section) {
                    Text("Sample state: " + name).font(.title.bold())
                    if surface == "cost" {
                    CostSummary(report: cost, basis: .reference, refreshing: refreshing,
                                sourceDate: cost.calculatedAt == nil ? nil : earlier, sourceError: error,
                                sourceAvailable: name != "first-failure")
                    } else {
                        PromptInsightsSection(state: state)
                    }
                    Spacer(minLength: 0)
                }.padding(PageStyle.gutter).frame(width: 1064, height: 1250, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            }.previewStill())
            host.frame = NSRect(x: 0, y: 0, width: 1064, height: 1250)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            AppearanceRendering.capture(host, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: directory.appendingPathComponent(surface + "-" + name + ".png"))
            window.close()
            }
        }
        print("Rendered sixteen separate native availability surfaces: \(directory.path)")
    }
}
