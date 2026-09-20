import SwiftUI

/// Temporary files outlive every model-owned database and hosting autorelease.
/// This scope is used only by synthetic entry points, never by the app lifecycle.
enum PreviewModelScope {
    @MainActor static func run(root: URL, defaults: UserDefaults, releaseTimeout: TimeInterval = 15,
                              prepare: () throws -> Void = {}, body: (UsageModel) throws -> Void) throws {
        weak var releasedModel: UsageModel?
        weak var releasedIndex: EventIndex?
        weak var releasedArchive: RequestArchive?
        let result: Result<Void, Error> = autoreleasepool {
            do { try prepare() } catch { return .failure(error) }
            let model = UsageModel(previewRoot: root, defaults: defaults, referenceDate: PreviewFixture.date)
            releasedModel = model
            releasedIndex = model.scanner.eventIndex
            releasedArchive = model.scanner.requestArchive
            let result = Result { try body(model) }
            do {
                try PreviewFixture.settle("preview background work") {
                    !model.filtering && !model.comparisons.busy && !model.insights.busy && !model.usageInsights.busy
                }
            } catch { return .failure(error) }
            return result
        }
        // A queued publication can briefly retain the model after its view closes.
        // If a fixture leaks an owner, fail visibly and preserve its files for
        // diagnosis instead of unlinking a database that is still open.
        try PreviewFixture.settle("preview resource release", timeout: releaseTimeout) {
            releasedModel == nil && releasedIndex == nil && releasedArchive == nil
        }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try result.get()
    }

    /// One PNG still: cache the hosted view in its window appearance, then write atomically.
    @MainActor static func png(_ view: NSView, to destination: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        AppearanceRendering.capture(view, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// Closed AppKit windows can remain retained by the application. Detach only
    /// fixture-owned hosting content before allowing its disposable model to die.
    @MainActor static func close(_ window: NSWindow?) {
        window?.contentViewController = nil
        window?.contentView = nil
        window?.close()
    }

    @MainActor static func verify() throws {
        PreviewFixture.prepare()
        _ = NSApplication.shared
        enum Expected: Error { case failure }
        for mode in ["return", "throw", "setup-throw", "pending-report", "retained-window", "retained-owner"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-lifecycle-" + UUID().uuidString)
            let suite = "local.tokenbar.lifecycle." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var caught = false
            var held: UsageModel?
            weak var heldArchive: RequestArchive?
            var cleanupFailed = false
            var retainedWindow: NSWindow?
            do {
                try run(root: root, defaults: defaults, releaseTimeout: mode == "retained-owner" ? 0.1 : 15, prepare: {
                    if mode == "setup-throw" {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        throw Expected.failure
                    }
                }) { model in
                    precondition(model.scanner.eventIndex != nil && model.scanner.requestArchive != nil)
                    if mode == "retained-window" {
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentViewController = NSHostingController(rootView: AppearanceHost(preferences: model.appearance) { Text("Synthetic fixture").environment(model) })
                        retainedWindow = window
                        close(window)
                    }
                    if mode == "throw" { throw Expected.failure }
                    if mode == "pending-report" { model.detailedReporting = true; model.rebuild() }
                    if mode == "retained-owner" { held = model; heldArchive = model.scanner.requestArchive }
                }
            } catch Expected.failure { caught = true }
            catch {
                guard mode == "retained-owner", error.localizedDescription.contains("preview resource release") else { throw error }
                cleanupFailed = true
                precondition(FileManager.default.fileExists(atPath: root.path) && held != nil && heldArchive != nil)
                print("PASS: retained preview owner reports cleanup failure and preserves its open files")
            }
            precondition(cleanupFailed == (mode == "retained-owner"))
            precondition(retainedWindow?.contentViewController == nil)
            retainedWindow = nil
            held = nil
            try PreviewFixture.settle("retained test owner release") { heldArchive == nil }
            if cleanupFailed { try FileManager.default.removeItem(at: root) }
            precondition(caught == (mode == "throw" || mode == "setup-throw"), "Original preview failure must survive cleanup")
            precondition(!FileManager.default.fileExists(atPath: root.path), "Released preview roots must be removed")
            print("PASS: preview lifecycle " + mode + " releases model/databases before removing its root")
        }
    }
}
