import SwiftUI

enum QuotaGuardChrome {
    static func hasWarning(_ risks: [QuotaRisk]) -> Bool {
        risks.contains { $0 != .none }
    }
    static func hasWarning(_ decisions: [QuotaGuardDecision]) -> Bool {
        hasWarning(decisions.map(\.risk))
    }
}

struct QuotaGuardSummary: View {
    @Bindable var coordinator: QuotaGuardCoordinator
    var compact = false
    @State private var expanded = false
    @Environment(\.noticeDismissals) private var notices
    private var warnings: [QuotaGuardDecision] {
        coordinator.decisions.filter { $0.risk != .none && !notices.containsAllowance($0.id, reset: $0.reading?.reset, level: $0.level) }
    }
    var body: some View {
        let warning = !warnings.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if warning {
                HStack {
                    Label("Quota Guard", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange)
                    if warnings.count > 1 { Text("\(warnings.count) allowance warnings").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if warnings.count > 1 {
                        Button(expanded ? "Less" : "More warnings") { expanded.toggle() }.font(.caption)
                    }
                }
                if let first = warnings.first {
                    if expanded { row(first) } else { summary(first) }
                }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(warnings.filter { $0.id != warnings.first?.id }) { row($0) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: compact ? 180 : 260)
                }
            }
            if let error = coordinator.persistenceError { Text(error).font(.caption).foregroundStyle(.orange) }
            if coordinator.submissionState.hasPrefix("That allowance") { Text(coordinator.submissionState).font(.caption).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: Binding(get: { compact ? nil : coordinator.selected }, set: { coordinator.selected = $0 })) { decision in
            QuotaGuardDetail(coordinator: coordinator, decision: decision)
        }
    }
    private func summary(_ decision: QuotaGuardDecision) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: PageStyle.related) {
                summaryText(decision).frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                actions(decision).fixedSize()
            }
            VStack(alignment: .leading, spacing: PageStyle.labelGap) {
                summaryText(decision)
                actions(decision)
            }
        }
    }
    private func summaryText(_ decision: QuotaGuardDecision) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(decision.title).font(.caption.weight(.semibold)).lineLimit(2).help(decision.title)
            Text(decision.riskLabel + (decision.remaining.map { " · " + CompactLiveCopy.percent($0) + " remaining" } ?? "") +
                 (decision.forecast.map { " · " + Runway.clockLabel($0, now: decision.evaluated) } ?? ""))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }.help(decision.reason.label + ". Open Allowances for source and reset times.")
    }
    private func actions(_ decision: QuotaGuardDecision) -> some View {
        HStack {
            Button(QuotaGuardAction.viewTitle) { coordinator.view(decision) }
                .accessibilityLabel(QuotaGuardAction.viewTitle + " for " + decision.title)
            Button(coordinator.isSnoozed(decision) ? "Snoozed 30 min" : QuotaGuardAction.snoozeTitle) { coordinator.snooze(decision) }
                .disabled(coordinator.isSnoozed(decision))
                .accessibilityLabel("Snooze notifications for " + decision.title + " for 30 minutes")
            DismissNoticeButton(label: "Dismiss " + decision.tool.label + " allowance warning") {
                notices.dismissAllowance(decision.id, reset: decision.reading?.reset, level: decision.level)
            }
        }.font(.caption)
    }
    private func row(_ decision: QuotaGuardDecision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(decision.title).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(decision.riskLabel + (decision.remaining.map { " · " + CompactLiveCopy.percent($0) + " remaining" } ?? ""))
                .font(.caption).foregroundStyle(decision.risk == .observedExhaustion ? Color.red : Color.primary)
            if let forecast = decision.forecast { Text("At recent burn: " + Runway.clockLabel(forecast, now: decision.evaluated)).font(.caption) }
            Text(decision.reason.label).font(.caption).foregroundStyle(.secondary)
            if let reading = decision.reading {
                Text("Reset " + (reading.resetWhen ?? "unavailable") + " · read " + reading.date.formatted(date: .omitted, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
                actions(decision)
            }
        }
    }
}
struct QuotaGuardDetail: View {
    @Bindable var coordinator: QuotaGuardCoordinator
    let decision: QuotaGuardDecision
    private var evidence: QuotaGuardDecision { coordinator.selectedEvidence ?? decision }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(evidence.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if coordinator.selectedEvidence == nil { Text("Historical observation: this allowance is no longer current. It has not been redirected to another account or window.").foregroundStyle(.orange) }
            else if !coordinator.selectedIsCurrent { Text("No fresh assessment is available for this allowance.").foregroundStyle(.orange) }
            Text(evidence.riskLabel + (evidence.remaining.map { " · " + CompactLiveCopy.percent($0) + " remaining" } ?? ""))
            Text(evidence.reason.label)
            if let r = evidence.reading {
                Text("Bucket: " + r.bucket + " · Window: " + r.window)
                Text("Observed " + r.date.formatted() + " · Reset " + (r.resetWhen ?? "unavailable"))
            }
            Text("Account reference: " + decision.id.prefix(10)).font(.caption).textSelection(.enabled)
            if let forecast = evidence.forecast { Text("Projected exhaustion " + Runway.clockLabel(forecast, now: evidence.evaluated)) }
            Text("This is one account allowance, not a whole-tool stop. Forecasts assume recent quota burn continues; they are not a guarantee or token-speed measurement.").font(.caption).foregroundStyle(.secondary)
            Button("Done") { coordinator.selected = nil }.keyboardShortcut(.defaultAction)
        }.padding(PageStyle.section).frame(width: 460).appCanvas().onExitCommand { coordinator.selected = nil }
    }
}
struct QuotaGuardSettingsView: View {
    @Bindable var coordinator: QuotaGuardCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quota Guard").font(.headline)
            Stepper("Low allowance: \(Int(coordinator.settings.policy.lowPercent))% remaining", value: Binding(get: { coordinator.settings.policy.lowPercent }, set: { value in
                var settings = coordinator.settings; settings.policy.lowPercent = value; coordinator.configure(settings)
            }), in: 5...50, step: 1)
            Stepper("Forecast lead: \(Int(coordinator.settings.policy.leadMinutes)) minutes", value: Binding(get: { coordinator.settings.policy.leadMinutes }, set: { value in
                var settings = coordinator.settings; settings.policy.leadMinutes = value; coordinator.configure(settings)
            }), in: 10...120, step: 5)
            Toggle("Enable quota notifications", isOn: Binding(get: { coordinator.settings.notifications }, set: { enabled in
                var settings = coordinator.settings; settings.notifications = enabled; coordinator.configure(settings, userEnabled: enabled)
            }))
            Toggle("Play notification sound", isOn: Binding(get: { coordinator.settings.sound }, set: { enabled in
                var settings = coordinator.settings; settings.sound = enabled; coordinator.configure(settings)
            })).disabled(!coordinator.settings.notifications)
            Text("Permission: " + coordinator.permission.rawValue + ". " + coordinator.submissionState).font(.caption).foregroundStyle(.secondary)
            Text("Escalation: 5% remaining or a forecast within 10 minutes. Forecast alerts need two distinct fresh observations. Snooze suppresses notifications for this allowance for 30 minutes, including escalations. macOS may delay or suppress delivery; in-app warnings stay available.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
