import SwiftUI

enum LiveTool: String, Codable, CaseIterable, Identifiable {
    case codex, claude, grok
    static let liveCoverage = "Codex quota uses the installed app-server. Claude quota uses a fresh account-matched local cache. Grok remaining uses the installed Grok agent’s billing reading. Grok activity follows locally open sessions and recent summary updates; its speed uses successive usage.json output counts."
    static let compactCoverage = "Popover: name, rate, remaining. Click a row for reset and projected zero. Today’s token bar uses recorded usage only."
    static func active(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil) -> [LiveTool] {
        var tools: [LiveTool] = []
        if codex.hasRate || codex.runningCount > 0 { tools.append(.codex) }
        if claude.hasRate || claude.runningCount > 0 { tools.append(.claude) }
        if let grok, grok.hasRate || grok.runningCount > 0 { tools.append(.grok) }
        return tools
    }
    /// The status item keeps a neutral Codex starting state when idle; live panels do not.
    static func visible(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil) -> [LiveTool] {
        let tools = active(codex: codex, claude: claude, grok: grok)
        return tools.isEmpty ? [.codex] : tools
    }
    func color(in palette: ToolPalette) -> Color { palette.color(rawValue, fallback: color) }
    var id: String { rawValue }
    var label: String { self == .codex ? "Codex" : self == .claude ? "Claude" : "Grok" }
    var color: Color { ToolPalette.defaultColor(rawValue) }
}
enum MenuBarTool: String, Codable, CaseIterable, Identifiable {
    case auto, codex, claude, grok
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    func resolve(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil) -> LiveTool {
        if self == .grok { return .grok }
        if self == .codex { return .codex }
        if self == .claude { return .claude }
        if let grok, grok.hasRate,
           (!codex.hasRate || (grok.lastReport ?? .distantPast) > (codex.lastReport ?? .distantPast)),
           (!claude.hasRate || (grok.lastReport ?? .distantPast) > (claude.lastReport ?? .distantPast)) { return .grok }
        if !codex.hasRate && !claude.hasRate, let grok, grok.runningCount > 0 { return .grok }
        if codex.hasRate != claude.hasRate { return claude.hasRate ? .claude : .codex }
        if codex.hasRate { return (claude.lastReport ?? .distantPast) > (codex.lastReport ?? .distantPast) ? .claude : .codex }
        if codex.runningCount == 0 && claude.runningCount > 0 { return .claude }
        if let grok, grok.runningCount > 0, codex.runningCount == 0 && claude.runningCount == 0 { return .grok }
        return .codex
    }
}
extension ActivitySnapshot {
    func filtered(for tool: LiveTool) -> ActivitySnapshot {
        let selected = turns.filter { $0.value.tool == tool }
        let sessions = Set(selected.values.map(\.session))
        return ActivitySnapshot(turns: selected, measurements: measurements.filter { sessions.contains($0.key) }, readAt: readAt, error: toolErrors[tool] ?? error, referenceDate: referenceDate)
    }
}


enum CompactLiveCopy {
    static func rate(_ available: Bool, amount: Double, unit: RateUnit) -> String {
        guard available else { return "—" }
        let number = unit != .second && amount >= 1000 ? RateDisplay.compact(amount) : String(format: "%.0f", amount)
        return "~" + number + " tok/" + unit.rawValue
    }
    static func remaining(_ estimate: Runway?) -> String {
        estimate.map { String(format: "%.0f%%", $0.remaining) } ?? "—"
    }
    static func detail(reading: QuotaReading?, estimate: Runway?, now: Date) -> String {
        if let estimate {
            var parts: [String] = []
            if estimate.remaining == 0 { parts.append("Exhausted") }
            if let zero = estimate.exhaustion { parts.append(Runway.clockLabel(zero, now: now)) }
            if let reading { parts.append(reading.reset.formatted(date: .abbreviated, time: .omitted)) }
            return parts.isEmpty ? CompactLiveCopy.remaining(estimate) : parts.joined(separator: " · ")
        }
        return "Unavailable"
    }
}

extension HistoryTool {
    func color(in palette: ToolPalette) -> Color {
        switch self {
        case .codex: return LiveTool.codex.color(in: palette)
        case .claude: return LiveTool.claude.color(in: palette)
        case .grok: return LiveTool.grok.color(in: palette)
        case .other: return .secondary
        case .unknown: return .secondary
        }
    }
}
