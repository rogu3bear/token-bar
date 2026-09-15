import Foundation

enum AccountQuotaPresentation {
    static func visible(_ readings: [QuotaReading]) -> [QuotaReading] {
        // Provider identity for the Spark allowance. Keep its saved
        // observations intact; only Accounts & plans omits this bucket.
        readings.filter { $0.bucket != "codex_bengalfox" }
    }
}
