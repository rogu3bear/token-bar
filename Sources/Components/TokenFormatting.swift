import Foundation

enum TokenFormatting {
    static let thousand = 1_000
    static let million = 1_000_000
    static let billion = 1_000_000_000

    static func compact(_ value: Int) -> String {
        let amount = Double(value)
        if value >= billion { return String(format: "%.2fB", amount / Double(billion)) }
        if value >= million { return String(format: "%.2fM", amount / Double(million)) }
        if value >= thousand { return String(format: "%.1fK", amount / Double(thousand)) }
        return "\(value)"
    }
}

func compact(_ value: Int) -> String { TokenFormatting.compact(value) }
