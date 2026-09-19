import Foundation

/// Presence and provenance travel with the counters; zero and unavailable are different.
enum UsageMetadata {
    static let fields = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
    static func recordedFields(_ raw: [String: Any]) -> [String] { fields.filter { raw[$0] as? Int != nil } }
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func service(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.count <= 100 else { return nil }
        return value.lowercased()
    }
    static func enrich(_ entry: inout Entry, cursor: Cursor, fields: [String], fingerprint: String,
                       last: Tokens?, info: [String: Any]) {
        entry.tokenFields = fields
        entry.recordID = fingerprint; entry.turnID = cursor.turnID
        entry.requestedService = cursor.requestedService
        entry.observedService = service(info["service_tier"])
        entry.serviceEvidence = entry.observedService == nil ? nil : "token_count.info.service_tier"
        entry.pricingDay = day(entry.date); entry.firstObserved = entry.date
        if let last, entry.tokens == last, last.input >= 0, fields.contains("input_tokens") { entry.requestInputTokens = last.input }
        if !fields.contains("input_tokens") { entry.contextBand = nil }
        entry.costMetadataVersion = 2
    }
    static func aggregationKey(_ entry: Entry) -> String {
        "\(entry.pricingDay ?? "unknown")|\(entry.tokenFields?.sorted().joined(separator: ",") ?? "unknown")|\(entry.observedService ?? "unknown")|\(entry.requestedService ?? "unknown")"
    }
    /// Fill a missing UTC pricing day from a real source timestamp. Does not change counters.
    static func recoverPricingDay(_ entry: inout Entry) {
        guard entry.pricingDay == nil, entry.bucket != "day" else { return }
        entry.pricingDay = day(entry.date)
    }

    /// CSV attribution. Unattributed is unknown, never a guessed person; an id
    /// is local sign-in evidence, not a dashboard scrape.
    static let unknownAccount = "unknown"
    static let inferredAccount = "inferred from local sign-in observation"
    static func accountAttribution(_ account: Account?) -> String {
        account == nil ? unknownAccount : inferredAccount
    }
}
extension Entry {
    func hasField(_ name: String) -> Bool { tokenFields?.contains(name) == true }
    var isSingleRequest: Bool { requestInputTokens != nil || contextBand != nil }
    /// Share of the model's context window this request occupied, 0...1.
    ///
    /// Only defined for a single request whose input is known against a
    /// harness-reported window. A cumulative delta can span several calls, so
    /// dividing it by one window would overstate occupancy; that case stays
    /// unavailable rather than being approximated.
    var contextOccupancy: Double? {
        guard let window = contextWindow, window > 0, let input = requestInputTokens, input >= 0 else { return nil }
        return min(1, Double(input) / Double(window))
    }
}
