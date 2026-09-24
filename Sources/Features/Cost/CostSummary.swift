import SwiftUI

/// The same report availability is used for headline and detailed coverage.
struct CostSummary: View {
    var report: CostReport
    var refreshing = false
    var sourceDate: Date?
    var sourceError: String?
    var sourceAvailable = true
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.related) {
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
                ReadAgeCaption(date: sourceDate, prefix: "Last successful usage read")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: PageStyle.related) {
                metric("ESTIMATED API EQUIVALENT", report.hasPricedRecords ? CostPricing.dollars(report.amounts.total) : "—", "USD · API equivalent")
                metric("PRICING COVERAGE", report.coverageText,
                       report.calculatedAt == nil ? "Awaiting calculation" : report.lines.isEmpty ? "No selected usage" : "\(compact(report.unpricedTokens)) tokens unpriced")
            }
        }
    }
    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        SummaryMetric(title: title, value: value, detail: detail)
    }
}
