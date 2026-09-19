import Foundation

enum AccountQuotaPresentation {
    /// Provider identity for the Spark allowance. Keep its saved
    /// observations intact; only Accounts & plans omits this bucket.
    static let omittedBucket = "codex_bengalfox"
    static func visible(_ readings: [QuotaReading]) -> [QuotaReading] {
        readings.filter { $0.bucket != omittedBucket }
    }
}
