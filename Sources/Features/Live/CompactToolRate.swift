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
        let reading = Runway.priority(quota.readings, samples: quota.samples, now: now, horizon: quota.horizon)
        let estimate = reading.map { Runway.estimate($0, samples: quota.samples, now: now, horizon: quota.horizon) }
        CompactToolFace(
            title: tool.label,
            tint: accent,
            rate: CompactLiveCopy.rate(meter.hasRate, amount: meter.displayedRate, unit: meter.unit),
            remaining: CompactLiveCopy.remaining(estimate),
            remainingAvailable: estimate != nil,
            detail: expanded ? CompactLiveCopy.detail(reading: reading, estimate: estimate, now: now) : nil,
            accessibilityRate: meter.hasRate ? meter.speedText + " per " + meter.unit.label : "rate unavailable",
            expanded: expanded
        )
    }
}

private struct CompactToolFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var tint: Color
    var rate: String
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
            Text(rate).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: rate)
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
        .accessibilityLabel(title + ", " + accessibilityRate + ", " + remaining + " remaining")
        .accessibilityHint(expanded ? "Hides remaining details" : "Shows remaining details")
        .accessibilityAddTraits(.isButton)
    }
}
