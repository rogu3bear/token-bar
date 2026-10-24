import Observation
import SwiftUI
import ServiceManagement

enum MenuBarPart: String, Codable, CaseIterable, Identifiable {
    case icon, activity, rate, quota, zero, dial, risk, fable, fablePace, timeLeft
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
        case .timeLeft: return "Estimated time left"
        case .fable: return "Fable quota (tightest Claude limit)"
        case .fablePace: return "Fable time left at recent pace"
        }
    }
}
struct MenuBarConfiguration: Codable, Equatable {
    var order: [MenuBarPart] = [.icon, .activity, .dial, .rate, .quota, .fable, .fablePace, .zero, .risk, .timeLeft]
    var enabled: Set<MenuBarPart> = [.dial, .rate]
    var compact = false
    var unit = "dashboard"
    var separator = "  "
    var tool: MenuBarTool? = .auto
    // Optional stored fields keep older v1 preferences decodable without resetting them.
    var names: Bool? = true
    var roll: Bool? = false
    var showsNames: Bool { get { names ?? true } set { names = newValue } }
    var rollsTools: Bool { get { roll ?? false } set { roll = newValue } }
    static let instrumentParts: Set<MenuBarPart> = [.icon, .activity, .dial, .rate, .timeLeft]
    func title(values: [MenuBarPart: String]) -> String {
        let parts = order.filter { enabled.contains($0) }.compactMap { values[$0] }.filter { !$0.isEmpty }
        return parts.isEmpty ? "◈" : parts.joined(separator: separator)
    }
    mutating func normalize() {
        if tool == nil { tool = .auto }
        if names == nil { names = true }
        if roll == nil { roll = false }
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
        if MenuBarConfiguration.instrumentParts.contains(part) {
            let visible = configuration.order.filter { MenuBarConfiguration.instrumentParts.contains($0) }
            guard let index = visible.firstIndex(of: part), visible.indices.contains(index + offset),
                  let source = configuration.order.firstIndex(of: part),
                  let target = configuration.order.firstIndex(of: visible[index + offset]) else { return }
            configuration.order.swapAt(source, target)
            return
        }
        guard let index = configuration.order.firstIndex(of: part), configuration.order.indices.contains(index + offset) else { return }
        configuration.order.swapAt(index, index + offset)
    }
    func reset() { configuration = MenuBarConfiguration() }
}
/// A display of Runway's existing allowance-burn forecast, never output-token speed.
/// Unknown time is distinct from observed exhaustion and from the quota reset.
struct MenuBarTimeLeft {
    let text: String
    let spoken: String
    init(allowance: AccountAllowancePresentation) {
        guard let estimate = allowance.estimate else {
            text = "Time left —"
            spoken = "Estimated time left unavailable. " + allowance.qualifier
            return
        }
        let age = allowance.reading.map { Runway.ageLabel($0, now: allowance.now) } ?? ""
        if estimate.remaining == 0 {
            text = "Exhausted"
            spoken = "Allowance exhausted" + age
        } else if let exhaustion = estimate.exhaustion {
            let seconds = exhaustion.timeIntervalSince(allowance.now)
            // An old projection passing zero is not a new provider observation.
            guard seconds.isFinite, seconds > 0, seconds < Double(Int.max / 60) else {
                text = "Time left —"
                spoken = "Estimated exhaustion time passed; waiting for a fresh allowance reading" + age
                return
            }
            let minutes = Int(ceil(seconds / 300)) * 5
            let hours = minutes / 60
            let duration = hours > 0 ? "\(hours)h " + String(format: "%02dm", minutes % 60) : "\(minutes)m"
            text = "≈" + duration + " left"
            spoken = "Estimated time until allowance exhaustion, approximately \(hours) hours \(minutes % 60) minutes at recent allowance burn" + age
        } else if estimate.percentPerHour == 0 {
            text = "No burn observed"
            spoken = "Estimated time left unavailable; no allowance burn observed" + age
        } else if estimate.percentPerHour != nil {
            text = "Resets first"
            spoken = "Quota resets before projected exhaustion at recent allowance burn" + age
        } else {
            text = allowance.reading?.reset == nil ? "Time left —" : "Learning burn"
            spoken = "Estimated time left unavailable. " + estimate.message + age
        }
    }
}

struct MenuBarPresentation {
    static let rollInterval: TimeInterval = 5
    static func warnedTools(_ coordinator: QuotaGuardCoordinator?, notices: NoticeDismissals) -> Set<LiveTool> {
        Set((coordinator?.displayDecisions ?? []).filter {
            $0.risk != .none && !notices.containsAllowance($0.id, reset: $0.reading?.reset, level: $0.level)
        }.map(\.tool))
    }

    /// One instrument per confirmed active provider; all consumers use the same evaluation clock.
    static func face(_ settings: MenuBarConfiguration, codex: Tachometer, claude: Tachometer, grok: Tachometer,
                     monitor: LiveMonitor, now: Date, palette: ToolPalette, claudeQuota: ToolQuotaState,
                     grokQuota: ToolQuotaState = ToolQuotaState(), warningTools: Set<LiveTool> = []) -> NSAttributedString {
        let meters: [LiveTool: Tachometer] = [.codex: codex, .claude: claude, .grok: grok]
        var instruments: [(LiveTool, Tachometer)] = LiveTool.allCases.compactMap { tool in
            guard settings.tool == nil || settings.tool == .auto || settings.tool?.rawValue == tool.rawValue,
                  let meter = meters[tool] else { return nil }
            let activity = LiveTool.confirmed(meter.activity, now: now)
            guard !activity.turns.isEmpty else { return nil }
            // A disposable projection never changes the process meter or saved unit preferences.
            let reading = Tachometer()
            reading.activity = activity
            reading.tick(now: now)
            reading.unit = meter.unit
            reading.minimum = meter.minimum
            reading.scale = meter.scale
            return (tool, reading)
        }
        if settings.rollsTools, instruments.count > 1, now.timeIntervalSinceReferenceDate.isFinite {
            let slot = floor(now.timeIntervalSinceReferenceDate / rollInterval)
                .truncatingRemainder(dividingBy: Double(instruments.count))
            let index = (Int(slot) + instruments.count) % instruments.count
            instruments = [instruments[index]]
        }
        let result = NSMutableAttributedString()
        var spoken: [String] = []
        var fields = settings
        // Retain legacy fields for compatibility; timeLeft reuses the qualified allowance forecast.
        fields.enabled.formIntersection(MenuBarConfiguration.instrumentParts)
        for (tool, reading) in instruments {
            if result.length > 0 { result.append(NSAttributedString(string: "   ")) }
            let warning = warningTools.contains(tool)
            result.append(attributed(fields, meter: reading, monitor: monitor, now: now,
                accent: warning ? .systemOrange : NSColor(tool.color(in: palette)), tool: tool,
                claudeQuota: claudeQuota, grokQuota: grokQuota, showsName: settings.showsNames))
            let unit = RateUnit(rawValue: settings.unit) ?? reading.unit
            let timeLeft = MenuBarTimeLeft(allowance: AccountAllowancePresentation(quota: quotaState(for: tool,
                monitor: monitor, claudeQuota: claudeQuota, grokQuota: grokQuota), now: now))
            spoken.append(tool.label + ", " + CompactLiveCopy.spokenRate(activity: "Working", available: reading.hasRate,
                amount: reading.rawRate * unit.multiplier, unit: unit) + (settings.enabled.contains(.timeLeft) ? ", " + timeLeft.spoken : "")
                + (warning ? ", allowance warning" : ""))
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "◈", attributes: [.foregroundColor: NSColor(palette.accent),
                .font: NSFont.systemFont(ofSize: 13)]))
        }
        let label = spoken.isEmpty ? "Token Bar, no confirmed active tools in this selection" : spoken.joined(separator: "; ")
        result.addAttribute(MenuBarDial.speech, value: label, range: NSRange(location: 0, length: result.length))
        return result
    }
    static func quotaState(for tool: LiveTool?, monitor: LiveMonitor, claudeQuota: ToolQuotaState?, grokQuota: ToolQuotaState? = nil) -> ToolQuotaState {
        if tool == .grok { return grokQuota ?? ToolQuotaState() }
        if tool == .claude { return claudeQuota ?? ToolQuotaState() }
        let account = monitor.currentID.flatMap { monitor.state.accounts[$0] }
        return ToolQuotaState(readings: account?.quotas ?? [], samples: monitor.state.samples, guardAccountID: monitor.currentID,
            guardAuthenticated: monitor.lastQuotaRefresh != nil && (account?.quotas.allSatisfy { $0.date == monitor.lastQuotaRefresh } ?? false),
            guardFailed: monitor.error != nil)
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
            .timeLeft: MenuBarTimeLeft(allowance: allowance).text,
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
    static func attributed(_ settings: MenuBarConfiguration, meter: Tachometer, monitor: LiveMonitor, now: Date, accent: NSColor? = nil, tool: LiveTool? = nil, claudeQuota: ToolQuotaState? = nil, grokQuota: ToolQuotaState? = nil, riskText: String? = nil, quotaFace: NSAttributedString? = nil, showsName: Bool = true) -> NSAttributedString {
        let accent = accent ?? .labelColor
        let values = values(settings, meter: meter, monitor: monitor, now: now, tool: tool, claudeQuota: claudeQuota, grokQuota: grokQuota, labelQuota: false)
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor]
        if let tool, showsName {
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
                    let presentation = MenuBarPresentation.face(preferences.configuration, codex: meter, claude: claudeMeter, grok: grokMeter,
                        monitor: monitor, now: evaluationDate ?? clock.now, palette: palette, claudeQuota: claudeQuota.quota, grokQuota: grokQuota.quota, warningTools: MenuBarPresentation.warnedTools(quotaGuard, notices: appearance.notices))
                    MenuBarPreview(value: presentation)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(3).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.vertical, 8)
                        .accessibilityLabel(MenuBarDial.spokenLabel(presentation))
                }
                Picker("Show speed for", selection: Binding(get: { preferences.configuration.tool ?? .auto }, set: { preferences.configuration.tool = $0 })) {
                    ForEach(MenuBarTool.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Show estimated time left", isOn: Binding(
                    get: { preferences.configuration.enabled.contains(.timeLeft) },
                    set: { enabled in
                        if enabled { preferences.configuration.enabled.insert(.timeLeft) }
                        else { preferences.configuration.enabled.remove(.timeLeft) }
                    }))
                Text("Estimated time until an active tool’s allowance runs out at its recent average allowance burn, rounded up to 5 minutes. This is not the quota reset timer. Unknown estimates show —; no measured burn and a reset before exhaustion are labeled separately.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show tool names", isOn: $preferences.configuration.showsNames)
                Toggle("Roll active tools every 5 seconds", isOn: $preferences.configuration.rollsTools)
                    .disabled(preferences.configuration.tool != .auto)
                VStack(alignment: .leading, spacing: PageStyle.labelGap) {
                    Text("Rate units").font(.callout)
                    Picker("Rate units", selection: $preferences.configuration.unit) {
                        Text("Follow each tool").tag("dashboard")
                        Text("Tokens / second").tag("s")
                        Text("Tokens / minute").tag("m")
                        Text("Tokens / hour").tag("h")
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Text("Each active tool keeps its own dial and rate. Follow each tool uses its live module unit; explicit units apply only to the menu bar. Allowance details stay in the popover.").font(.caption).foregroundStyle(.secondary)
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
                            ForEach(preferences.configuration.order.filter { MenuBarConfiguration.instrumentParts.contains($0) }) { part in
                                HStack {
                                    Toggle(part.label, isOn: Binding(get: { preferences.configuration.enabled.contains(part) }, set: { enabled in
                                        if enabled { preferences.configuration.enabled.insert(part) }
                                        else { preferences.configuration.enabled.remove(part) }
                                    }))
                                    Spacer()
                                    if reordering {
                                        Button { preferences.move(part, by: -1) } label: { Image(systemName: "arrow.up") }
                                            .disabled(preferences.configuration.order.first { MenuBarConfiguration.instrumentParts.contains($0) } == part).accessibilityLabel("Move \(part.label) earlier")
                                        Button { preferences.move(part, by: 1) } label: { Image(systemName: "arrow.down") }
                                            .disabled(preferences.configuration.order.last { MenuBarConfiguration.instrumentParts.contains($0) } == part).accessibilityLabel("Move \(part.label) later")
                                    }
                                }
                            }
                        }
                        if preferences.configuration.enabled.contains(.activity) {
                            Toggle("Compact activity labels", isOn: $preferences.configuration.compact)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Separator", selection: $preferences.configuration.separator) {
                                Text("Dot ·").tag(" · ")
                                Text("Line |").tag(" | ")
                                Text("Space").tag("  ")
                            }.pickerStyle(.segmented)
                        }
                        Text("Each dial follows its tool’s automatic range. Auto shows all confirmed active tools together, or one at a time with Roll enabled. Hiding names keeps separate instruments. c = chats, a = agents. Unconfirmed activity and remaining allowance stay in the popover. With every field off, each active tool keeps an icon; when nothing is confirmed active, one quiet mark remains.")
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
