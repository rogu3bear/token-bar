import SwiftUI
import Charts

struct AccountsView: View {
    @Bindable var model: UsageModel
    @Bindable var monitor: LiveMonitor
    @Bindable var signIns: SignInTimeline
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    private var accounts: [LiveAccount] {
        monitor.state.accounts.values.sorted {
            if ($0.id == monitor.currentID) != ($1.id == monitor.currentID) { return $0.id == monitor.currentID }
            return $0.observed > $1.observed
        }
    }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                PageHeader(.accounts, subtitle: "Supported account observations: Codex. Claude’s current cached quota appears on Now; Claude account and plan history is not available here.") {
                    if monitor.busy { ProgressView().controlSize(.small) }
                }
                if let error = monitor.error { ErrorNotice(message: error) }
                if accounts.isEmpty {
                    Text("No saved Codex account observations. Sign in through Codex; the account and plan appear after a successful reading.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(accounts) { account in
                    let quotas = AccountQuotaPresentation.visible(account.quotas)
                    if account.id != accounts.first?.id { Divider() }
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
                                    current: account.id == monitor.currentID)
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
                    }
                }
                DetailSheet("About account readings") {
                Text("Quotas refresh every 30 seconds while the app runs. History is collected locally while this app runs. Quota samples are retained for 90 days, generally five minutes apart, with resets preserved. Gaps mean no readings; the app does not switch accounts or reconstruct missing quota history.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !model.snapshot.plans.isEmpty {
                    HistoricalPlanChart(plans: model.snapshot.plans)
                }
                if let error = signIns.error { ErrorNotice(message: error) }
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
        }
    }
}

struct QuotaTrendCard: View {
    var quota: QuotaReading
    var history: [QuotaReading]
    var samples: [QuotaReading]
    var current: Bool
    @Environment(\.appAccent) private var accent
    @Environment(\.evaluationDate) private var evaluationDate
    private var points: [QuotaPlotPoint] { QuotaPlotPoint.build(history + [quota], for: quota.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(quota.name + " · " + (quota.minutes >= 1440 ? "\(quota.minutes / 1440) days" : "\(quota.minutes / 60) hours")).font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f%%", max(0, 100 - quota.used))).font(PageStyle.title)
                Text(current ? "remaining at last reading" : "remaining when last observed").font(.caption).foregroundStyle(.secondary)
            }
            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(x: .value("Observed", point.reading.date), y: .value("Quota left", max(0, 100 - point.reading.used)), series: .value("Segment", point.segment))
                        .foregroundStyle(accent)
                    PointMark(x: .value("Observed", point.reading.date), y: .value("Quota left", max(0, 100 - point.reading.used)))
                        .foregroundStyle(accent).symbolSize(10)
                }.chartYScale(domain: 0...100).chartLegend(.hidden).frame(height: 130)
            } else { Text("History begins with this reading. More samples will appear automatically.").font(.callout).foregroundStyle(.secondary).frame(minHeight: 90) }
            Text(quota.reset.map { "Reset " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset unavailable").font(.caption).foregroundStyle(.secondary)
            if current {
                let estimate = Runway.estimate(quota, samples: samples, now: evaluationDate ?? Date())
                Text(estimate.message).font(.caption).foregroundStyle(.secondary)
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
            Text("Plans found in local history").font(.title2.bold())
            Chart(plans) { observation in
                PointMark(x: .value("Observed", observation.firstSeen), y: .value("Plan", observation.plan.uppercased()))
                    .foregroundStyle(accent).symbolSize(24)
            }.frame(height: max(120, CGFloat(Set(plans.map(\.plan)).count) * 32))
            Text("Each point is a plan recorded in a usage log. \(plans.filter { $0.account == nil }.count.formatted()) observations have no known account; they are not assigned to your current sign-in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
