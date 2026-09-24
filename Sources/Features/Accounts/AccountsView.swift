import SwiftUI
import Charts

struct AccountsView: View {
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    @Bindable var signIns: SignInTimeline
    @State private var showMethod = false
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    @Environment(\.presentationClock) private var clock
    private var now: Date { evaluationDate ?? clock.now }
    private var accounts: [LiveAccount] {
        monitor.state.accounts.values.sorted {
            if ($0.id == monitor.currentID) != ($1.id == monitor.currentID) { return $0.id == monitor.currentID }
            return $0.observed > $1.observed
        }
    }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                PageHeader(.accounts, subtitle: "Current remaining from installed Codex, Claude Code, and Grok.") {
                    MethodButton(title: "How allowances are read") { showMethod = true }
                }
                if let error = monitor.error { ErrorNotice(message: error) }
                VStack(alignment: .leading, spacing: PageStyle.related) {
                    ForEach(LiveTool.allCases) { tool in
                        AccountAllowanceDisclosure(tool: tool, quota: model.quota(for: tool), now: now)
                            .moduleSurface()
                    }
                }
                if accounts.isEmpty {
                    Text("No saved account observations yet. Sign in through a supported tool; the account and plan appear after a successful reading.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(accounts) { account in
                    let quotas = AccountQuotaPresentation.visible(account.quotas)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.email).font(.title3.bold()).textSelection(.enabled)
                                Text(account.plan.uppercased()).font(.callout).foregroundStyle(.primary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(account.id == monitor.currentID ? "Current sign-in" : "Previous account · saved reading")
                                    .font(.callout).foregroundStyle(account.id == monitor.currentID ? Color.primary : .secondary)
                                Text("Observed " + account.observed.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if quotas.isEmpty { Text("No quota windows to display for this account.").foregroundStyle(.secondary) }
                        LazyVGrid(columns: quotas.count == 1 ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 320), spacing: 20)], alignment: .leading, spacing: 20) {
                            ForEach(quotas) { quota in
                                QuotaTrendCard(quota: quota, history: monitor.state.quotaHistory ?? monitor.state.samples, samples: monitor.state.samples,
                                    current: account.id == monitor.currentID,
                                    confirmed: account.id == monitor.currentID && !model.quota(for: .codex).guardFailed)
                            }
                        }
                        let plans = monitor.state.plans.filter { $0.accountID == account.id }.sorted { $0.firstSeen < $1.firstSeen }
                        if !plans.isEmpty {
                            Text("Plan observations").font(.headline)
                            ForEach(plans) { plan in
                                HStack(spacing: 12) {
                                    Circle().fill(accent).frame(width: 7, height: 7)
                                    Text(plan.plan.uppercased()).fontWeight(.medium)
                                    Text(plan.firstSeen.formatted(date: .abbreviated, time: .omitted))
                                    Text("→ " + plan.lastSeen.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                                }.font(.callout)
                            }
                            Text("First and last observed dates, not subscription start or end dates.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.moduleSurface()
                }
                if !model.snapshot.plans.isEmpty {
                    HistoricalPlanChart(plans: model.snapshot.plans).moduleSurface()
                }
                if let error = signIns.error { ErrorNotice(message: error) }
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
        }
        .sheet(isPresented: $showMethod) {
            MethodSheet(title: "How allowances are read", done: { showMethod = false }) {
                Text(LiveTool.liveCoverage)
                Text("Saved account and plan observations are historical evidence. They do not establish subscription start or end dates. Gaps mean no readings; Token Bar does not switch accounts or reconstruct missing history.")
                Text("Quota observations are retained for 90 days, generally five minutes apart with resets preserved. A first sample needs a later reading before it can form a trend. Forecasts use recent quota burn and never token speed.")
            }
        }
        .sheet(item: Binding(get: { model.quotaGuard.selected }, set: { model.quotaGuard.selected = $0 })) { decision in
            QuotaGuardDetail(coordinator: model.quotaGuard, decision: decision)
        }
    }
}

struct QuotaTrendCard: View {
    var quota: QuotaReading
    var history: [QuotaReading]
    var samples: [QuotaReading]
    var current: Bool
    var confirmed = true
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    private var points: [QuotaPlotPoint] { QuotaPlotPoint.build(history + [quota], for: quota.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(quota.name + " · " + quota.windowLabel).font(.headline)
            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(x: .value("Observed", point.reading.date), y: .value("Quota left", max(0, 100 - point.reading.used)), series: .value("Segment", point.segment))
                        .foregroundStyle(accent)
                    PointMark(x: .value("Observed", point.reading.date), y: .value("Quota left", max(0, 100 - point.reading.used)))
                        .foregroundStyle(accent).symbolSize(10)
                }.chartYScale(domain: 0...100).chartLegend(.hidden).frame(height: 130)
            }
            Text(quota.resetWhen.map { "Reset " + $0 } ?? "Reset unavailable").font(.caption).foregroundStyle(.secondary)
            if current && confirmed {
                let estimate = Runway.estimate(quota, samples: samples, now: evaluationDate ?? Date())
                if let rate = estimate.percentPerHour { Text(String(format: "Recent burn: %.2f percentage points/hour", rate)).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct HistoricalPlanChart: View {
    var plans: [PlanObservation]
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plans found in local history").font(PageStyle.sectionTitle)
            Chart(plans) { observation in
                PointMark(x: .value("Observed", observation.firstSeen), y: .value("Plan", observation.plan.uppercased()))
                    .foregroundStyle(accent).symbolSize(24)
            }.frame(height: max(120, CGFloat(Set(plans.map(\.plan)).count) * 32))
            Text("Each point is a plan recorded in a usage log. \(plans.filter { $0.account == nil }.count.formatted()) observations have no known account; they are not assigned to your current sign-in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
