import SwiftUI

/// The same report availability is used for headline and detailed coverage.
struct CostSummary: View {
    var report: CostReport
    var basis: CostPriceBasis
    var refreshing = false
    var sourceDate: Date?
    var sourceError: String?
    var sourceAvailable = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if refreshing {
                Text(report.calculatedAt == nil ? "Loading cost results…" : "Refreshing… Previous calculation remains visible until the new result is ready.")
                    .foregroundStyle(.secondary)
            }
            if let sourceError {
                ErrorNotice(message: "Usage read failed or was incomplete. " + sourceError)
                if report.calculatedAt != nil { Text("The estimate uses the available local snapshot; it may be stale or incomplete.").foregroundStyle(.secondary) }
            }
            if !refreshing || report.calculatedAt != nil { Text(report.statusMessage(sourceAvailable: sourceAvailable)).foregroundStyle(.secondary) }
            if let sourceDate {
                HStack(spacing: 4) {
                    Text("Last successful usage read")
                    RelativeAgeText(date: sourceDate)
                    Text("ago · " + sourceDate.formatted(date: .abbreviated, time: .shortened))
                }.font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: PageStyle.related) {
                metric("ESTIMATED API EQUIVALENT", report.hasPricedRecords ? CostPricing.dollars(report.amounts.total) : "—", "USD · API equivalent")
                metric("PRICING COVERAGE", report.coverage.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                       report.calculatedAt == nil ? "Awaiting calculation" : report.lines.isEmpty ? "No selected usage" : "\(compact(report.unpricedTokens)) tokens unpriced")
                metric("UNKNOWN REASONING LEVEL", report.lines.isEmpty ? "—" : compact(report.unknownEffortTokens), "tokens with no recorded effort")
            }
            Text(basis == .historical ? "Dated API rates where verified. Unknown historical tariffs and ambiguous price-change days remain unpriced. This is an API-equivalent estimate, not an amount paid." : "Valued at the \(CostRateCard.reference.observedOn) reference rates. This is not a bill or subscription charge.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        SummaryMetric(title: title, value: value, detail: detail)
    }
}
