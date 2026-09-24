import SwiftUI
import Charts

struct HistoryView: View {
    @Bindable var model: UsageModel
    private var breakdown: Int { model.reporting.historyBreakdown }
    private var metric: UsageMetric { model.reporting.historyMetric }
    @State private var showMethod = false
    var body: some View {
        @Bindable var reporting = model.reporting
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.reportSection) {
                header
                HStack(alignment: .top, spacing: PageStyle.related) {
                    periodFilter.frame(maxWidth: model.period == 4 ? .infinity : 280, alignment: .leading)
                    filters
                    Spacer(minLength: 8)
                    ReportFreshness(state: ReadPresentation(snapshot: model.snapshot,
                        refreshing: model.busy || model.filtering), date: model.lastSuccessfulUsageRead)
                }
                summary
                UsageDiagnosticsView(health: model.snapshot.readHealth, compact: true)
                if let integrity = model.snapshot.integrity, !integrity.isClean { IntegrityBanner(report: integrity) }
                if model.report.entries.contains(where: { $0.tokens.cached > $0.tokens.input || $0.tokens.reasoning > $0.tokens.output }) {
                    StatusNotice(message: "Some source counters have inconsistent cached-input or reasoning subsets. The total still uses input + output; subset comparisons may be unreliable.", severity: .warning)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Where the usage went").font(PageStyle.sectionTitle)
                    ChoiceRow(title: "Measure", selection: $reporting.historyMetric, choices: UsageMetric.allCases.map { ($0, $0.rawValue) }, segmented: true)
                        .frame(maxWidth: 540)
                    ChoiceRow(title: "Compare", selection: $reporting.historyBreakdown, choices: [(0, "Tasks"), (1, "Models"), (2, "Accounts"), (3, "Days"), (4, "Tools"), (5, "Projects")])
                    ContributionChart(rows: rows, metric: metric)
                    if breakdown == 2 { Text("Account associations are inferred from local sign-in observations. Unattributed history stays separate.").font(.caption).foregroundStyle(.secondary) }
                }.moduleSurface()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Usage over time").font(PageStyle.sectionTitle)
                        Spacer()
                        Text("\(model.report.tasks.count.formatted()) tasks · Local time").font(.caption).foregroundStyle(.secondary)
                    }
                    UsageTimelineChart(timeline: model.report.timeline, metric: metric, tools: model.report.toolTimelines)
                }.moduleSurface()
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
        }
        .sheet(isPresented: $showMethod) {
            MethodSheet(title: "How history is counted", done: { showMethod = false }) {
                Text("Total = input + output. Cached input is already in input; reasoning is already in output. These are processed tokens, not quota or billed cost.")
                Text("Reused context is counted on each processing pass, so totals are not unique written tokens. Repeated counter snapshots and inherited fork counters are deduplicated. Older records are grouped by day, task, and model; raw logs remain unchanged.")
                Text("Account identity marked inferred comes from local sign-in observations, not execution or billing records. Historical usage without that evidence remains unattributed.")
            }
        }
    }
    private var header: some View {
        PageHeader(.history) {
            MethodButton(title: "How history is counted") { showMethod = true }
            Button("Refresh history") { model.refresh(history: true) }.disabled(model.busy)
            Button("Export CSV") { model.export() }.disabled(model.filtering || model.busy)
        }
    }
    private var periodFilter: some View { ReportPeriodFilter(model: model) }
    private var filters: some View { ReportFilters(model: model) }
    private var hasResult: Bool { model.snapshot.hasUsageResult }
    private var rows: [UsageRow] {
        switch breakdown {
        case 1: return model.report.models
        case 2: return model.report.accounts
        case 4: return model.report.harnesses
        case 5: return model.report.projects
        case 3: return model.report.days.map { UsageRow(id: $0.date.ISO8601Format(), title: $0.date.formatted(date: .complete, time: .omitted), tokens: $0.tokens, last: $0.date) }
        default: return model.report.tasks
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: PageStyle.related) {
                SummaryMetric(title: "TOTAL PROCESSED", value: hasResult ? UsageMetric.total.formatted(model.totals) : "—",
                              detail: "Input + output")
                    .help(hasResult ? model.totals.total.formatted() + " processed tokens" : "Reading unavailable")
                SummaryMetric(title: "INPUT", value: hasResult ? compact(model.totals.input) : "—", detail: "Includes cached input")
                    .help(hasResult ? model.totals.input.formatted() + " input tokens" : "Reading unavailable")
                SummaryMetric(title: "OUTPUT", value: hasResult ? compact(model.totals.output) : "—", detail: "Includes reasoning")
                    .help(hasResult ? model.totals.output.formatted() + " output tokens" : "Reading unavailable")
            }
            if hasResult && !model.report.toolTimelines.isEmpty {
                Divider()
                ReportComposition(parts: model.report.toolTimelines.map {
                    CompositionPart(id: $0.id, amount: Double($0.totals.total), value: UsageMetric.total.formatted($0.totals))
                })
            }
        }.moduleSurface()
    }
}
