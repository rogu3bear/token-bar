import SwiftUI

struct ToolQuotaSummary: View {
    var tool: LiveTool
    var quota: ToolQuotaState
    var now: Date
    var compact = false
    var embedded = false
    var detailsOnly = false
    var connection: ClaudeConnectionModel? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let allowance = AccountAllowancePresentation(quota: quota, now: now)
        let reading = allowance.reading
        let estimate = allowance.estimate
        VStack(alignment: .leading, spacing: 10) {
            if !detailsOnly {
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
            }
            if let reading {
                if !detailsOnly {
                    if !compact {
                        Text("Quota read " + reading.date.formatted(date: .omitted, time: .standard) + Runway.ageLabel(reading, now: now))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(tool.label) · \(reading.minutes >= 1440 ? "\(reading.minutes / 1440)-day" : "\(reading.minutes / 60)-hour") window" + (reading.reset.map { " · resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? " · reset unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if detailsOnly, let zero = estimate?.exhaustion {
                    Text("Projected zero " + Runway.clockLabel(zero, now: now)).font(.callout)
                }
                if compact || detailsOnly || estimate?.exhaustion == nil {
                    Text(estimate?.message ?? "Learning quota burn").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(allowance.detail).font(.caption).foregroundStyle(.secondary)
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
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
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

/// Stable tool identity owns disclosure state; meter activity never owns this section.
struct AccountAllowanceSection: View {
    var tools: [LiveTool]
    var quota: (LiveTool) -> ToolQuotaState
    var now: Date
    var connection: ClaudeConnectionModel? = nil
    var sourcesKnown = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tools.isEmpty {
                if !sourcesKnown {
                    Text("Account allowances").font(.headline)
                    Text("No account sources detected yet. Open a supported tool to begin.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Account allowances").font(.headline)
                HStack(alignment: .top, spacing: 24) {
                    ForEach(tools) { tool in
                        AccountAllowanceDisclosure(tool: tool, quota: quota(tool), now: now,
                                                   connection: tool == .claude ? connection : nil)
                    }
                }
            }
        }.padding(.horizontal, 16)
    }
}

struct AccountAllowanceDisclosure: View {
    var tool: LiveTool
    var quota: ToolQuotaState
    var now: Date
    var connection: ClaudeConnectionModel? = nil
    var showsIdentity = true
    @State private var expanded = false
    var body: some View {
        let allowance = AccountAllowancePresentation(quota: quota, now: now)
        DisclosureGroup(isExpanded: $expanded) {
            ToolQuotaSummary(tool: tool, quota: quota, now: now, embedded: true, detailsOnly: true, connection: connection)
                .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsIdentity {
                        Text(tool.label).font(.subheadline.weight(.semibold))
                    }
                    Text(allowance.remaining).font(.title3.weight(.semibold)).monospacedDigit()
                    if allowance.estimate != nil { Text("remaining").font(.caption).foregroundStyle(.secondary) }
                }
                if allowance.estimate == nil || allowance.estimate?.remaining == 0 {
                    Text(allowance.qualifier).font(.caption).foregroundStyle(.secondary)
                }
                if let reading = allowance.reading {
                    Text("\(reading.minutes >= 1440 ? "\(reading.minutes / 1440)-day" : "\(reading.minutes / 60)-hour")" + (reading.reset.map { " · resets " + $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? " · reset unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Read " + reading.date.formatted(date: .omitted, time: .standard) + Runway.ageLabel(reading, now: now))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine)
        }
    }
}
