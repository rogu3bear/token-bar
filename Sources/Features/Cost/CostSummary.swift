import SwiftUI

/// Valuation and its pricing coverage are one claim. Source coverage is separate.
struct CostSummary: View {
    var report: CostReport
    var refreshing = false
    var sourceDate: Date?
    var sourceError: String?
    var sourceAvailable = true
    var sourceHealth: UsageReadHealth?
    var showsDiagnostics = true
    private var available: Bool { sourceAvailable && report.calculatedAt != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ESTIMATED API EQUIVALENT").font(.caption).foregroundStyle(.secondary)
                        Text(available && report.hasPricedRecords ? CostPricing.dollars(report.amounts.total) : "—")
                            .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("USD · estimate, not an amount paid").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PRICING COVERAGE").font(.caption).foregroundStyle(.secondary)
                        Text(available ? report.coverageText : "—").font(PageStyle.metric).monospacedDigit()
                        Text(!available ? "Awaiting available history" : report.lines.isEmpty ? "No selected usage" : compact(report.unpricedTokens) + " tokens unpriced")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 16) {
                    Text(report.statusMessage(sourceAvailable: sourceAvailable)).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ReportFreshness(state: ReadPresentation(hasResult: available, refreshing: refreshing,
                        failed: sourceHealth?.failed ?? (sourceError != nil)), date: sourceDate)
                }
            }.moduleSurface()
            if available, let reported = report.reportedGrokUsd {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECORDED GROK COST").font(.caption).foregroundStyle(.secondary)
                    Text(CostPricing.dollars(reported)).font(PageStyle.metric).monospacedDigit()
                    Text("USD retained in local Grok usage records. " + report.reportedGrokQualification + " Separate from the API estimate and amounts paid.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).moduleSurface()
            }
            if showsDiagnostics {
                if let sourceHealth { UsageDiagnosticsView(health: sourceHealth, compact: true) }
                else if let sourceError { ErrorNotice(message: sourceError) }
            }
        }
    }
}
