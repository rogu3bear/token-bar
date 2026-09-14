import SwiftUI

struct ToolQuotaSummary: View {
    var tool: LiveTool
    var quota: ToolQuotaState
    var now: Date
    var compact = false
    var embedded = false
    var connection: ClaudeConnectionModel? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let reading = Runway.priority(quota.readings, samples: quota.samples, now: now, horizon: quota.horizon)
        let estimate = reading.map { Runway.estimate($0, samples: quota.samples, now: now, horizon: quota.horizon) }
        VStack(alignment: .leading, spacing: 10) {
            if embedded && !compact {
                VStack(spacing: 8) {
                    decisionValue("Remaining", text: estimate.map { String(format: "%.0f%%", $0.remaining) } ?? "—")
                    decisionValue("Projected zero", text: estimate?.exhaustion.map { Runway.clockLabel($0, now: now) } ?? "—")
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    value(tool.label + " remaining", text: estimate.map { String(format: "%.0f%%", $0.remaining) } ?? "—")
                    if !compact || estimate?.exhaustion != nil {
                        value("Projected zero", text: estimate?.exhaustion.map { Runway.clockLabel($0, now: now) } ?? "—")
                    }
                }
            }
            if let reading {
                if !compact {
                    Text("Quota read " + reading.date.formatted(date: .omitted, time: .standard) + Runway.ageLabel(reading, now: now))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(tool.label) · \(reading.minutes >= 1440 ? "\(reading.minutes / 1440)-day" : "\(reading.minutes / 60)-hour") window · resets " + reading.reset.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if compact || estimate?.exhaustion == nil {
                    Text(estimate?.message ?? "Learning quota burn").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(quota.unavailable).font(.caption).foregroundStyle(.secondary)
            }
            if let connection, tool == .claude, !compact {
                ClaudeConnectionControl(model: connection)
                if connection.status == .notConnected {
                    DetailSheet("Connect by hand instead") {
                        Text(ClaudeQuotaSource.relayHelp).textSelection(.enabled)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if compact {
                if let label = quota.accountLabel { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
            } else if quota.accountLabel != nil || estimate?.exhaustion != nil {
                DetailSheet("Account and estimate") {
                    if let label = quota.accountLabel { Text(label).textSelection(.enabled) }
                    if estimate?.exhaustion != nil { Text(estimate?.message ?? "Estimate from recent quota burn") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading).padding(embedded ? 0 : compact ? 10 : 18)
    }
    private func decisionValue(_ label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(text).font(.system(size: 29, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: text)
        }.accessibilityElement(children: .combine)
    }
    private func value(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(compact ? .system(size: 9, weight: .semibold) : .caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: compact ? 19 : 29, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
