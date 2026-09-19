import SwiftUI

/// Process-local fixture settings. Never installed in the user's preferences.
enum PreviewFixture {
    /// Distinct synthetic source diagnostics; never derived from a real ledger.
    static let sourceDiagnostics = (0..<2359).map { index in
        let scope = index < 2020 ? "history" : "live"
        let reason = index % 2 == 0
            ? "Source was replaced by a different session; prior totals retained."
            : "Source continuity is incomplete; retained prior totals and admitted only independently supported requests."
        return "Codex · \(scope) · /synthetic/sessions/sample-\(index).jsonl: " + reason
    }.joined(separator: " ")

    static let date = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!
    static func prepare() {
        setenv("TZ", "UTC", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
    }
    /// Wall time bounds waiting only; it never supplies displayed fixture data.
    @MainActor static func settle(_ label: String, timeout: TimeInterval = 15, ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard ready() else {
            throw NSError(domain: "PreviewFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture did not settle: " + label])
        }
    }
}
extension View {
    func previewStill() -> some View {
        environment(\.evaluationDate, PreviewFixture.date)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}
