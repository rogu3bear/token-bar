import SwiftUI
import Charts

struct CostView: View {
    @Bindable var model: UsageModel
    @Environment(\.appAccent) private var accent
    @State private var breakdown = 0
    @State private var showMethod = false
    @State private var showAll = false
    private var report: CostReport { model.costReport }
    private var rows: [CostRow] { breakdown == 0 ? report.models : report.efforts }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                header
                if let integrity = model.snapshot.integrity, !integrity.isClean { IntegrityBanner(report: integrity) }
                periodFilter
                ReportFilters(model: model, includesCost: true)
                pricingAssumptions
                DetailSheet("Published model price history") { CostRateHistoryView(selectedModel: model.modelFilter) }
                CostSummary(report: report, basis: model.costBasis, refreshing: model.busy || model.filtering,
                            sourceDate: model.lastSuccessfulUsageRead, sourceError: model.snapshot.error, sourceAvailable: model.costSourceAvailable)
                if report.calculatedAt != nil && model.costSourceAvailable {
                    CostUsageContext(model: model, monitor: model.live)
                    CostOutputComparison(report: report, basis: model.costBasis)
                    VStack(alignment: .leading, spacing: 14) {
                        ChoiceRow(title: "Compare", selection: $breakdown, choices: [(0, "Models"), (1, "Reasoning levels")], segmented: true)
                        ForEach(Array((showAll ? rows : Array(rows.prefix(8))))) { row in costRow(row) }
                        if rows.count > 8 { Button { showAll.toggle() } label: { Text(showAll ? "Show fewer" : "Show all \(rows.count)").foregroundStyle(accent) }.buttonStyle(.link) }
                        if rows.isEmpty { Text("No usage matches these filters.").foregroundStyle(.secondary) }
                    }
                    dailyChart
                    contributions
                    if !report.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Usage still awaiting a price").font(.headline)
                            ForEach(report.issues.keys.sorted(), id: \.self) { reason in
                                HStack { Text(reason); Spacer(); Text(compact(report.issues[reason] ?? 0) + " tokens").monospacedDigit() }
                            }
                        }.font(.callout).padding(16).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                DetailSheet("Report details and exports") {
                    if report.calculatedAt != nil && model.costSourceAvailable {
                        CostEvidenceView(model: model, monitor: model.live).padding(.top, 12)
                    } else {
                        Text("Evidence details require an available calculated report. Recover details retries the local usage read.")
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
        PageHeader("Cost", subtitle: "What the selected usage is worth under these pricing assumptions.") {
            Button("Recover details") { model.refresh(history: true, recoverCosts: true) }.disabled(model.busy)
            Button("Export CSV") { model.exportCosts() }.disabled(model.filtering || model.busy || report.lines.isEmpty)
            MethodButton(title: "How cost is calculated") { showMethod = true }
        }
    }
    private var periodFilter: some View { ReportPeriodFilter(model: model) }
    private var pricingAssumptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSheet("Pricing · " + model.costBasis.rawValue + " · " + model.costService.rawValue) {
                Text("Change valuation, not which usage records are selected.").font(.caption).foregroundStyle(.secondary)
                ChoiceRow(title: "Rate dates", selection: $model.costBasis, choices: CostPriceBasis.allCases.map { ($0, $0.rawValue) }, segmented: true)
                ChoiceRow(title: "Service · Standard/Fast are comparisons", selection: $model.costService, choices: CostService.allCases.map { ($0, $0.rawValue) }, segmented: true)
            }
        }
    }
    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated cost over time").font(PageStyle.sectionTitle)
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
            }.chartYAxisLabel("USD").frame(height: 190)
                .overlay { if report.timeline.isEmpty { Text("No timestamped priceable usage in this period").foregroundStyle(.secondary) } }
            Text(report.minuteResolution ? "Cumulative API-equivalent estimate · minute resolution · local time. Unpriced usage is excluded." : "Daily totals. Unpriced usage is excluded from dollar bars and retained in the selected report and coverage.").font(.caption).foregroundStyle(.secondary)
            if report.dailyOnlyAmount.total > 0 {
                Text(UsageTimeline.dailyOnlyCaption(CostPricing.dollars(report.dailyOnlyAmount.total), additionalTokens: false)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var contributions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What contributes to the estimate").font(PageStyle.sectionTitle)
            HStack(alignment: .top, spacing: 16) {
                component("Input", report.amounts.input)
                component("Cache reads", report.amounts.cached)
                component("Cache writes", report.amounts.cacheWrite)
                component("Reasoning", report.amounts.reasoning)
                component("Answer", report.amounts.answer)
            }
            Text("Reasoning and answer partition output; cache reads and writes partition input. Nothing is counted twice.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func component(_ title: String, _ amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(!report.hasPricedRecords ? "—" : CostPricing.dollars(amount)).font(PageStyle.detailMetric).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func costRow(_ row: CostRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title).font(.callout.weight(.medium)).textSelection(.enabled)
                Spacer()
                Text(row.hasPricedRecords ? CostPricing.dollars(row.amounts.total) : "Unpriced").monospacedDigit()
            }
            ProgressView(value: NSDecimalNumber(decimal: row.amounts.total).doubleValue,
                         total: max(0.000001, NSDecimalNumber(decimal: rows.first?.amounts.total ?? 0).doubleValue))
                .progressViewStyle(ReportMagnitudeStyle())
            Text(row.output.usdPerMillionOutput.map { CostPricing.dollars($0) + " / 1M output tokens · same priced records" } ?? "Cost per output unavailable")
                .font(.callout).monospacedDigit()
            Text("\(compact(row.pricedTokens)) tokens priced · \(compact(row.unpricedTokens)) unpriced · \(row.records.formatted()) records")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var method: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("API-equivalent estimates and evidence").font(PageStyle.sectionTitle)
            Text("Historical rates use dated, sourced versions and leave unsupported intervals unpriced. Reference rates apply the \(CostRateCard.reference.observedOn) card to any period for comparison. Recorded tier uses only a tier present in usage metadata; Standard and Fast are explicit scenarios. Neither establishes a charge. Subscriptions, credits, taxes, regional uplifts, and tool fees are excluded.")
            Text("Effort is the setting recorded for a turn. It is not inferred from reasoning-token counts and does not multiply prices. Missing effort stays Unknown; models with no verified price stay unpriced.")
            Text("A single-request observation is needed to choose a long-context rate. For session-wide pricing, all observed usage in that task is considered even outside your filters. Missing evidence is never assumed to be short context.")
            Text("Recover details reads available local logs into temporary storage and enriches only groups whose token totals and record counts match existing history. Missing files, changed totals, or mixed account attribution leave the original group intact. A private rollback ledger is saved before enrichment.")
            Link(destination: CostRateCard.reference.source) { Text("OpenAI pricing source").foregroundStyle(accent) }
            SheetDoneButton { showMethod = false }
        }.padding(PageStyle.gutter).frame(width: 560).onExitCommand { showMethod = false }
    }
}
