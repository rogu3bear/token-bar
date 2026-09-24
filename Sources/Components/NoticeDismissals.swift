import Observation
import SwiftUI
import CryptoKit

/// Session-only acknowledgements. Never writes to the ledger or notification settings.
@Observable final class NoticeDismissals {
    private var dismissed: Set<String> = []
    private struct Allowance { var reset: Date?; var level: Int }
    private var allowances: [String: Allowance] = [:]
    static func key(_ parts: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(parts.sorted())) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    func contains(_ key: String) -> Bool { dismissed.contains(key) }
    func dismiss(_ key: String) { dismissed.insert(key) }
    func containsAllowance(_ id: String, reset: Date?, level: Int) -> Bool {
        guard let saved = allowances[id], level <= saved.level else { return false }
        switch (saved.reset, reset) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= 60
        default: return false
        }
    }
    func dismissAllowance(_ id: String, reset: Date?, level: Int) {
        allowances[id] = Allowance(reset: reset, level: level)
    }
    func restore() { dismissed.removeAll(); allowances.removeAll() }
    var hasDismissed: Bool { !dismissed.isEmpty || !allowances.isEmpty }
}

private struct NoticeDismissalsKey: EnvironmentKey {
    static let defaultValue = NoticeDismissals()
}
extension EnvironmentValues {
    var noticeDismissals: NoticeDismissals {
        get { self[NoticeDismissalsKey.self] }
        set { self[NoticeDismissalsKey.self] = newValue }
    }
}

struct DismissNoticeButton: View {
    var label = "Dismiss warning"
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), action) } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help("Dismiss for this session")
    }
}
