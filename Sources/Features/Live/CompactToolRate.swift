import SwiftUI

/// Compact speed dial for popover rows - smaller version of dashboard gauge
struct CompactSpeedDial: View {
    var value: Double
    var available: Bool
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let startDegrees = 150.0
    private static let sweepDegrees = 240.0
    private static func degrees(at fraction: Double) -> Double { startDegrees + fraction * sweepDegrees }
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.65)
            let radius = min(size.width, size.height) * 0.42
            func point(_ fraction: Double, _ distance: Double) -> CGPoint {
                let angle = Self.degrees(at: fraction) * .pi / 180
                return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            }
            var rail = Path()
            rail.addArc(center: center, radius: radius, startAngle: .degrees(Self.startDegrees), 
                       endAngle: .degrees(Self.startDegrees + Self.sweepDegrees), clockwise: false)
            context.stroke(rail, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if available {
                var active = Path()
                active.addArc(center: center, radius: radius, startAngle: .degrees(Self.startDegrees),
                             endAngle: .degrees(Self.degrees(at: value)), clockwise: false)
                context.stroke(active, with: .color(tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                let angle = Self.degrees(at: value)
                func polar(_ degrees: Double, _ distance: Double) -> CGPoint {
                    let a = degrees * .pi / 180
                    return CGPoint(x: center.x + cos(a) * distance, y: center.y + sin(a) * distance)
                }
                let tip = polar(angle, radius - 5)
                let left = polar(angle + 90, 1.5), right = polar(angle - 90, 1.5)
                let tail = polar(angle + 180, radius * 0.35)
                var needle = Path()
                needle.move(to: tip); needle.addLine(to: left); needle.addLine(to: tail)
                needle.addLine(to: right); needle.closeSubpath()
                context.fill(needle, with: .color(tint))
            }
        }
        .frame(width: 22, height: 16)
        .animation(reduceMotion ? nil : .smooth(duration: 0.8), value: value)
        .accessibilityHidden(true)
    }
}

/// One popover row: name, rate, remaining. Click reveals reset and projected zero.
struct CompactToolRate: View {
    var tool: LiveTool
    @Bindable var meter: Tachometer
    var quota: ToolQuotaState
    var now: Date
    var expanded = false
    var warning: String? = nil
    @Environment(\.appAccent) private var accent
    var body: some View {
        let allowance = AccountAllowancePresentation(quota: quota, now: now)
        let activity = CompactLiveCopy.activity(meter)
        let dialValue = meter.hasRate && meter.scale > meter.minimum 
            ? min(1, max(0, (meter.rate - meter.minimum) / (meter.scale - meter.minimum))) : 0.5
        CompactToolFace(
            title: tool.label,
            tint: warning == nil ? accent : .orange,
            rate: CompactLiveCopy.rateHeadline(activity: activity, available: meter.hasRate, amount: meter.displayedRate, unit: meter.unit),
            activity: activity,
            remaining: allowance.remaining,
            remainingAvailable: allowance.estimate != nil,
            detail: warning ?? (allowance.estimate == nil ? allowance.qualifier : nil),
            accessibilityRate: CompactLiveCopy.spokenRate(activity: activity, available: meter.hasRate, amount: meter.displayedRate, unit: meter.unit),
            dialValue: dialValue,
            dialAvailable: meter.hasRate,
            expanded: expanded
        )
    }
}

private struct CompactToolFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var tint: Color
    var rate: String?
    var activity: String
    var remaining: String
    var remainingAvailable: Bool
    var detail: String?
    var accessibilityRate: String
    var dialValue: Double = 0.5
    var dialAvailable: Bool = false
    var expanded: Bool
    var body: some View {
        chrome(content: numbers)
    }
    private var remainingNumber: some View {
        Text(remaining).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: remaining)
            .foregroundStyle(remainingAvailable ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .frame(minWidth: 44, alignment: .trailing)
    }
    private var numbers: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint).frame(width: 14, height: 14)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(activity).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let rate {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        CompactSpeedDial(value: dialValue, available: dialAvailable, tint: tint)
                        Text(rate).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: rate)
                    }
                    Text(rate == "—" ? "Speed unavailable" : "Output speed").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                remainingNumber
                Text("remaining").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .animation(InteractionMotion.disclosure(reduceMotion), value: expanded)
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
        .accessibilityLabel(title + ", " + accessibilityRate + ", " + (remainingAvailable ? remaining + " remaining" : "remaining unavailable") + (detail.map { ", " + $0 } ?? ""))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Hides provider details" : "Shows provider details")
        .accessibilityAddTraits(.isButton)
    }
}
