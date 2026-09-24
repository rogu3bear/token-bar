import Observation
import SwiftUI
import ServiceManagement

enum MenuBarPart: String, Codable, CaseIterable, Identifiable {
    case icon, activity, rate, quota, zero, dial, risk, fable, fablePace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .risk: return "Quota Guard warning"
        case .icon: return "App icon"
        case .activity: return "Running chats and agents"
        case .rate: return "Output rate"
        case .quota: return "Quota remaining (%)"
        case .dial: return "Speed dial"
        case .zero: return "Projected zero"
        case .fable: return "Fable quota (tightest Claude limit)"
        case .fablePace: return "Fable time left at recent pace"
        }
    }
}
struct MenuBarConfiguration: Codable, Equatable {
    var order: [MenuBarPart] = [.icon, .activity, .dial, .rate, .quota, .fable, .fablePace, .zero, .risk]
    var enabled: Set<MenuBarPart> = [.dial, .rate, .quota]
    var compact = false
    var unit = "dashboard"
    var separator = "  "
    var tool: MenuBarTool? = .auto
    func title(values: [MenuBarPart: String]) -> String {
        let parts = order.filter { enabled.contains($0) }.compactMap { values[$0] }.filter { !$0.isEmpty }
        return parts.isEmpty ? "◈" : parts.joined(separator: separator)
    }
    mutating func normalize() {
        if tool == nil { tool = .auto }
        var seen = Set<MenuBarPart>()
        order = (order + MenuBarPart.allCases).filter { seen.insert($0).inserted }
        if !["dashboard", "s", "m", "h"].contains(unit) { unit = "dashboard" }
        if ![" · ", " | ", "  "].contains(separator) { separator = " · " }
    }
}
@Observable final class MenuBarPreferences {
    var configuration: MenuBarConfiguration { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "menuBarConfiguration.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MenuBarConfiguration.self, from: $0) } ?? MenuBarConfiguration()
        loaded.normalize(); configuration = loaded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: key) }
    }
    func move(_ part: MenuBarPart, by offset: Int) {
        guard let index = configuration.order.firstIndex(of: part), configuration.order.indices.contains(index + offset) else { return }
        configuration.order.swapAt(index, index + offset)
    }
    func reset() { configuration = MenuBarConfiguration() }
}
struct MenuBarPresentation {
    /// One presentation owner for the real status item and settings preview.
    static func combined(_ settings: MenuBarConfiguration, codex: Tachometer, claude: Tachometer, grok: Tachometer,
                         monitor: LiveMonitor, now: Date, palette: ToolPalette, claudeQuota: ToolQuotaState, grokQuota: ToolQuotaState = ToolQuotaState(), riskText: String? = nil) -> NSAttributedString {
        let auto = (settings.tool ?? .auto) == .auto
        let selected = (settings.tool ?? .auto).resolve(codex: codex, claude: claude, grok: grok)
        func meter(_ tool: LiveTool) -> Tachometer { tool == .grok ? grok : tool == .claude ? claude : codex }
        let working = LiveTool.active(codex: codex, claude: claude, grok: grok)
        let tools = auto ? working : [selected]
        func remainingValue(_ tool: LiveTool) -> Double? {
            AccountAllowancePresentation(
                quota: quotaState(for: tool, monitor: monitor, claudeQuota: claudeQuota, grokQuota: grokQuota),
                now: now
            ).estimate?.remaining
        }
        // Auto's remaining line names every tool used in the last hour that has a measured remaining.
        let recent = auto && settings.enabled.contains(.quota)
            ? LiveTool.recent(codex: codex, claude: claude, grok: grok, now: now).compactMap { tool in remainingValue(tool).map { (tool, $0) } }
            : []
        let recentFace = recent.isEmpty ? nil : remainingLine(recent, palette: palette)
        if auto && working.isEmpty {
            var quiet = settings
            quiet.enabled.subtract([.rate, .dial, .activity, .zero, .fable, .fablePace])
            guard let recentFace else {
                // Nothing used within the hour: the clean idle face, no stale remaining.
                quiet.enabled.remove(.quota)
                return attributed(quiet, meter: Tachometer(), monitor: monitor, now: now, accent: NSColor(palette.accent),
                                  claudeQuota: claudeQuota, grokQuota: grokQuota, riskText: riskText)
            }
            return attributed(quiet, meter: Tachometer(), monitor: monitor, now: now, accent: NSColor(palette.accent),
                              claudeQuota: claudeQuota, grokQuota: grokQuota, riskText: riskText, quotaFace: recentFace)
        }
        if tools.count <= 1 {
            let tool = tools.first ?? selected
            var speed = settings
            let grokAuto = auto && tool == .grok
            let grokHasQuota = hasQuotaReading(.grok, monitor: monitor, now: now, claudeQuota: claudeQuota, grokQuota: grokQuota)
            if grokAuto && !grokHasQuota {
                speed.enabled.remove(.zero)
                if recentFace == nil { speed.enabled.remove(.quota) }
            }
            // The title already names a lone tool; others used within the hour join by name.
            let others = recent.contains { $0.0 != tool }
            return attributed(speed, meter: meter(tool), monitor: monitor, now: now,
                              accent: NSColor(tool.color(in: palette)), tool: tool, claudeQuota: claudeQuota, grokQuota: grokQuota,
                              riskText: riskText, quotaFace: others ? recentFace : nil)
        }
        let total = Tachometer()
        total.unit = meter(selected).unit
        total.rawRate = tools.reduce(0) { $0 + (meter($1).hasRate ? meter($1).rawRate : 0) }
        total.rate = total.rawRate
        total.hasRate = tools.contains { meter($0).hasRate }
        total.scale = RateBounds.fitting([total.rawRate]).upper
        for tool in tools {
            total.activity.turns.merge(meter(tool).activity.turns) { first, _ in first }
        }
        total.activity.readAt = now
        var summary = settings
        summary.enabled.remove(.quota)
        summary.enabled.remove(.zero) // A cross-provider exhaustion time has no meaning.
        let partial = tools.contains { !meter($0).hasRate }
        let result = NSMutableAttributedString(string: partial ? "Total (partial) · " : "Total · ", attributes: [.foregroundColor: NSColor.labelColor])
        result.append(attributed(summary, meter: total, monitor: monitor, now: now, accent: NSColor(palette.accent), claudeQuota: claudeQuota, riskText: riskText))
        guard settings.enabled.contains(.quota) else { return result }
        if let recentFace {
            result.append(NSAttributedString(string: settings.separator, attributes: [.foregroundColor: NSColor.labelColor]))
            result.append(recentFace)
        }
        // Unavailable is not zero: a working tool without a measured remaining still says so.
        for tool in tools where remainingValue(tool) == nil && tool != .grok {
            result.append(NSAttributedString(string: settings.separator + tool.label + " quota unavailable",
                attributes: [.foregroundColor: NSColor(tool.color(in: palette)), .font: NSFont.systemFont(ofSize: 12)]))
        }
        return result
    }
    /// `Claude 45% Grok 80% Codex 12% remaining`: tool-colored names and figures, the word once.
    static func remainingLine(_ entries: [(LiveTool, Double)], palette: ToolPalette) -> NSAttributedString {
        let figure = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let result = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            let color = NSColor(entry.0.color(in: palette))
            if index > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: figure])) }
            result.append(NSAttributedString(string: entry.0.label + " ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]))
            result.append(NSAttributedString(string: CompactLiveCopy.percent(entry.1), attributes: [.font: figure, .foregroundColor: color]))
        }
        result.append(NSAttributedString(string: " remaining", attributes: [.font: figure, .foregroundColor: NSColor.labelColor]))
        assert(result.string == CompactLiveCopy.remainingLine(entries.map { ($0.0.label, $0.1) }))
        return result
    }
    static func quotaState(for tool: LiveTool?, monitor: LiveMonitor, claudeQuota: ToolQuotaState?, grokQuota: ToolQuotaState? = nil) -> ToolQuotaState {
        if tool == .grok { return grokQuota ?? ToolQuotaState() }
        if tool == .claude { return claudeQuota ?? ToolQuotaState() }
        let account = monitor.currentID.flatMap { monitor.state.accounts[$0] }
        return ToolQuotaState(readings: account?.quotas ?? [], samples: monitor.state.samples, guardAccountID: monitor.currentID)
    }
    static func hasQuotaReading(_ tool: LiveTool, monitor: LiveMonitor, now: Date, claudeQuota: ToolQuotaState?, grokQuota: ToolQuotaState? = nil) -> Bool {
        let state = quotaState(for: tool, monitor: monitor, claudeQuota: claudeQuota, grokQuota: grokQuota)
        return AccountAllowancePresentation(quota: state, now: now).estimate != nil
    }
    static func values(_ settings: MenuBarConfiguration, meter: Tachometer, monitor: LiveMonitor, now: Date, tool: LiveTool? = nil, claudeQuota: ToolQuotaState? = nil, grokQuota: ToolQuotaState? = nil, labelQuota: Bool = true) -> [MenuBarPart: String] {
        let unit = RateUnit(rawValue: settings.unit) ?? meter.unit
        let amount = meter.rawRate * unit.multiplier
        let rate = CompactLiveCopy.rate(meter.hasRate, amount: amount, unit: unit)
        let activity = meter.activity
        let counts = "\(activity.chatCount)c \(activity.agentCount)a"
            + (activity.unknownCount > 0 ? " \(activity.unknownCount)?" : "")
            + (activity.uncertain > 0 ? " \(activity.uncertain) unconfirmed" : "")
        let state = quotaState(for: tool, monitor: monitor, claudeQuota: claudeQuota, grokQuota: grokQuota)
        let allowance = AccountAllowancePresentation(quota: state, now: now)
        let estimate = allowance.estimate
        let remaining = allowance.remaining
        let zero = estimate?.exhaustion.map { Runway.clockLabel($0, now: now) } ?? "—"
        // A single-tool title already establishes identity for all its fields.
        // Standalone quotas in Auto's mixed-tool readout still need their name.
        let quotaName = labelQuota ? tool?.label : nil
        // Fable names itself and follows Claude's account whichever tool is selected.
        let fable = claudeQuota.flatMap { ClaudeQuotaSource.fableBudget($0, now: now) }
        let pace = claudeQuota.flatMap { ClaudeQuotaSource.fablePace($0, now: now) }
        let paceName = settings.enabled.contains(.fable) ? "" : "Fable "
        return [
            .icon: "◈", .activity: settings.compact && activity.readAt != nil ? counts : meter.status,
            .rate: rate,
            .quota: estimate == nil ? (quotaName.map { $0 + " quota unavailable" } ?? "Quota unavailable") : (quotaName.map { $0 + " " } ?? "") + remaining + " remaining",
            .zero: "Zero " + zero, .dial: "Speed dial " + rate,
            .fable: {
                guard let fable, fable.remaining > 0 else { return "" }
                return "Fable " + CompactLiveCopy.percent(fable.remaining) + " · " + fable.binding
            }(),
            .fablePace: {
                guard let pace else { return "" }
                switch pace {
                case .exhausted: return ""
                case .idle, .learning, .resetsFirst, .left: return paceName + pace.menuText
                }
            }()
        ]
    }
    static func title(_ settings: MenuBarConfiguration, meter: Tachometer, monitor: LiveMonitor, now: Date, tool: LiveTool? = nil, claudeQuota: ToolQuotaState? = nil, grokQuota: ToolQuotaState? = nil) -> String {
        (tool.map { $0.label + " · " } ?? "") + settings.title(values: values(settings, meter: meter, monitor: monitor, now: now, tool: tool, claudeQuota: claudeQuota, grokQuota: grokQuota, labelQuota: false))
    }
    static func attributed(_ settings: MenuBarConfiguration, meter: Tachometer, monitor: LiveMonitor, now: Date, accent: NSColor? = nil, tool: LiveTool? = nil, claudeQuota: ToolQuotaState? = nil, grokQuota: ToolQuotaState? = nil, riskText: String? = nil, quotaFace: NSAttributedString? = nil) -> NSAttributedString {
        let accent = accent ?? .labelColor
        let values = values(settings, meter: meter, monitor: monitor, now: now, tool: tool, claudeQuota: claudeQuota, grokQuota: grokQuota, labelQuota: false)
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor]
        if let tool {
            result.append(NSAttributedString(string: tool.label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: accent]))
        }
        for part in settings.order where settings.enabled.contains(part) {
            if part == .risk && riskText == nil { continue }
            if (part == .fablePace || part == .fable) && (values[part] ?? "").isEmpty { continue }
            if result.length > 0 { result.append(NSAttributedString(string: settings.separator, attributes: attributes)) }
            if part == .quota, let quotaFace {
                result.append(quotaFace)
            } else if part == .risk {
                result.append(NSAttributedString(string: riskText ?? "", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange]))
            } else if part == .fablePace {
                // Smaller and secondary: a projection beside the measured figure.
                result.append(NSAttributedString(string: values[part] ?? "", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
            } else if part == .dial {
                result.append(MenuBarDial.attributed(value: meter.rate, minimum: meter.minimum, maximum: meter.scale,
                    available: meter.hasRate, accent: accent, identity: tool?.rawValue ?? "combined"))
            } else {
                var partAttributes = attributes
                if part == .icon || part == .quota || part == .fable { partAttributes[.foregroundColor] = accent }
                result.append(NSAttributedString(string: values[part] ?? "—", attributes: partAttributes))
            }
        }
        if result.length == 0 || !settings.order.contains(where: { settings.enabled.contains($0) }) {
            if result.length > 0 { result.append(NSAttributedString(string: settings.separator, attributes: attributes)) }
            var iconAttributes = attributes
            iconAttributes[.foregroundColor] = accent
            result.append(NSAttributedString(string: "◈", attributes: iconAttributes))
        }
        return result
    }

}
struct MenuBarSettingsView: View {
    @Environment(\.presentationClock) private var clock
    var allowsSystemSettings = false
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    @Environment(\.toolPalette) private var palette
    @Bindable var preferences: MenuBarPreferences
    @Bindable var appearance: AppearancePreferences
    @Bindable var meter: Tachometer
    @Bindable var claudeMeter: Tachometer
    @Bindable var grokMeter: Tachometer
    @Bindable var monitor: LiveMonitor
    @Bindable var claudeQuota: ClaudeQuotaMonitor
    @Bindable var grokQuota: GrokQuotaMonitor
    var claudeConnection: ClaudeConnectionModel? = nil
    var quotaGuard: QuotaGuardCoordinator? = nil
    var updateCheck: UpdateCheck? = nil
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var reordering = false
    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                PageHeader("Settings", subtitle: "Changes apply and save automatically.")
                VStack(alignment: .leading, spacing: PageStyle.related) {
                Text("Menu bar").font(PageStyle.sectionTitle)
                Group {
                    let presentation = MenuBarPresentation.combined(preferences.configuration, codex: meter, claude: claudeMeter, grok: grokMeter,
                        monitor: monitor, now: evaluationDate ?? clock.now, palette: palette, claudeQuota: claudeQuota.quota, grokQuota: grokQuota.quota, riskText: quotaGuard?.menuText(selection: preferences.configuration.tool))
                    MenuBarPreview(value: presentation)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(3).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.vertical, 8)
                        .accessibilityLabel(presentation.string.replacingOccurrences(of: "\u{FFFC}", with: "Speed dial"))
                }
                Picker("Show speed for", selection: Binding(get: { preferences.configuration.tool ?? .auto }, set: { preferences.configuration.tool = $0 })) {
                    ForEach(MenuBarTool.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: PageStyle.labelGap) {
                    Text("Rate units").font(.callout)
                    Picker("Rate units", selection: $preferences.configuration.unit) {
                        Text("Follow selected tool").tag("dashboard")
                        Text("Tokens / second").tag("s")
                        Text("Tokens / minute").tag("m")
                        Text("Tokens / hour").tag("h")
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Text("Follow selected tool uses its live module unit. Explicit units apply only to the menu bar.").font(.caption).foregroundStyle(.secondary)
                }.moduleSurface()
                VStack(alignment: .leading, spacing: PageStyle.related) {
                Label("Appearance", systemImage: "paintpalette")
                    .font(PageStyle.sectionTitle)
                    .labelStyle(.titleAndIcon)
                AppearanceControls(preferences: appearance)
                }.moduleSurface()
                DetailSheet("Customize") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Reorder fields", isOn: $reordering)
                        VStack(spacing: 12) {
                            ForEach(preferences.configuration.order) { part in
                                HStack {
                                    Toggle(part.label, isOn: Binding(get: { preferences.configuration.enabled.contains(part) }, set: { enabled in
                                        if enabled { preferences.configuration.enabled.insert(part) }
                                        else { preferences.configuration.enabled.remove(part) }
                                    }))
                                    Spacer()
                                    if reordering {
                                        Button { preferences.move(part, by: -1) } label: { Image(systemName: "arrow.up") }
                                            .disabled(preferences.configuration.order.first == part).accessibilityLabel("Move \(part.label) earlier")
                                        Button { preferences.move(part, by: 1) } label: { Image(systemName: "arrow.down") }
                                            .disabled(preferences.configuration.order.last == part).accessibilityLabel("Move \(part.label) later")
                                    }
                                }
                            }
                        }
                        Toggle("Compact labels", isOn: $preferences.configuration.compact)
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Separator", selection: $preferences.configuration.separator) {
                                Text("Dot ·").tag(" · ")
                                Text("Line |").tag(" | ")
                                Text("Space").tag("  ")
                            }.pickerStyle(.segmented)
                        }
                        Text("The dial follows the dashboard’s automatic range. Quota remaining is the prioritized subscription quota, not a token balance. Fable quota is the lowest remaining of Claude’s 5-hour, weekly and Fable weekly limits, named by the limit that binds, and is omitted when remaining is a measured zero or when any of them is missing or stale. Fable time left projects when the first of those limits runs out at the average burn of recent hours, weighted toward recent use; it needs 30 minutes of readings. c = chats, a = agents. Unconfirmed activity stays labeled. With every field off, the app icon remains available. A shorter selection leaves more room for other menu-bar apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }
                Divider()
                if let quotaGuard {
                    DetailSheet("Allowance warnings") { QuotaGuardSettingsView(coordinator: quotaGuard) }
                }
                if let claudeConnection {
                    DetailSheet("Connections") { ClaudeConnectionControl(model: claudeConnection) }
                }
                VStack(alignment: .leading, spacing: PageStyle.related) {
                Text("General").font(PageStyle.sectionTitle)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(!allowsSystemSettings)
                    .onAppear { if allowsSystemSettings { launchAtLogin = SMAppService.mainApp.status == .enabled } }
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard allowsSystemSettings, enabled != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = error.localizedDescription }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                if let loginError { ErrorNotice(message: loginError) }
                if let updateCheck { UpdateCheckControl(check: updateCheck, allowsNetwork: allowsSystemSettings) }
                DetailSheet("Local data and permissions") { LocalAccessExplanation().padding(.top, 8) }
                Button("Restore menu bar defaults") { preferences.reset() }
                Button("Show dismissed warnings") { appearance.notices.restore() }
                    .disabled(!appearance.notices.hasDismissed)
                }.moduleSurface()
            }
        }
    }
}
