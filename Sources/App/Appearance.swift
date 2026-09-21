import Observation
import SwiftUI

struct ToolPalette {
    // Legacy per-tool choices are retained in preferences, never rendered together.
    static func defaultColor(_ id: String) -> Color { .primary }
    var overrides: [String: Color] = [:]
    var followsAccent = true
    var accent: Color = AccentContrast.foreground(Color(nsColor: .controlAccentColor))
    func color(_ id: String, fallback: Color) -> Color { accent }

}
struct ToolPaletteKey: EnvironmentKey { static let defaultValue = ToolPalette() }
struct AppAccentKey: EnvironmentKey { static let defaultValue = AccentContrast.foreground(Color(nsColor: .controlAccentColor)) }
struct PresentationClockKey: EnvironmentKey { static let defaultValue = PresentationClock() }
extension EnvironmentValues {
    var presentationClock: PresentationClock { get { self[PresentationClockKey.self] } set { self[PresentationClockKey.self] = newValue } }
    var toolPalette: ToolPalette { get { self[ToolPaletteKey.self] } set { self[ToolPaletteKey.self] = newValue } }
    var appAccent: Color { get { self[AppAccentKey.self] } set { self[AppAccentKey.self] = newValue } }
}
@Observable final class AppearancePreferences {
    static let marketingAccent = "D5F566"
    static let systemAccent = "SYSTEM"
    static let presets = [("Mint", "65E0BB"), ("Lime", "D5F566"), ("Blue", "67B9FF"), ("Coral", "FFAB91")]
    static var accentChoices: [(String, String)] { [("macOS", systemAccent)] + presets }
    var mode: String { didSet { defaults.set(mode, forKey: "appearance.mode") } }
    var hex: String { didSet { defaults.set(hex, forKey: "appearance.accent") } }
    var toolColors: [String: String] { didSet { defaults.set(toolColors, forKey: "appearance.toolColors") } }
    var toolsFollowAccent: Bool { didSet { defaults.set(toolsFollowAccent, forKey: "appearance.toolsFollowAccent") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        toolColors = (defaults.dictionary(forKey: "appearance.toolColors") as? [String: String] ?? [:]).filter { Self.valid($0.value) }
        toolsFollowAccent = defaults.bool(forKey: "appearance.toolsFollowAccent")
        let storedMode = defaults.string(forKey: "appearance.mode") ?? "System"
        mode = ["System", "Dark", "Light"].contains(storedMode) ? storedMode : "System"
        hex = Self.resolvedAccent(defaults.string(forKey: "appearance.accent"))
    }
    static func valid(_ hex: String) -> Bool { hex.count == 6 && UInt32(hex, radix: 16) != nil }
    static func resolvedAccent(_ stored: String?) -> String {
        guard let stored, stored != systemAccent else { return systemAccent }
        return valid(stored) ? stored.uppercased() : systemAccent
    }
    var followsSystemAccent: Bool { hex == Self.systemAccent }
    var color: Color { followsSystemAccent ? Color(nsColor: .controlAccentColor) : Self.color(hex) }
    var foreground: Color { AccentContrast.foreground(color) }
    static func color(_ hex: String) -> Color {
        if hex == systemAccent { return Color(nsColor: .controlAccentColor) }
        let rgb = UInt32(hex, radix: 16) ?? 0x65E0BB
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var scheme: ColorScheme? { mode == "Dark" ? .dark : mode == "Light" ? .light : nil }
    var toolPalette: ToolPalette {
        ToolPalette(overrides: toolColors.mapValues(Self.color), followsAccent: toolsFollowAccent, accent: foreground)
    }
    func setToolColor(_ color: Color, id: String) {
        guard let value = Self.hex(color) else { return }
        toolColors[id] = value
    }
    private static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    func setColor(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        hex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    func websitePreset() { mode = "Dark"; hex = Self.marketingAccent }
}
struct AppearanceHost<Content: View>: View {
    @Bindable var preferences: AppearancePreferences
    var clock: PresentationClock? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environment(\.presentationClock, clock ?? PresentationClockKey.defaultValue).environment(\.toolPalette, preferences.toolPalette).environment(\.appAccent, preferences.foreground).tint(preferences.foreground).accentColor(preferences.foreground).preferredColorScheme(preferences.scheme)
    }
}
struct AppearanceControls: View {
    @Bindable var preferences: AppearancePreferences
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.section) {
            Picker("Appearance", selection: $preferences.mode) {
                ForEach(["System", "Dark", "Light"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            HStack(spacing: 12) {
                Picker("Accent preset", selection: $preferences.hex) {
                    ForEach(AppearancePreferences.accentChoices, id: \.1) { name, hex in
                        Text(name).tag(hex)
                    }
                    if !AppearancePreferences.accentChoices.contains(where: { $0.1 == preferences.hex }) {
                        Text("Custom").tag(preferences.hex)
                    }
                }.pickerStyle(.menu)
                Spacer()
                ColorPicker("Custom accent", selection: Binding(get: { preferences.color }, set: { preferences.setColor($0) }), supportsOpacity: false)
            }
            HStack {
                Circle().fill(preferences.color).frame(width: 14, height: 14)
                if preferences.followsSystemAccent {
                    Text("macOS accent")
                } else {
                    Text("Accent #" + preferences.hex).monospaced()
                }
                Spacer()
                Button("Match website preview") { preferences.websitePreset() }.buttonStyle(.borderedProminent)
            }
            Text("macOS follows the accent in System Settings. One accent is shared by all tools, charts, and controls. Tool names and chart symbols identify each tool.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Warnings keep their warning color.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct AppearanceSettingsView: View {
    @Bindable var preferences: AppearancePreferences
    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                PageHeader("Appearance", subtitle: "Choose your appearance and colors. Changes apply everywhere and save automatically.")
                AppearanceControls(preferences: preferences)
            }
        }
    }
}

/// Shared by settings tabs and the standalone menu-bar settings window.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(showsIndicators: false) {
            content()
                .frame(maxWidth: 604, alignment: .leading)
                .padding(PageStyle.gutter)
                .background(ScrollIndicatorSuppression())
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Hides indicators only on the containing scroll view; never traverses the window.
struct ScrollIndicatorSuppression: NSViewRepresentable {
    func makeNSView(context: Context) -> Suppressor { Suppressor() }
    func updateNSView(_ view: Suppressor, context: Context) { view.schedule() }
    final class Suppressor: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); schedule() }
        override func layout() { super.layout(); suppress() }
        func schedule() { DispatchQueue.main.async { [weak self] in self?.suppress() } }
        private func suppress() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        }
    }
}

struct MethodButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: "info.circle").foregroundStyle(AccentContrast.label) }
            .buttonStyle(.link)
            .tint(AccentContrast.label)
            .help(title)
    }
}

/// Return activates Done; Escape dismisses without changing page preferences.
struct SheetDoneButton: View {
    var action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button("Done", action: action).keyboardShortcut(.defaultAction)
        }.onExitCommand(perform: action)
    }
}

/// Secondary content opens in a bounded sheet, leaving the page easy to scan.
struct DetailSheet<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @State private var presented = false
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        Button(title) { presented = true }.buttonStyle(.bordered)
            .sheet(isPresented: $presented) {
                VStack(alignment: .leading, spacing: PageStyle.related) {
                    Text(title).font(PageStyle.sectionTitle)
                    ScrollView {
                        VStack(alignment: .leading, spacing: PageStyle.related) { content() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SheetDoneButton { presented = false }
                }.padding(PageStyle.gutter).frame(width: 700, height: 520)
                    .onExitCommand { presented = false }
            }
    }
}

enum NoticeSeverity: String {
    case error = "Error", warning = "Warning"
    var symbol: String { self == .error ? "exclamationmark.circle" : "exclamationmark.triangle" }
    var color: Color { self == .error ? .red : .orange }
}

/// Resolve AppKit dynamic colors in the same appearance as the hosted SwiftUI tree.
/// Every bitmap renderer uses this boundary, including AppKit menu attachments.
enum AppearanceRendering {
    @MainActor static func capture(_ view: NSView, to bitmap: NSBitmapImageRep) {
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
    }
}

/// One accent, with native neutral ink when it cannot carry small text or symbols.
/// Dynamic resolution also covers AppKit status attachments and System appearance.
enum AccentContrast {
    static func ratio(_ foreground: NSColor, on background: NSColor) -> Double {
        guard let fg = foreground.usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else { return 1 }
        func luminance(_ color: NSColor, over: NSColor) -> Double {
            let a = color.alphaComponent
            let channels = zip([color.redComponent, color.greenComponent, color.blueComponent],
                               [over.redComponent, over.greenComponent, over.blueComponent])
            let linear = channels.map { component, base -> Double in
                let value = Double(component * a + base * (1 - a))
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let a = luminance(fg, over: bg), b = luminance(bg, over: bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    static func foreground(_ accent: Color) -> Color {
        let source = NSColor(accent)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var result = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                // These are the native canvases used by pages, sheets and controls.
                let backgrounds: [NSColor] = [.windowBackgroundColor, .controlBackgroundColor, .textBackgroundColor]
                // Reserve contrast for display conversion and small antialiased glyphs.
                // The rendered regression floor remains 4.5:1.
                if backgrounds.allSatisfy({ ratio(source, on: $0) >= 7 }) { result = source }
                else { result = .labelColor }
                result = result.usingColorSpace(.sRGB) ?? result
            }
            return result
        })
    }
    /// Adaptive label ink that does not follow the application accent, even when that hue is 7:1.
    static var label: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var result = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                result = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
            }
            return result
        })
    }
}

/// Nil preserves the system clock; isolated previews inject an evaluation instant.
private struct EvaluationDateKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var evaluationDate: Date? {
        get { self[EvaluationDateKey.self] }
        set { self[EvaluationDateKey.self] = newValue }
    }
}
struct RelativeAgeText: View {
    var date: Date
    @Environment(\.evaluationDate) private var evaluationDate
    var body: some View {
        if let evaluationDate {
            Text(Self.label(from: date, to: evaluationDate))
        } else { Text(date, style: .relative) }
    }
    static func label(from date: Date, to now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: max(0, now.timeIntervalSince(date))) ?? "0 seconds"
    }
    /// Absolute clock after the relative age. Cost, Insights, and prompt results share this suffix.
    static func captionSuffix(_ date: Date) -> String {
        "ago · " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
/// Shared relative-age caption; successful local reads also show the absolute clock.
struct ReadAgeCaption: View {
    var date: Date
    var prefix: String
    var includesClock = true
    var body: some View {
        HStack(spacing: 4) {
            Text(prefix)
            RelativeAgeText(date: date)
            Text(includesClock ? RelativeAgeText.captionSuffix(date) : "ago")
        }
    }
}
