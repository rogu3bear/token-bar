import Foundation
import AppKit
import SwiftUI
func sameColor(_ left: Color, _ right: Color) -> Bool {
    NSColor(left).usingColorSpace(.sRGB) == NSColor(right).usingColorSpace(.sRGB)
}
let suite = "local.codex-token-bar.appearance-test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let style = AppearancePreferences(defaults: defaults)
assert(style.mode == "System" && style.followsSystemAccent)
assert(sameColor(style.color, Color(nsColor: .controlAccentColor)), "absent accent follows the macOS control accent")
style.websitePreset()
let restored = AppearancePreferences(defaults: defaults)
assert(restored.mode == "Dark" && restored.hex == AppearancePreferences.marketingAccent)
restored.setColor(.init(red: 1, green: 0, blue: 0))
assert(AppearancePreferences(defaults: defaults).hex == "FF0000")
defaults.set("invalid", forKey: "appearance.accent")
let recovered = AppearancePreferences(defaults: defaults)
assert(recovered.followsSystemAccent && sameColor(recovered.color, Color(nsColor: .controlAccentColor)))
defaults.set("65E0BB", forKey: "appearance.accent")
let keptMint = AppearancePreferences(defaults: defaults)
assert(keptMint.hex == "65E0BB" && !keptMint.followsSystemAccent, "a saved Mint hex is not migrated")
defaults.set("D5F566", forKey: "appearance.accent")
assert(AppearancePreferences(defaults: defaults).hex == "D5F566", "a saved Lime hex remains a custom accent")
print("PASS: appearance defaults follow macOS accent, website preset, custom persistence, invalid recovery and saved Mint")

assert(Destination.capsule == [.history, .cost, .accounts])
assert(!Destination.capsule.contains(.insights) && !Destination.capsule.contains(.menuBar) && !Destination.capsule.contains(.appearance))
assert(Destination.settings == [.menuBar, .appearance])
assert(Destination.accounts.title == "Allowances")
print("PASS: report navigation contains History, Cost and Allowances only")
assert(FirstRunAccess.needsExplanation(defaults))
assert(FirstRunAccess.needsExplanation(defaults), "Viewing or dismissing does not accept local access")
FirstRunAccess.accept(defaults)
assert(!FirstRunAccess.needsExplanation(UserDefaults(suiteName: suite)!))
assert(defaults.string(forKey: "appearance.mode") != nil, "Access acknowledgement preserves appearance")
assert(ImportProgress.discovering.fraction == nil)
assert(ImportProgress.codex(completed: 0, total: 0).fraction == nil)
assert(ImportProgress.codex(completed: 25, total: 100).fraction == 0.25)
assert(ImportProgress.otherTools.fraction == nil && ImportProgress.costDetails.fraction == nil)
print("PASS: local-access acknowledgement persists only on acceptance; import stages never invent whole-import percentages")

let colors = AppearancePreferences(defaults: defaults)
assert(colors.toolColors.isEmpty && !colors.toolsFollowAccent)
colors.setToolColor(.init(red: 1, green: 0, blue: 0), id: "codex")
colors.setToolColor(.init(red: 0, green: 0, blue: 1), id: "claude")
let reopenedColors = AppearancePreferences(defaults: defaults)
assert(reopenedColors.toolColors["codex"] == "FF0000" && reopenedColors.toolColors["claude"] == "0000FF")
reopenedColors.toolsFollowAccent = true
reopenedColors.hex = "00FF00"
let shared = AppearancePreferences(defaults: defaults)
assert(shared.toolsFollowAccent && shared.toolColors["codex"] == "FF0000")
assert(sameColor(shared.toolPalette.color("codex", fallback: .red), shared.foreground))
shared.toolsFollowAccent = false
assert(sameColor(shared.toolPalette.color("codex", fallback: .green), shared.foreground), "Legacy tool colors cannot compete with the app accent")
defaults.set(["codex": "invalid", "claude": "123456"], forKey: "appearance.toolColors")
let repairedColors = AppearancePreferences(defaults: defaults)
assert(repairedColors.toolColors["codex"] == nil && repairedColors.toolColors["claude"] == "123456")
print("PASS: legacy tool colors remain stored, never override the app accent, and reject invalid values")

let claudeProgress = ImportProgress.work(title: "Reading Claude history", completed: 25, total: 100, unit: "files")
assert(claudeProgress.fraction == 0.25 && claudeProgress.detail.contains("75 remaining"))
assert(ImportProgress.work(title: "Reading Claude history", completed: 0, total: 0, unit: "files").fraction == nil)
assert(ImportProgress.codex(completed: 25, total: 100).detail == claudeProgress.detail,
       "Codex file remaining uses the same checked-count face as other tools")
let undiscovered = ImportProgress.work(title: "Reading Claude history", completed: 0, total: 0, unit: "files")
assert(ImportProgress.codex(completed: 0, total: 0).detail == undiscovered.detail,
       "A Codex stage with no files yet is still finding work, not 0 remaining")
print("PASS: measured work shows actual completed fraction and remaining count; undiscovered work has no percentage")

// The canonical preset is complete even when an older profile has competing colors.
colors.toolColors = ["codex": "0000FF", "claude": "FF6600", "grok": "FF0000"]
colors.toolsFollowAccent = false
colors.websitePreset()
assert(colors.mode == "Dark" && colors.hex == AppearancePreferences.marketingAccent)
for id in ["codex", "claude", "grok", "future-tool"] {
    assert(sameColor(colors.toolPalette.color(id, fallback: .blue), colors.foreground))
}
colors.mode = "Light"
colors.hex = "AB70E0"
let custom = AppearancePreferences(defaults: defaults)
assert(custom.mode == "Light" && custom.hex == "AB70E0")
assert(custom.toolColors["codex"] == "0000FF", "Theme repair preserves old saved values")
assert(sameColor(custom.toolPalette.color("claude", fallback: .orange), custom.foreground))
print("PASS: canonical Dark/Frost preset and customized Light/accent both resolve exactly one accent")

struct ThemeProbe: View {
    @Environment(\.appAccent) var accent
    @Environment(\.toolPalette) var palette
    var body: some View {
        HStack(spacing: 0) {
            accent
            palette.color("codex", fallback: .blue)
            palette.color("claude", fallback: .orange)
            MethodButton(title: "") {}.frame(width: 40, height: 40)
        }.frame(width: 160, height: 40).background(Color(nsColor: .windowBackgroundColor))
    }
}
// Fixed reference values make the contrast formula independently checkable.
assert(abs(AccentContrast.ratio(.black, on: .white) - 21) < 0.001)
assert(abs(AccentContrast.ratio(NSColor(AppearancePreferences.color("D5F566")), on: .white) - 1.22) < 0.08)
struct ContrastControls: View {
    var body: some View {
        VStack(spacing: 16) {
            MethodButton(title: "Counting method and evidence") {}
            HStack {
                Button("Done") {}.keyboardShortcut(.defaultAction)
                Button("Match website preview") {}.buttonStyle(.borderedProminent)
                Toggle("Enabled", isOn: .constant(true))
            }
        }.padding(20).frame(width: 500, height: 120)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
MainActor.assumeIsolated {
_ = NSApplication.shared
// Opposite host appearance catches split AppKit/SwiftUI drawing contexts.
for (mode, hex) in [("Dark", AppearancePreferences.marketingAccent), ("Light", AppearancePreferences.marketingAccent), ("Light", "174A70"), ("Dark", "174A70"), ("Light", "AB70E0"), ("Light", "767676"), ("Dark", "777777")] {
    NSApp.appearance = NSAppearance(named: mode == "Dark" ? .aqua : .darkAqua)
    colors.mode = mode; colors.hex = hex
    let host = NSHostingView(rootView: AppearanceHost(preferences: colors) { ThemeProbe() })
    host.frame = NSRect(x: 0, y: 0, width: 160, height: 40)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    AppearanceRendering.capture(host, to: bitmap)
    // Bitmap output is display-color-managed. Compare consumers to the actual
    // root accent swatch, not untransformed preference RGB values.
    let expected = bitmap.colorAt(x: bitmap.pixelsWide / 8, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    if mode == "Dark" && hex == AppearancePreferences.marketingAccent {
        assert(expected.blueComponent > expected.redComponent + 0.1, "Canonical Dark/Frost must retain frost")
    } else if mode == "Light" && hex == "174A70" {
        assert(expected.blueComponent > expected.redComponent + 0.1, "Legible custom hue must survive")
    } else {
        let channels = [expected.redComponent, expected.greenComponent, expected.blueComponent]
        assert(channels.max()! - channels.min()! < 0.025, "Fallback must be native neutral ink, not another hue")
    }
    let appearance = NSAppearance(named: mode == "Dark" ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        for background: NSColor in [.windowBackgroundColor, .controlBackgroundColor, .textBackgroundColor] {
            let ratio = AccentContrast.ratio(NSColor(colors.foreground), on: background)
            print(String(format: "%@/%@ foreground contrast %.2f:1", mode, hex, ratio))
            assert(ratio >= 4.5, "Accent or adaptive foreground must meet small-text contrast")
        }
    }
    for fraction in [0.125, 0.375, 0.625] {
        let pixel = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * fraction), y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        assert(abs(pixel.redComponent - expected.redComponent) < 0.025)
        assert(abs(pixel.greenComponent - expected.greenComponent) < 0.025)
        assert(abs(pixel.blueComponent - expected.blueComponent) < 0.025)
    }
    let background = bitmap.colorAt(x: bitmap.pixelsWide - 1, y: 0)!.usingColorSpace(.sRGB)!
    var visibleLinkPixels = 0
    for x in (bitmap.pixelsWide * 3 / 4)..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            let pixel = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            if AccentContrast.ratio(pixel, on: background) >= 4.5 { visibleLinkPixels += 1 }
        }
    }
    assert(visibleLinkPixels > 5, "Rendered method icon must contain legible ink")
    let output = URL(fileURLWithPath: "build/tests/contrast-\(mode)-\(hex).png")
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
    print(String(format: "Rendered %@/%@ ink contrast %.2f:1", mode, hex, AccentContrast.ratio(expected, on: background)))
    window.close()
    let controls = NSHostingView(rootView: AppearanceHost(preferences: colors) { ContrastControls() })
    controls.frame = NSRect(x: 0, y: 0, width: 500, height: 120)
    let controlsWindow = NSWindow(contentRect: controls.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    controlsWindow.isReleasedWhenClosed = false
    controlsWindow.contentView = controls
    controlsWindow.makeKeyAndOrderFront(nil)
    controls.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let controlsBitmap = controls.bitmapImageRepForCachingDisplay(in: controls.bounds)!
    AppearanceRendering.capture(controls, to: controlsBitmap)
    let canvas = controlsBitmap.colorAt(x: 0, y: 0)!
    var textInk = 0
    // The first row contains the real MethodButton label, separate from controls.
    for x in 0..<controlsBitmap.pixelsWide {
        for y in 0..<(controlsBitmap.pixelsHigh / 2) {
            if AccentContrast.ratio(controlsBitmap.colorAt(x: x, y: y)!, on: canvas) >= 4.5 { textInk += 1 }
        }
    }
    assert(textInk > 40, "Method text must render legibly, not only its icon")
    try! controlsBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/controls-\(mode)-\(hex).png"))
    controlsWindow.close()
}
}
print("PASS: rendered appAccent, legacy tool consumers and native accent agree under opposite host appearances")

// Architectural guards complement the pixel test: new render routes must not
// silently bypass the host or introduce another drawing/appearance boundary.
let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources")
let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!
for case let file as URL in enumerator where file.pathExtension == "swift" {
    let source = try String(contentsOf: file, encoding: .utf8)
    if file.lastPathComponent != "Appearance.swift" {
        for literal in [".blue", ".purple", ".mint", ".green", "Color(red:"] {
            assert(!source.contains(literal), "Hard-coded decorative accent in " + file.path)
        }
        assert(!source.contains(".tint("), "Nested tint override in " + file.path)
        assert(!source.contains("environment(\\.appAccent"), "Nested appAccent override in " + file.path)
        assert(!source.contains("cacheDisplay(in:"), "Capture bypasses appearance boundary: " + file.path)
    }
    for line in source.components(separatedBy: "\n") where line.contains("NSHostingView(rootView:") || line.contains("NSHostingController(rootView:") {
        let direct = line.contains("rootView: AppearanceHost(preferences:")
        let namedHost = line.contains("rootView: view") && source.contains("let view = AppearanceHost(preferences:")
        let menuHost = line.contains("rootView: menuView(now:") && source.contains("func menuView(now: Date) -> some View {\n            AppearanceHost(preferences:")
        assert(direct || namedHost || menuHost, "Hosting entry bypasses AppearanceHost: " + file.path)
    }
    if file.lastPathComponent.hasSuffix("Preview.swift") && source.contains("NSHostingView(rootView:") {
        assert(source.contains("websitePreset()"), "Preview lacks canonical theme: " + file.path)
    }
}
let product = try String(contentsOf: sourceRoot.appendingPathComponent("App/ProductPreview.swift"), encoding: .utf8)
assert(product.contains("else { DashboardRoot(model: model, initialDestination: .now) }"), "Live still must render the shipping host")
let motion = try String(contentsOf: sourceRoot.appendingPathComponent("App/ProductMotionPreview.swift"), encoding: .utf8)
assert(motion.contains("QuickLiveView(model: model, monitor: model.live, meter: model.tachometer)"))
assert(motion.contains("MenuBarPresentation.combined("))
assert(!motion.contains("MenuBarPresentation.attributed("))
print("PASS: all hosting/capture routes retain the appearance boundary and marketing uses shipping composition")

PreviewFixture.prepare()
assert(PreviewFixture.date.ISO8601Format() == "2026-09-12T12:00:00Z")
assert(Calendar.current.component(.hour, from: PreviewFixture.date) == 12)
let previewScope = try String(contentsOf: sourceRoot.appendingPathComponent("App/PreviewModelScope.swift"), encoding: .utf8)
assert(product.contains("PreviewModelScope.run(root: root, defaults: defaults)"))
assert(previewScope.contains("referenceDate: PreviewFixture.date"))
assert(product.contains("let now = PreviewFixture.date"))
assert(product.contains("$0.disablesAnimations = true"))
let costPreview = try String(contentsOf: sourceRoot.appendingPathComponent("App/CostPreview.swift"), encoding: .utf8)
assert(costPreview.contains("DashboardRoot(model: model, initialDestination: page)"))
assert(costPreview.contains("for page in Destination.capsule"), "Default page stills are product destinations")
assert(!costPreview.contains("for page in Destination.allCases"))
assert(!costPreview.contains("CostView(model: model)"), "Cost product image must retain shipping navigation")
let appSource = try String(contentsOf: sourceRoot.appendingPathComponent("App/App.swift"), encoding: .utf8)
let liveSource = try String(contentsOf: sourceRoot.appendingPathComponent("Features/Live/LiveOverview.swift"), encoding: .utf8)
assert(liveSource.contains("Button(\"Settings\") { commands.settings() }"))
assert(liveSource.contains("Button(\"Reports\") { commands.reports(nil) }"))
assert(appSource.contains("window.title = \"Token Bar — Reports\""))
assert(appSource.contains("window.title = \"Token Bar — Settings\""))
assert(!appSource.contains("Button(\"Menu bar settings\")"))
let menuSettings = try String(contentsOf: sourceRoot.appendingPathComponent("Features/Settings/MenuBarSettings.swift"), encoding: .utf8)
assert(menuSettings.contains("AppearanceControls(preferences: appearance)"))
assert(!menuSettings.contains("PageHeader(\"Appearance\""), "Combined settings must not wrap a second Appearance page")
let navigation = try String(contentsOf: sourceRoot.appendingPathComponent("Navigation/DashboardNavigation.swift"), encoding: .utf8)
assert(navigation.contains("private let destinations = Destination.capsule"))
let accountsView = try String(contentsOf: sourceRoot.appendingPathComponent("Features/Accounts/AccountsView.swift"), encoding: .utf8)
assert(accountsView.contains("AccountAllowanceDisclosure"))
assert(accountsView.contains("Current remaining from installed Codex, Claude Code, and Grok."))
assert(accountsView.contains("No saved account observations yet. Sign in through a supported tool"))
assert(!accountsView.contains("No saved Codex account observations"))
assert(!accountsView.contains("remaining at last reading"), "Allowances must not reprint remaining under the disclosures")
assert(!accountsView.contains("Claude’s current cached quota appears on Now"))
assert(menuSettings.contains(".labelsHidden()"), "Rate units must not steal width from the segmented control")
let quotaGuardViews = try String(contentsOf: sourceRoot.appendingPathComponent("Features/QuotaGuard/QuotaGuardViews.swift"), encoding: .utf8)
assert(!quotaGuardViews.contains("All allowances"), "Allowances is a capsule tab; Guard must not keep a competing expander")
assert(quotaGuardViews.contains("More warnings"))
let welcome = try String(contentsOf: sourceRoot.appendingPathComponent("App/FirstRunWelcome.swift"), encoding: .utf8)
assert(welcome.contains("Codex, Claude Code, and Grok"))
let speedHeader = try String(contentsOf: sourceRoot.appendingPathComponent("Features/Live/ToolSpeedCard.swift"), encoding: .utf8)
assert(!speedHeader.contains("Estimated ·") && !speedHeader.contains("Rate report"), "Coverage and rate age belong in the method sheet")
let nowSummary = try String(contentsOf: sourceRoot.appendingPathComponent("Features/Live/ToolQuotaSummary.swift"), encoding: .utf8)
assert(!nowSummary.contains("Text(\"Account allowances\")"), "Idle Now must not retitle remaining as the Allowances destination")
assert(costPreview.contains("else { state = \"populated\" }"))
assert(costPreview.contains("PreviewModelScope.run(root: root, defaults: defaults)"))
assert(motion.contains("let elapsed = Double(frame) / 30"), "Motion samples must not depend on rendering speed")
print("PASS: fixed UTC fixture clock, shipping Cost shell, clean default and frame-indexed motion samples")

assert(EnvironmentValues().evaluationDate == nil, "Production views retain their native clock")
let fixedAge = RelativeAgeText.label(from: PreviewFixture.date.addingTimeInterval(-600), to: PreviewFixture.date)
assert(fixedAge == "10 minutes")
assert(RelativeAgeText.label(from: PreviewFixture.date.addingTimeInterval(-600), to: PreviewFixture.date) == fixedAge)
print("PASS: production clock remains uninjected; fixture relative age is explicit and stable")

// Exercise the shipping chart, including its native symbol/line legend. Palette
// swatches alone cannot catch colors synthesized by Swift Charts.
MainActor.assumeIsolated {
    PreviewFixture.prepare()
    let date = PreviewFixture.date
    var first = Tokens(); first.output = 100
    var second = Tokens(); second.output = 200
    let codex = UsageTimeline(points: [DailyUsage(date: date, tokens: first), DailyUsage(date: date.addingTimeInterval(60), tokens: second)], minuteResolution: true)
    let claude = UsageTimeline(points: [DailyUsage(date: date, tokens: second), DailyUsage(date: date.addingTimeInterval(60), tokens: second)], minuteResolution: true)
    let series = [ToolUsageTimeline(tool: .codex, totals: second, timeline: codex), ToolUsageTimeline(tool: .claude, totals: second, timeline: claude)]
    for (mode, hex) in [("Dark", AppearancePreferences.marketingAccent), ("Light", AppearancePreferences.marketingAccent), ("Light", "174A70")] {
        colors.mode = mode; colors.hex = hex
        NSApp.appearance = NSAppearance(named: mode == "Dark" ? .aqua : .darkAqua)
        let host = NSHostingView(rootView: AppearanceHost(preferences: colors) {
            UsageTimelineChart(timeline: codex, tools: series)
                .padding(20).frame(width: 600).background(Color(nsColor: .windowBackgroundColor))
        })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        AppearanceRendering.capture(host, to: bitmap)
        var unexpected = 0, accentPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let r = pixel.redComponent, g = pixel.greenComponent, b = pixel.blueComponent
                guard max(r, g, b) - min(r, g, b) > 0.10 else { continue }
                let matches = mode == "Dark" ? (b > r + 0.10 && g > r) :
                    hex == "174A70" ? (b > r + 0.10 && g > r) : false
                if matches { accentPixels += 1 } else { unexpected += 1 }
            }
        }
        assert(unexpected == 0, "Shipping chart/legend introduced another hue: \(mode)/\(hex), \(unexpected) pixels")
        if mode == "Dark" || hex == "174A70" { assert(accentPixels > 100, "The chart must retain its legible accent") }
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/chart-\(mode)-\(hex).png"))
        window.close()
    }
    print("PASS: shipping minute chart and native legend retain one resolved accent in Dark, Light and custom states")

    colors.websitePreset()
    func height<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: AppearanceHost(preferences: colors) { view.frame(width: 600) }).fittingSize.height
    }
    let available = height(SummaryMetric(title: "RECORDED TOKENS", value: "2.33M"))
    let unavailable = height(SummaryMetric(title: "RECORDED TOKENS", value: "—"))
    assert(available == unavailable, "Availability changes must preserve the metric frame")
    for enabled in [true, false] {
        let headerHeight = height(PageHeader("History", subtitle: "Local records") {
            Button("Refresh history") {}.disabled(!enabled)
            Button("Export CSV") {}.disabled(!enabled)
        })
        let baseline = height(PageHeader("History", subtitle: "Local records") {
            Button("Refresh history") {}
            Button("Export CSV") {}
        })
        assert(headerHeight == baseline, "Disabled actions must preserve the page-header frame")
    }
    for emphasized in [false, true] {
        for value in [0.0, 0.5, 1.0] {
            let host = NSHostingView(rootView: AppearanceHost(preferences: colors) {
                ProgressView(value: value).progressViewStyle(ReportMagnitudeStyle(emphasized: emphasized))
                    .frame(width: 300).padding(10).background(Color(nsColor: .windowBackgroundColor))
            })
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            assert(host.frame.height == 30, "Magnitude and selection must not change row height")
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            AppearanceRendering.capture(host, to: bitmap)
            let y = bitmap.pixelsHigh / 2
            let start = Int(10 * CGFloat(bitmap.pixelsWide) / 320)
            let end = bitmap.pixelsWide - start
            var filled = 0
            for x in start..<end {
                let pixel = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if pixel.blueComponent > 0.5 && pixel.blueComponent > pixel.redComponent + 0.1 { filled += 1 }
            }
            assert(abs(Double(filled) / Double(end - start) - value) < 0.02, "Recorded magnitude must preserve its actual fraction, including zero")
            window.close()
        }
    }
    print("PASS: shared headers, metric availability and contribution selection retain stable geometry and actual fractions")
}

// The module header stays stable while its disclosure opens below it.
MainActor.assumeIsolated {
    let now = PreviewFixture.date
    let reading = QuotaReading(accountID: "synthetic-account", bucket: "sample", name: "Sample", window: "primary", minutes: 300,
                               used: 36, reset: now.addingTimeInterval(3600), date: now)
    let quota = ToolQuotaState(readings: [reading], samples: [reading], accountLabel: "Synthetic account")
    let idleMeter = Tachometer(defaults: defaults)
    idleMeter.activity = ActivitySnapshot(readAt: now, referenceDate: now)
    @MainActor func capture<V: View>(_ name: String, _ content: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: AppearanceHost(preferences: colors) { content.frame(width: width).padding(16) })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        AppearanceRendering.capture(host, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/allowance-" + name + ".png"))
        let height = host.frame.height; window.close(); return height
    }
    for (mode, hex) in [("Dark", AppearancePreferences.marketingAccent), ("Light", AppearancePreferences.marketingAccent), ("Light", "2345AF")] {
        colors.mode = mode; colors.hex = hex
        let collapsed = capture("collapsed-" + mode + hex,
            CompactToolRate(tool: .codex, meter: idleMeter, quota: quota, now: now), width: 408)
        let expanded = capture("expanded-" + mode + hex,
            CompactToolRate(tool: .codex, meter: idleMeter, quota: quota, now: now, expanded: true), width: 408)
        assert(expanded == collapsed, "Expansion changes the chevron without moving the module's headline readings")
        let accounts = capture("accounts-" + mode + hex,
            AccountAllowanceSection(tools: [.codex, .claude], quota: { _ in quota }, now: now), width: 812)
        assert(accounts < 140, "Collapsed allowances must leave room for live gauges at the minimum window")
    }
    print("PASS: allowance rows and module headers retain intrinsic sizing in dark/light/custom accent")
}

assert(compact(999) == "999")
assert(compact(TokenFormatting.thousand) == "1.0K")
assert(compact(TokenFormatting.million) == "1.00M")
assert(compact(TokenFormatting.billion) == "1.00B")
print("PASS: History and Cost compact counts share TokenFormatting magnitude cutovers")

// Measure native layout boxes and retained SwiftUI identity, not a screenshot's
// pixels or a duplicate arithmetic implementation of the layout.
private final class ProviderLayoutProbes {
    var views: [String: NSView] = [:]
    func frame(_ key: String) -> CGRect { views[key]!.convert(views[key]!.bounds, to: nil) }
}
private struct ProviderLayoutProbe: NSViewRepresentable {
    let key: String
    let probes: ProviderLayoutProbes
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); probes.views[key] = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
private final class ProviderLayoutState: ObservableObject {
    @Published var tools = ["codex", "claude", "grok"]
}
private struct ProviderLayoutFixture: View {
    @ObservedObject var state: ProviderLayoutState
    let probes: ProviderLayoutProbes
    var body: some View {
        ProviderColumnsLayout(columns: state.tools.count) {
            ForEach(state.tools, id: \.self) { tool in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tool).font(.title2)
                    Text(tool == "claude" ? "Inspect activity read failure with additional context and unavailable reporting" : "Estimated output tokens per second")
                        .fixedSize(horizontal: false, vertical: true)
                }.background(ProviderLayoutProbe(key: tool + "-header", probes: probes))
            }
            ForEach(state.tools, id: \.self) { tool in
                Color.clear.frame(height: 210).background(ProviderLayoutProbe(key: tool + "-gauge", probes: probes))
            }
            ForEach(state.tools, id: \.self) { _ in Divider() }
            ForEach(state.tools, id: \.self) { tool in
                Text(tool == "codex" ? "A long model name and an activity error that must stay within this provider's own column" : "Model details")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ProviderLayoutProbe(key: tool + "-footer", probes: probes))
            }
        }
    }
}
MainActor.assumeIsolated {
    for width: CGFloat in [796, 1096] {
        let state = ProviderLayoutState(), probes = ProviderLayoutProbes()
        let host = NSHostingView(rootView: ProviderLayoutFixture(state: state, probes: probes).frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        var retained: [String: NSView] = [:]
        for tools in [["codex", "claude", "grok"], ["codex", "grok"], ["grok"], ["codex", "claude", "grok"]] {
            state.tools = tools
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let firstGauge = probes.frame(tools[0] + "-gauge")
            for (index, tool) in tools.enumerated() {
                let header = probes.frame(tool + "-header"), gauge = probes.frame(tool + "-gauge"), footer = probes.frame(tool + "-footer")
                assert(abs(header.midX - gauge.midX) < 1, "Intrinsic header must center on its own gauge through active-set changes")
                assert(abs(footer.midX - header.midX) < 1 && abs(footer.width - header.width) < 1, "Footer must use its own header's measure and center")
                assert(abs(gauge.minY - firstGauge.minY) < 1 && abs(gauge.height - 210) < 1, "Asymmetric text must preserve the shared gauge row")
                assert(header.width <= gauge.width + 1 && footer.width <= gauge.width + 1)
                if index > 0 {
                    let previous = probes.frame(tools[index - 1] + "-gauge")
                    assert(previous.maxX < gauge.minX, "Provider columns cannot overlap")
                    let separator = ProviderColumnsLayout(columns: tools.count).separatorPositions(width: width)[index - 1]
                    assert(abs(separator - (previous.maxX + gauge.minX) / 2) < 1, "Divider must bisect the actual inter-provider gap")
                }
                if let previous = retained[tool] { assert(previous === probes.views[tool + "-gauge"], "Surviving tool must retain its own gauge view identity") }
            }
            retained = Dictionary(uniqueKeysWithValues: tools.map { ($0, probes.views[$0 + "-gauge"]!) })
        }
    }
    print("PASS: native provider columns center intrinsic headers/footers on their own gauge, share asymmetric row heights, and retain tool identity across 3→2→1→3")
}

MainActor.assumeIsolated {
    let now = PreviewFixture.date
    let reading = QuotaReading(accountID: "synthetic-account", bucket: "sample", name: "Sample", window: "primary", minutes: 300,
                               used: 36, reset: now.addingTimeInterval(3600), date: now)
    let quota = ToolQuotaState(readings: [reading], samples: [reading], accountLabel: "Synthetic account")
    for width: CGFloat in [796, 1096] {
        for tools: [LiveTool] in [[.codex], [.codex, .claude]] {
            let probes = ProviderLayoutProbes()
            let host = NSHostingView(rootView: NowOccupancyStack(working: tools, remaining: { tool in
                AccountAllowanceDisclosure(tool: tool, quota: quota, now: now)
                    .background(ProviderLayoutProbe(key: tool.label + "-remaining", probes: probes))
            }, header: { tool in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tool.label).font(.title2)
                    Text("Estimated output tokens per second")
                }.background(ProviderLayoutProbe(key: tool.label + "-header", probes: probes))
            }, gauge: { tool in
                Color.clear.frame(height: 210).background(ProviderLayoutProbe(key: tool.label + "-gauge", probes: probes))
            }, footer: { tool in
                Text("sample-model").frame(maxWidth: .infinity, alignment: .leading)
                    .background(ProviderLayoutProbe(key: tool.label + "-footer", probes: probes))
            }).frame(width: width))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            for tool in tools {
                let remaining = probes.frame(tool.label + "-remaining")
                let header = probes.frame(tool.label + "-header")
                let gauge = probes.frame(tool.label + "-gauge")
                assert(abs(remaining.midX - gauge.midX) < 1, "\(tool.label) remaining must share the gauge column center, not a full-bleed row")
                assert(abs(header.midX - gauge.midX) < 1)
                assert(remaining.width <= header.width + 1, "\(tool.label) remaining cannot span the dashboard while the speed header occupies one column")
                assert(header.midY > remaining.midY && remaining.maxY <= header.minY + 1, "\(tool.label) rate header must sit above remaining")
            }
        }
    }
    print("PASS: Now remaining occupies the same provider column as its speed header and gauge")
}

let largeNotice = NoticeContent(PreviewFixture.sourceDiagnostics)
assert(largeNotice.needsDetails && largeNotice.continuityCount == 2359)
assert(largeNotice.summary.contains("coverage remains incomplete"))
assert((0..<largeNotice.pageCount).map { largeNotice.page($0) }.joined() == PreviewFixture.sourceDiagnostics)
assert((0..<largeNotice.pageCount).allSatisfy { largeNotice.page($0).count <= NoticeContent.pageSize })
let unicodeNotice = NoticeContent(String(repeating: "🧑🏽‍💻é\n", count: 4000))
assert((0..<unicodeNotice.pageCount).map { unicodeNotice.page($0) }.joined() == unicodeNotice.message)
assert(!NoticeContent("Connection unavailable.").needsDetails)
assert(NoticeContent("Connection unavailable.").summary == "Connection unavailable.")
assert(NoticeContent("").summary.isEmpty)
let mixedNotice = NoticeContent(PreviewFixture.sourceDiagnostics + " Account service unavailable.")
assert(mixedNotice.summary.contains("include") && mixedNotice.summary.contains("all reported issues"))
assert(mixedNotice.page(mixedNotice.pageCount - 1).hasSuffix("Account service unavailable."))
assert(NoticeContent(String(repeating: "line\n", count: 12)).needsDetails)
print("PASS: bounded diagnostic summary counts warning occurrences; all original text survives paging, including Unicode")

// A retained diagnostic set must not push a normal page's content out of reach.
MainActor.assumeIsolated {
    for width in [360.0, 820.0] {
    let host = NSHostingView(rootView: ErrorNotice(message: PreviewFixture.sourceDiagnostics).frame(width: width))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let height = host.fittingSize.height
    print("Synthetic diagnostic notice: \(PreviewFixture.sourceDiagnostics.count) characters; height \(height)"); fflush(stdout)
    precondition(height <= 180, "Source diagnostics must leave room for page content")
    }
}
print("PASS: thousands of retained source diagnostics leave normal page content reachable")


assert(NowOccupancyCopy.line(sourcesKnown: false, occupied: false) == NowOccupancyCopy.noSources)
assert(NowOccupancyCopy.line(sourcesKnown: true, occupied: false) == NowOccupancyCopy.noneWorking)
assert(NowOccupancyCopy.line(sourcesKnown: true, occupied: true) == nil)
assert(NowOccupancyCopy.noneWorkingLine(sourcesKnown: false, occupied: false) == nil,
       "Dashboard Now must not stack 'not working' on top of missing tools")
assert(NowOccupancyCopy.noneWorkingLine(sourcesKnown: true, occupied: false) == NowOccupancyCopy.noneWorking)
assert(NowOccupancyCopy.noneWorkingLine(sourcesKnown: true, occupied: true) == nil)
print("PASS: Now empty occupancy copy distinguishes missing tools from idle-with-sources")

let zeroRead = ReadPresentation(hasResult: true)
assert(zeroRead.availability == .available && zeroRead.coverage == .complete && zeroRead.freshness == .current)
let noRead = ReadPresentation(hasResult: false, failed: true)
assert(noRead.availability == .unavailable && noRead.coverage == .unknown)
let retainedRead = ReadPresentation(hasResult: true, failed: true, partial: true)
assert(retainedRead.availability == .available && retainedRead.coverage == .partial && retainedRead.freshness == .stale)
let updatingRead = ReadPresentation(hasResult: true, refreshing: true, partial: true)
assert(updatingRead.freshness == .refreshing && updatingRead.coverage == .partial)
assert(ReadPresentation(hasResult: false, refreshing: true).freshness == .loading)
print("PASS: availability, coverage and freshness compose without converting absent data into zero")

let retainedGaps = Snapshot(updated: PreviewFixture.date, error: PreviewFixture.sourceDiagnostics)
assert(retainedGaps.readHealth.continuityCount == 2359 && retainedGaps.readHealth.affectedFiles == 2359)
assert(!retainedGaps.readHealth.failed && ReadPresentation(snapshot: retainedGaps).freshness == .current)
assert(ReadPresentation(snapshot: retainedGaps).caption == "Read completed · coverage incomplete")
let mixedFailure = Snapshot(updated: PreviewFixture.date, error: PreviewFixture.sourceDiagnostics + " Account service unavailable.")
assert(mixedFailure.readHealth.failed)
print("PASS: full legacy diagnostic payload retains source counts and coverage while mixed unknown failures stay failures")
