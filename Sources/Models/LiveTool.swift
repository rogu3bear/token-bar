import SwiftUI

enum LiveTool: String, Codable, CaseIterable, Identifiable {
    case codex, claude, grok
    static let liveCoverage = "Codex quota uses the installed app-server. Claude quota uses an account-matched local cache that the installed Claude Code refreshes every 15 minutes. Grok remaining uses the installed Grok agent’s billing reading. Grok activity follows locally open sessions and recent summary updates; its speed uses successive usage.json output counts."
    static let compactCoverage = "Popover: name, rate, remaining. Click a row for reset and projected zero. Today’s token bar uses recorded usage only."
    static func active(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil) -> [LiveTool] {
        var tools: [LiveTool] = []
        if codex.hasRate || codex.runningCount > 0 { tools.append(.codex) }
        if claude.hasRate || claude.runningCount > 0 { tools.append(.claude) }
        if let grok, grok.hasRate || grok.runningCount > 0 { tools.append(.grok) }
        return tools
    }
    /// Occupancy alias of `active`. Idle no longer invents a Codex placeholder.
    static func visible(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil) -> [LiveTool] {
        active(codex: codex, claude: claude, grok: grok)
    }
    /// Popover rows: working tools, plus unused Claude whose remaining is a measured zero.
    static func compact(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil, remaining: (LiveTool) -> Double?) -> [LiveTool] {
        let working = Set(active(codex: codex, claude: claude, grok: grok))
        return allCases.filter { working.contains($0) || ($0 == .claude && remaining($0) == 0) }
    }
    /// Now columns: working tools while any are working; measured remainings only when idle.
    /// Connection or discovery without a reading does not mint a seat.
    static func nowOccupied(codex: Tachometer, claude: Tachometer, grok: Tachometer? = nil, remaining: (LiveTool) -> Double?) -> [LiveTool] {
        let working = active(codex: codex, claude: claude, grok: grok)
        if !working.isEmpty { return working }
        return allCases.filter { remaining($0) != nil }
    }
    func color(in palette: ToolPalette) -> Color { palette.color(rawValue, fallback: color) }
    var id: String { rawValue }
    var label: String { self == .codex ? "Codex" : self == .claude ? "Claude" : "Grok" }
    var color: Color { ToolPalette.defaultColor(rawValue) }
}

/// Process-owned relevance, independent of the short-lived speed/activity window.
/// Remembers tool identity only, never quota values or an account's identity.
struct AccountToolRelevance {
    private(set) var known: Set<LiveTool> = []
    var tools: [LiveTool] { LiveTool.allCases.filter { known.contains($0) } }
    mutating func observe(_ tool: LiveTool, discovered: Bool = false, account: Bool = false,
                          quota: Bool = false, activity: Bool = false) {
        if discovered || account || quota || activity { known.insert(tool) }
    }
}

/// Both allowance surfaces use the same current-reading and disclosure contract.
struct AccountAllowancePresentation {
    let quota: ToolQuotaState
    let now: Date
    var matching: [QuotaReading] {
        quota.readings.filter {
            (quota.guardAccountID == nil || $0.accountID == quota.guardAccountID) &&
            !$0.accountID.isEmpty && $0.used.isFinite && (0...100).contains($0.used) && $0.date <= now
        }
    }
    var reading: QuotaReading? {
        guard !quota.guardFailed else { return nil }
        return Runway.priority(matching, samples: quota.samples, now: now, horizon: quota.horizon)
    }
    var estimate: Runway? { reading.map { Runway.estimate($0, samples: quota.samples, now: now, horizon: quota.horizon) } }
    /// Occupancy exception: remaining is a measured zero, not missing.
    var measuredZero: Bool { estimate.map { $0.remaining == 0 } ?? false }
    var remaining: String { CompactLiveCopy.remaining(estimate) }
    var qualifier: String {
        if let estimate { return estimate.remaining == 0 ? "Exhausted" : "Remaining" }
        if quota.guardFailed { return "Read failed · unconfirmed" }
        if matching.contains(where: { $0.reset.map { $0 <= now } == true }) { return "Reset passed · unconfirmed" }
        if !matching.isEmpty { return "Stale · unconfirmed" }
        return "Unavailable"
    }
    var detail: String {
        var parts = [String]()
        if let reading, let estimate {
            parts.append(estimate.remaining == 0 ? "Exhausted" : remaining + " remaining")
            if let reset = reading.reset {
                parts.append("Resets " + reset.formatted(date: .abbreviated, time: .shortened))
            } else {
                parts.append("Reset unavailable")
            }
            parts.append("Quota read " + reading.date.formatted(date: .omitted, time: .standard) + Runway.ageLabel(reading, now: now))
            if let zero = estimate.exhaustion { parts.append("Projected zero " + Runway.clockLabel(zero, now: now)) }
            parts.append(estimate.message)
        } else {
            parts.append(qualifier + " · " + quota.unavailable)
            if let last = matching.max(by: { $0.date < $1.date }) {
                parts.append("Last quota read " + last.date.formatted(date: .abbreviated, time: .shortened))
                if let reset = last.reset {
                    parts.append("Reported reset " + reset.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        if let label = quota.accountLabel { parts.append(label) }
        return parts.joined(separator: " · ")
    }
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
    static func activity(_ meter: Tachometer) -> String {
        if meter.runningCount > 0 || meter.hasRate { return "Working" }
        if meter.activity.readAt == nil || meter.activity.uncertain > 0 || meter.activity.error != nil { return "Unconfirmed" }
        return "Idle"
    }
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
            if let reading, let reset = reading.reset { parts.append(reset.formatted(date: .abbreviated, time: .omitted)) }
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
