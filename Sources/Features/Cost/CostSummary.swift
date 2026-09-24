import SwiftUI

/// The same report availability is used for headline and detailed coverage.
struct CostSummary: View {
    var report: CostReport
    var refreshing = false
    var sourceDate: Date?
    var sourceError: String?
    var sourceAvailable = true
    var sourceHealth: UsageReadHealth?
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.related) {
            ReadStatusView(state: ReadPresentation(hasResult: report.calculatedAt != nil && sourceAvailable,
                refreshing: refreshing, failed: sourceHealth?.failed ?? (sourceError != nil),
                partial: report.unpricedTokens > 0 || sourceHealth?.partial == true), date: sourceDate)
            if let sourceHealth { UsageDiagnosticsView(health: sourceHealth) }
            else if let sourceError { ErrorNotice(message: sourceError) }
            if !refreshing || report.calculatedAt != nil { Text(report.statusMessage(sourceAvailable: sourceAvailable)).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: PageStyle.related) {
                metric("ESTIMATED API EQUIVALENT", report.hasPricedRecords ? CostPricing.dollars(report.amounts.total) : "—", "USD · API equivalent")
                metric("PRICING COVERAGE", report.coverageText,
                       report.calculatedAt == nil ? "Awaiting calculation" : report.lines.isEmpty ? "No selected usage" : "\(compact(report.unpricedTokens)) tokens unpriced")
            }
        }
    }
    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        SummaryMetric(title: title, value: value, detail: detail)
            .moduleSurface()
    }
}
