import SwiftUI
import Charts

struct HistoryView: View {
    @Bindable var model: UsageModel
    @Environment(\.appAccent) private var accent
    @Environment(\.toolPalette) private var palette
    @State private var breakdown = 0
    @State private var metric = UsageMetric.output
    @State private var showMethod = false
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                header
                if let integrity = model.snapshot.integrity, !integrity.isClean { IntegrityBanner(report: integrity) }
                periodFilter
                filters
                if let error = model.snapshot.error {
                    Text("Usage read failed or was incomplete. Results below may be stale or incomplete.")
                        .font(.callout).foregroundStyle(.secondary)
                    ErrorNotice(message: error)
                }
                HStack(alignment: .top, spacing: PageStyle.related) {
                    card(UsageMetric.total, model.totals)
                    card("INPUT", model.totals.input)
                    card(UsageMetric.output, model.totals)
                }
                ChoiceFlow(spacing: 14) {
                    ForEach(model.report.toolTimelines) { series in
                        HStack(spacing: 5) {
                            Circle().fill(series.tool.color(in: palette)).frame(width: 8, height: 8)
                            Text(series.id + ": " + UsageMetric.total.formatted(series.totals))
                        }.font(.caption).help(series.totals.total.formatted() + " processed tokens in the selected report")
                    }
                }
                Text("Total = input + output. Cached input is already in input; reasoning is already in output. These are processed tokens, not quota or billed cost.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.report.entries.contains(where: { $0.tokens.cached > $0.tokens.input || $0.tokens.reasoning > $0.tokens.output }) {
                    StatusNotice(message: "Some source counters have inconsistent cached-input or reasoning subsets. The total still uses input + output; subset comparisons may be unreliable.", severity: .warning, dismissible: false)
                }
                ChoiceRow(title: "Measure", selection: $metric, choices: UsageMetric.allCases.map { ($0, $0.rawValue) }, segmented: true)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Where the usage went").font(PageStyle.sectionTitle)
                    ChoiceRow(title: "Compare", selection: $breakdown, choices: [(0, "Tasks"), (1, "Models"), (2, "Accounts"), (3, "Days"), (4, "Tools"), (5, "Projects")])
                    ContributionChart(rows: rows, metric: metric)
                    if breakdown == 2 { Text("Account associations are inferred from local sign-in observations. Unattributed history stays separate.").font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Usage over time").font(PageStyle.sectionTitle)
                        Spacer()
                        Text("\(model.report.tasks.count.formatted()) tasks · Local time").font(.caption).foregroundStyle(.secondary)
                    }
                    UsageTimelineChart(timeline: model.report.timeline, metric: metric, tools: model.report.toolTimelines)
                }
                HStack {
                    MethodButton(title: "How history is counted") { showMethod = true }
                    Spacer()
                    if let updated = model.snapshot.updated {
                        ReadAgeCaption(date: updated, prefix: "Updated", includesClock: false).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
        }
        .sheet(isPresented: $showMethod) {
            VStack(alignment: .leading, spacing: 18) {
                Text("How history is counted").font(PageStyle.sectionTitle)
                Text("Reused context is counted on each processing pass, so totals are not unique written tokens. Repeated counter snapshots and inherited fork counters are deduplicated. Older records are grouped by day, task, and model; raw logs remain unchanged.")
                Text("Account identity marked inferred comes from local sign-in observations, not execution or billing records. Historical usage without that evidence remains unattributed.")
                SheetDoneButton { showMethod = false }
            }.padding(PageStyle.gutter).frame(width: 500).onExitCommand { showMethod = false }
        }
    }
    private var header: some View {
        PageHeader(.history, subtitle: model.snapshot.historyImportedAt.map { "Local history checked " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Local history is being gathered automatically") {
            Button("Refresh history") { model.refresh(history: true) }.disabled(model.busy)
            Button("Export CSV") { model.export() }.disabled(model.filtering || model.busy)
        }
    }
    private var periodFilter: some View { ReportPeriodFilter(model: model) }
    private var filters: some View { ReportFilters(model: model) }
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
    private func card(_ metric: UsageMetric, _ tokens: Tokens) -> some View {
        SummaryMetric(title: metric.rawValue.uppercased(), value: metric.formatted(tokens))
            .help(metric.amount(tokens).formatted() + " tokens")
    }
    private func card(_ label: String, _ value: Int) -> some View {
        SummaryMetric(title: label, value: compact(value))
            .help(value.formatted() + " tokens")
    }
}
