import Foundation

enum ImportProgress: Equatable {
    case discovering, codex(completed: Int, total: Int), otherTools, costDetails, catalog
    case work(title: String, completed: Int, total: Int, unit: String)
    var title: String {
        switch self {
        case let .work(title, _, _, _): return title
        case .discovering: return "Finding local history"
        case .codex: return "Reading Codex history"
        case .otherTools: return "Reading other tool history"
        case .costDetails: return "Checking cost details"
        case .catalog: return "Preparing your reports"
        }
    }
    var detail: String {
        switch self {
        case let .work(_, completed, total, unit): return Self.checked(completed: completed, total: total, unit: unit)
        case .discovering: return "Finding files. The amount of new usage is not known yet."
        case let .codex(completed, total): return Self.checked(completed: completed, total: total, unit: "files")
        case .otherTools: return "Reading Claude, Grok, and OpenCode files. The remaining file count is not known yet."
        case .costDetails: return "Adding missing pricing details to recorded usage. This does not add tokens."
        case .catalog: return "History has been checked. Updating task names and report totals."
        }
    }
    /// Known remaining is only a count when the stage has a total. Zero total is still finding work, not 0 remaining.
    private static func checked(completed: Int, total: Int, unit: String) -> String {
        total == 0 ? "Finding \(unit) to check…" : "\(completed.formatted()) of \(total.formatted()) \(unit) checked · \(max(0, total - completed).formatted()) remaining."
    }
    var fraction: Double? {
        let completed: Int, total: Int
        switch self {
        case let .codex(done, count), let .work(_, done, count, _): completed = done; total = count
        default: return nil
        }
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}
