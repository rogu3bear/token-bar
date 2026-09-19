import SwiftUI

/// One popover row: name, rate, remaining. Click reveals reset and projected zero.
struct CompactToolRate: View {
    var tool: LiveTool
    @Bindable var meter: Tachometer
    var quota: ToolQuotaState
    var now: Date
    var expanded = false
    @Environment(\.appAccent) private var accent
    var body: some View {
        let allowance = AccountAllowancePresentation(quota: quota, now: now)
        let activity = CompactLiveCopy.activity(meter)
        let idle = activity == "Idle"
        CompactToolFace(
            title: tool.label,
            tint: accent,
            rate: idle ? "Idle" : CompactLiveCopy.rate(meter.hasRate, amount: meter.displayedRate, unit: meter.unit),
            activity: activity,
            remaining: allowance.remaining,
            remainingAvailable: allowance.estimate != nil,
            detail: expanded ? allowance.detail : allowance.estimate == nil ? allowance.qualifier : nil,
            accessibilityRate: CompactLiveCopy.spokenRate(activity: activity, available: meter.hasRate, amount: meter.displayedRate, unit: meter.unit),
            expanded: expanded
        )
    }
}

private struct CompactToolFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var tint: Color
    var rate: String
    var activity: String
    var remaining: String
    var remainingAvailable: Bool
    var detail: String?
    var accessibilityRate: String
    var expanded: Bool
    var body: some View {
        chrome(content: numbers)
    }
    private var numbers: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(rate).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: rate)
                if activity != "Idle" { Text(activity + (rate == "—" ? " · rate unavailable" : "")).font(.caption).foregroundStyle(.secondary) }
            }
            Text(remaining).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: remaining)
                .foregroundStyle(remainingAvailable ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
    private func chrome<Content: View>(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", " + accessibilityRate + ", " + remaining + " remaining" + (detail.map { ", " + $0 } ?? ""))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Hides remaining details" : "Shows remaining details")
        .accessibilityAddTraits(.isButton)
    }
}
