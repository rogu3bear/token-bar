import SwiftUI
import Charts

struct CostView: View {
    @Bindable var model: UsageModel
    @Environment(\.appAccent) private var accent
    private var breakdown: Int { model.reporting.costBreakdown }
    @State private var showMethod = false
    @State private var showAll = false
    private var report: CostReport { model.costReport }
    private var rows: [CostRow] { breakdown == 0 ? report.models : report.efforts }
    var body: some View {
        @Bindable var reporting = model.reporting
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.reportSection) {
                header
                HStack(alignment: .top, spacing: PageStyle.related) {
                    periodFilter.frame(maxWidth: model.period == 4 ? .infinity : 260, alignment: .leading)
                    pricingAssumptions
                    Spacer(minLength: 8)
                    ReportFilters(model: model, includesCost: true)
                }
                CostSummary(report: report, refreshing: model.busy || model.filtering,
                            sourceDate: model.lastSuccessfulUsageRead, sourceAvailable: model.costSourceAvailable,
                            sourceHealth: model.snapshot.readHealth, showsDiagnostics: false)
                UsageDiagnosticsView(health: model.snapshot.readHealth, compact: true)
                if let integrity = model.snapshot.integrity, !integrity.isClean { IntegrityBanner(report: integrity) }
                if report.calculatedAt != nil && model.costSourceAvailable {
                    contributions.moduleSurface()
                    dailyChart.moduleSurface()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cost attribution").font(PageStyle.sectionTitle)
                        ChoiceRow(title: "Compare", selection: $reporting.costBreakdown, choices: [(0, "Models"), (1, "Reasoning levels")], segmented: true)
                            .frame(maxWidth: 320)
                        ForEach(Array((showAll ? rows : Array(rows.prefix(8))))) { row in
                            costRow(row)
                            if row.id != (showAll ? rows.last?.id : rows.prefix(8).last?.id) { Divider() }
                        }
                        if rows.count > 8 { Button { showAll.toggle() } label: { Text(showAll ? "Show fewer" : "Show all \(rows.count)").foregroundStyle(accent) }.buttonStyle(.link) }
                        if rows.isEmpty { Text("No usage matches these filters.").foregroundStyle(.secondary) }
                    }.moduleSurface()
                    if !report.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Usage still awaiting a price").font(.headline)
                            ForEach(report.issues.keys.sorted(), id: \.self) { reason in
                                HStack { Text(reason); Spacer(); Text(compact(report.issues[reason] ?? 0) + " tokens").monospacedDigit() }
                            }
                        }.font(.callout).moduleSurface()
                    }
                }
                HStack {
                    Text("Diagnostics and recovery").font(.headline)
                    Spacer()
                    Button("Rebuild pricing details") { model.refresh(history: true, recoverCosts: true) }.disabled(model.busy)
                }
                DetailSheet("Report details and exports") {
                    if report.calculatedAt != nil && model.costSourceAvailable {
                        CostUsageContext(model: model, monitor: model.live).padding(.top, 12)
                        CostOutputComparison(report: report, basis: model.costBasis)
                        CostRateHistoryView(selectedModel: model.modelFilter)
                        CostEvidenceView(model: model, monitor: model.live)
                    } else {
                        Text("Evidence details require an available calculated report. Rebuild pricing details retries the local usage read.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
                if let message = model.costRecoveryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
        }
        .sheet(isPresented: $showMethod) { method }
    }
    private var header: some View {
        PageHeader(.cost) {
            Button("Export CSV") { model.exportCosts() }.disabled(model.filtering || model.busy || report.lines.isEmpty)
            MethodButton(title: "How cost is calculated") { showMethod = true }
        }
    }
    private var periodFilter: some View { ReportPeriodFilter(model: model) }
    private var pricingAssumptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSheet("Pricing basis · " + model.costBasis.rawValue + " · " + model.costService.rawValue) {
                Text("Change valuation, not which usage records are selected.").font(.caption).foregroundStyle(.secondary)
                ChoiceRow(title: "Rate dates", selection: $model.costBasis, choices: CostPriceBasis.allCases.map { ($0, $0.rawValue) }, segmented: true)
                ChoiceRow(title: "Service · Standard/Fast are comparisons", selection: $model.costService, choices: CostService.allCases.map { ($0, $0.rawValue) }, segmented: true)
            }
        }
    }
    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated cost over time").font(PageStyle.sectionTitle)
            Text(report.minuteResolution ? "Cumulative estimated API equivalent (USD)" : "Daily estimated API equivalent (USD)")
                .font(.callout).foregroundStyle(.secondary)
            Chart(report.timeline) { point in
                if report.minuteResolution {
                    LineMark(x: .value("Minute", point.date), y: .value("USD", NSDecimalNumber(decimal: point.amounts.total).doubleValue))
                        .interpolationMethod(.stepEnd).foregroundStyle(accent)
                    PointMark(x: .value("Minute", point.date), y: .value("USD", NSDecimalNumber(decimal: point.amounts.total).doubleValue))
                        .symbolSize(12).foregroundStyle(accent)
                } else {
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value("USD", NSDecimalNumber(decimal: point.amounts.total).doubleValue))
                        .foregroundStyle(accent)
                }
            }.chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(date: report.minuteResolution ? .omitted : .abbreviated,
                                                time: report.minuteResolution ? .shortened : .omitted))
                        }
                    }
                }
            }.frame(height: 190)
                .overlay { if report.timeline.isEmpty { Text("No timestamped priceable usage in this period").foregroundStyle(.secondary) } }
            Text(report.minuteResolution ? "Cumulative API-equivalent estimate · minute resolution · local time. Unpriced usage is excluded." : "Daily totals. Unpriced usage is excluded from dollar bars and retained in the selected report and coverage.").font(.caption).foregroundStyle(.secondary)
            if report.dailyOnlyAmount.total > 0 {
                Text(UsageTimeline.dailyOnlyCaption(CostPricing.dollars(report.dailyOnlyAmount.total), additionalTokens: false)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var contributions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost composition").font(PageStyle.sectionTitle)
            if report.hasPricedRecords {
                ReportComposition(parts: [
                    ("Input", report.amounts.input), ("Cache reads", report.amounts.cached),
                    ("Cache writes", report.amounts.cacheWrite), ("Reasoning", report.amounts.reasoning),
                    ("Answer", report.amounts.answer)
                ].map { CompositionPart(id: $0.0, amount: NSDecimalNumber(decimal: $0.1).doubleValue, value: CostPricing.dollars($0.1)) })
            } else {
                Text("No priced usage to break down.").foregroundStyle(.secondary)
            }
            Text("Input excludes cache reads and writes. Reasoning and answer split output. Unpriced usage is excluded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func costRow(_ row: CostRow) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.callout.weight(.medium)).textSelection(.enabled)
                Text(row.hasPricedRecords
                     ? "\(compact(row.pricedTokens)) tokens priced · \(compact(row.unpricedTokens)) unpriced · \(row.records.formatted()) \(row.records == 1 ? "record" : "records")"
                     : "\(compact(row.unpricedTokens)) tokens · \(row.records.formatted()) \(row.records == 1 ? "record" : "records") · No supported price")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(row.hasPricedRecords ? CostPricing.dollars(row.amounts.total) : "Unpriced")
                .font(.callout.weight(.medium)).monospacedDigit()
        }.padding(.vertical, 4)
    }
    private var method: some View {
        MethodSheet(title: "API-equivalent estimates and evidence", done: { showMethod = false }) {
            Text(model.costBasis == .historical
                 ? "Dated API rates where verified. Unknown historical tariffs and ambiguous price-change days remain unpriced. This is an API-equivalent estimate, not an amount paid."
                 : "Valued at the \(CostRateCard.reference.observedOn) reference rates. This is not a bill or subscription charge.")
            Text("Historical rates use dated, sourced versions and leave unsupported intervals unpriced. Reference rates apply the \(CostRateCard.reference.observedOn) card to any period for comparison. Recorded tier uses only a tier present in usage metadata; Standard and Fast are explicit scenarios. Neither establishes a charge. Subscriptions, credits, taxes, regional uplifts, and tool fees are excluded.")
            Text("Effort is the setting recorded for a turn. It is not inferred from reasoning-token counts and does not multiply prices. Missing effort stays Unknown; models with no verified price stay unpriced.")
            Text("A single-request observation is needed to choose a long-context rate. For session-wide pricing, all observed usage in that task is considered even outside your filters. Missing evidence is never assumed to be short context.")
            Text("Rebuild pricing details reads available local logs into temporary storage and enriches only groups whose token totals and record counts match existing history. Missing files, changed totals, or mixed account attribution leave the original group intact. A private rollback ledger is saved before enrichment.")
            Link(destination: CostRateCard.reference.source) { Text("OpenAI pricing source").foregroundStyle(accent) }
        }
    }
}
