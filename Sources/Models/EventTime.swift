import Foundation

/// ISO-8601 event timestamps from Codex, Claude Code, and UTC day bounds.
///
/// Fractional seconds are optional. A stamp that one reader admits must parse
/// the same way everywhere those logs are tailed. Grok six-digit offsets stay
/// on `GrokUsage.date` until that extra truncation can share this parser.
enum EventTime {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }

    static func parse(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        return parse(value)
    }
}
