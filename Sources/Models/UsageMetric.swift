import Foundation

enum UsageMetric: String, CaseIterable, Identifiable {
    case output = "Output", uncached = "Uncached input", cached = "Cached input", total = "Total processed"
    var id: String { rawValue }
    func amount(_ tokens: Tokens) -> Int {
        switch self {
        case .output: return tokens.output
        case .uncached: return max(0, tokens.input - tokens.cached)
        case .cached: return tokens.cached
        case .total: return tokens.total
        }
    }

    /// Compact face for this measure. Charts and History cards share `compact(_:)`.
    func formatted(_ tokens: Tokens) -> String {
        compact(amount(tokens))
    }
}

