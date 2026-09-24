import SwiftUI

/// Exercises the shipping window/actions with CostPreview's isolated model.
enum HistoryNavigationPreview {
    @MainActor static func verify(_ model: UsageModel, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let delegate = AppDelegate()
        delegate.model = model
        delegate.configureNavigationActions()
        defer { delegate.detailWindow?.close(); delegate.settingsWindow?.close() }
        var receipts: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "HistoryNavigationPreview", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
            receipts.append(message)
        }
        var million = Tokens()
        million.input = 1_000_000
        million.output = 1_000_000
        try require(UsageMetric.total.rawValue.uppercased() == "TOTAL PROCESSED",
                    "History total card title is UsageMetric.total")
        try require(UsageMetric.output.rawValue.uppercased() == "OUTPUT",
                    "History output card title is UsageMetric.output")
        try require(UsageMetric.output.formatted(million) == "1.00M",
                    "History output compact uses TokenFormatting")
        try require(UsageMetric.total.formatted(million) == "2.00M",
                    "History total compact uses TokenFormatting")
        func settle() throws {
            let deadline = Date().addingTimeInterval(15)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            while model.filtering && Date() < deadline
            try require(!model.filtering, "Report publication settled")
            delegate.detailWindow?.contentView?.layoutSubtreeIfNeeded()
        }
        model.showDetails?()
        try settle()
        try require(delegate.dashboardSelection.destination == .history, "Reports defaults to History")
        try require(delegate.detailWindow?.title == "Token Bar — Reports", "Reports entry and window title agree")
        try require(!Destination.capsule.contains(.now), "Live is not a competing report destination")
        model.showMenuBarSettings?()
        let settingsWindow = delegate.settingsWindow
        model.showMenuBarSettings?()
        try require(delegate.settingsWindow === settingsWindow, "Settings reuses its existing window")
        delegate.settingsWindow?.orderOut(nil)
        // The exact callback used by the Today chart opens History.
        model.showHistory?()
        try settle()
        try require(delegate.dashboardSelection.destination == .history, "Today opens History on first window creation")
        try require(model.detailedReporting, "First-open History enables detailed reporting")
        let window = delegate.detailWindow
        let host = window?.contentViewController
        model.search = "gpt"
        delegate.dashboardSelection.destination = .cost
        try settle()
        model.showDetails?()
        try require(delegate.dashboardSelection.destination == .cost, "Reports preserves the selected Cost destination")
        window?.orderOut(nil)
        model.showHistory?()
        try settle()
        try require(delegate.dashboardSelection.destination == .history, "Today selects History in an existing hidden window")
        try require(delegate.detailWindow === window && delegate.detailWindow?.contentViewController === host,
                    "Navigation preserves the window and hosting controller")
        try require(model.search == "gpt", "Navigation preserves report filters")
        delegate.dashboardSelection.destination = .now
        try settle()
        try require(!model.detailedReporting, "Returning to Now disables detailed reporting")
        model.showDetails?()
        try require(delegate.dashboardSelection.destination == .now, "Reports preserves Now")
        if CommandLine.arguments.contains("--large-history") {
            let now = model.referenceDate ?? Date()
            let sample = model.snapshot.entries[0]
            model.snapshot = Snapshot(entries: (0..<100_000).map { position in
                var row = sample
                row.session = "synthetic-task-\(position % 1000)"
                row.date = now.addingTimeInterval(Double(-position * 10))
                return row
            }, updated: now)
            model.search = ""; model.period = 3
            model.rebuild()
            try settle()
            try require(model.report.entries.count == 100_000, "Large synthetic history is prepared before navigation")
        }
        // Re-entering pages uses the prepared report; no source or query changed.
        let publications = model.reportPublicationCount
        var navigationMilliseconds: [Double] = []
        for destination in [Destination.history, .cost, .now, .history, .cost, .insights, .history] {
            let start = Date()
            delegate.dashboardSelection.destination = destination
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            delegate.detailWindow?.contentView?.layoutSubtreeIfNeeded()
            navigationMilliseconds.append(Date().timeIntervalSince(start) * 1000)
        }
        try require(model.reportPublicationCount == publications, "Warm page changes perform no report rebuild or publication")
        try JSONSerialization.data(withJSONObject: ["synthetic": true, "checks": receipts, "navigationMilliseconds": navigationMilliseconds], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("receipt.json"))
        print("PASS: Today/History routing, retained Reports selection, stable host and report state")
    }
}
