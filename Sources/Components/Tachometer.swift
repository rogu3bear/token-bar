import Observation
import SwiftUI
import Combine

enum RateUnit: String, CaseIterable, Identifiable {
    case second = "s", minute = "m", hour = "h"
    var id: String { rawValue }
    var multiplier: Double { self == .second ? 1 : self == .minute ? 60 : 3600 }
    var label: String { self == .second ? "second" : self == .minute ? "minute" : "hour" }
}
struct RateBounds: Equatable {
    var lower: Double
    var upper: Double
    static func fitting(_ values: [Double]) -> RateBounds {
        let low = values.min() ?? 0, high = values.max() ?? 0
        guard high > 0 else { return RateBounds(lower: 0, upper: 100) }
        let margin = max(high * 0.2, (high - low) * 0.2)
        let target = max(1, high - low + 2 * margin) / 4
        let magnitude = pow(10, floor(log10(target)))
        let step = ([1.0, 2, 5, 10].first { $0 * magnitude >= target } ?? 10) * magnitude
        return RateBounds(lower: max(0, floor((low - margin) / step) * step),
                          upper: ceil((high + margin) / step) * step)
    }
}

@Observable final class Tachometer {
    var rate: Double = 0
    var rawRate: Double = 0
    var peak: Double = 0
    var scale: Double = 100
    var minimum: Double = 0
    var unit: RateUnit { didSet {
        if let unitDefaults, let unitKey { unitDefaults.set(unit.rawValue, forKey: unitKey) }
    } }
    private let unitDefaults: UserDefaults?
    private let unitKey: String?
    /// Only the owning app injects persistence; standalone meters and demos remain isolated.
    init(tool: LiveTool? = nil, defaults: UserDefaults? = nil) {
        unitDefaults = defaults
        unitKey = tool.map { "dashboard.rateUnit." + $0.rawValue }
        unit = unitKey.flatMap { defaults?.string(forKey: $0) }.flatMap(RateUnit.init(rawValue:)) ?? .second
    }
    @ObservationIgnored private var recentRates: [(Date, Double)] = []
    var displayedRate: Double { rawRate * unit.multiplier }
    var lastReport: Date?
    var models: [String] = []
    var activity = ActivitySnapshot()
    var reportingCount = 0
    var hasRate = false
    var runningCount: Int { activity.running.count }
    var status: String {
        if runningCount > 0 {
            let chats = activity.chatCount, agents = activity.agentCount
            var label = "\(chats) chat\(chats == 1 ? "" : "s") · \(agents) agent\(agents == 1 ? "" : "s")"
            if activity.unknownCount > 0 { label += " · \(activity.unknownCount) unknown" }
            if activity.uncertain > 0 { label += " · \(activity.uncertain) unconfirmed" }
            return label
        }
        if activity.uncertain > 0 { return "\(activity.uncertain) unconfirmed · details" }
        return activity.readAt == nil ? "Reading live activity…" : "No running tasks observed"
    }
    func apply(_ snapshot: ActivitySnapshot) { activity = snapshot; tick() }
    func tick(now: Date = Date()) {
        let samples = activity.freshMeasurements(at: now)
        let value = samples.reduce(0) { $0 + $1.rate }
        let fresh = !samples.isEmpty
        if hasRate != fresh { hasRate = fresh }
        if reportingCount != samples.count { reportingCount = samples.count }
        let latest = samples.map(\.date).max()
        if lastReport != latest { lastReport = latest }
        let modelNames = Array(Set(samples.map(\.model))).filter { !$0.isEmpty }.sorted()
        if models != modelNames { models = modelNames }
        if value != rawRate { rawRate = value }
        if rate != value && (value == 0 || abs(value - rate) >= max(0.5, rate * 0.015)) { rate = value }
        if value > peak { peak = value }
        recentRates.removeAll { now.timeIntervalSince($0.0) > 30 }
        if fresh { recentRates.append((now, value)) } else { recentRates.removeAll() }
        let bounds = RateBounds.fitting(recentRates.map { $0.1 })
        if minimum != bounds.lower { minimum = bounds.lower }
        if scale != bounds.upper { scale = bounds.upper }
    }
}

struct RPMGauge: View {
    @Environment(\.appAccent) private var accent
    var value: Double
    var minimum: Double
    var maximum: Double
    var measured: Double
    var hasRate: Bool
    @Binding var unit: RateUnit
    var compactLayout = false
    var showsReadout = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let center = CGPoint(x: width / 2, y: height * 0.59)
            let radius = min(width * 0.44, height * 0.52)
            let fraction = min(1, max(0, (value - minimum) / max(1, maximum - minimum)))
            AnimatedRateDial(fraction: fraction, width: width, height: height, minimum: minimum, maximum: maximum, unit: unit, showsLabels: !compactLayout)
                .animation(reduceMotion ? nil : .smooth(duration: 1.2, extraBounce: 0), value: fraction)
                .animation(reduceMotion ? nil : .smooth(duration: 1.2, extraBounce: 0), value: minimum)
                .animation(reduceMotion ? nil : .smooth(duration: 1.2, extraBounce: 0), value: maximum)
            if showsReadout {
                RateReadout(measured: measured, hasRate: hasRate, unit: $unit, size: compactLayout ? 34 : 46)
                    .position(x: center.x, y: center.y + radius * 0.48)
            }
        }.frame(minHeight: 180)
    }
}

/// The same measured value and unit binding, independent of the dial geometry.
struct RateReadout: View {
    var measured: Double
    var hasRate: Bool
    @Binding var unit: RateUnit
    var size: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                RollingRate(value: measured * unit.multiplier, available: hasRate, size: size,
                            compactThousands: unit != .second, unit: unit)
                Text("tok/" + unit.rawValue)
                    .font(.system(size: size * 0.6, weight: .medium)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 7) {
                Text("Output tokens per").font(.caption).foregroundStyle(.secondary)
                Picker("Rate unit", selection: $unit) {
                    ForEach(RateUnit.allCases) { choice in Text(choice.rawValue).tag(choice) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                    .accessibilityLabel("Output tokens per " + unit.label)
            }
        }
    }
}

struct AnimatedRateDial: View, Animatable {
    @Environment(\.appAccent) private var accent
    var fraction: Double
    var width: Double
    var height: Double
    var minimum: Double
    var maximum: Double
    var unit: RateUnit
    var showsLabels = true
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(fraction, AnimatablePair(minimum, maximum)) }
        set { fraction = newValue.first; minimum = newValue.second.first; maximum = newValue.second.second }
    }
    var body: some View {
        let center = CGPoint(x: width / 2, y: height * 0.59)
        let radius = min(width * 0.44, height * 0.52)
        Canvas { context, _ in
                func point(_ degrees: Double, _ distance: Double) -> CGPoint {
                    let angle = degrees * .pi / 180
                    return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                }
                var rail = Path()
                rail.addArc(center: center, radius: radius, startAngle: .degrees(150), endAngle: .degrees(390), clockwise: false)
                context.stroke(rail, with: .color(.primary.opacity(0.09)), style: StrokeStyle(lineWidth: showsLabels ? 14 : 6, lineCap: .round))
                var active = Path()
                active.addArc(center: center, radius: radius, startAngle: .degrees(150), endAngle: .degrees(150 + fraction * 240), clockwise: false)
                context.stroke(active, with: .color(accent), style: StrokeStyle(lineWidth: showsLabels ? 14 : 6, lineCap: .round))
                for tick in stride(from: 0, through: 40, by: showsLabels ? 2 : 10) {
                    let angle = 150 + Double(tick) * 6
                    let major = tick % 10 == 0
                    var line = Path()
                    line.move(to: point(angle, radius - 17)); line.addLine(to: point(angle, radius - (major ? 33 : 25)))
                    context.stroke(line, with: .color(.primary.opacity(major ? 0.75 : 0.25)), lineWidth: major ? 2 : 1)
                    if major && showsLabels {
                        let amount = (minimum + (maximum - minimum) * Double(tick) / 40) * unit.multiplier
                        let label = amount >= 1_000_000 ? String(format: "%.1fM", amount / 1_000_000) : amount >= 1000 ? String(format: "%.1fK", amount / 1000) : String(format: "%.0f", amount)
                        context.draw(Text(label).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(.secondary), at: point(angle, radius - 52))
                    }
                }
                let angle = 150 + fraction * 240
                let tip = point(angle, radius - 41)
                let left = point(angle + 90, 4), right = point(angle - 90, 4), tail = point(angle + 180, 18)
                var needle = Path(); needle.move(to: tip); needle.addLine(to: left); needle.addLine(to: tail); needle.addLine(to: right); needle.closeSubpath()
                context.fill(needle, with: .color(accent))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(accent), lineWidth: 2)
            }
    }
}

struct RollingRate: View {
    var value: Double
    var available: Bool
    var size: Double
    var compactThousands = false
    var unit: RateUnit = .second
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if available && compactThousands && value >= 1000 {
                Text("~" + RateDisplay.compact(value))
                    .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
                    .frame(width: size * 5.2, height: size * 1.25)
            } else if available && !reduceMotion {
                RateOdometer(value: value.rounded(), size: size)
                    .animation(.smooth(duration: 1.2, extraBounce: 0), value: value.rounded())
            } else {
                Text(available ? "~" + String(format: "%.0f", value) : "—")
                    .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(width: size * 5.2, height: size * 1.25)
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: available)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(available ? "Approximately " + String(format: "%.0f", value) + " output tokens per " + unit.label : "Awaiting token reports")
    }
}

// SwiftUI interpolates the numeric value each display frame; glyphs move vertically
// within clipped columns instead of replacing the entire number on report arrival.
struct RateOdometer: View, Animatable {
    var value: Double
    var size: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View {
        Canvas { context, bounds in
            let safe = max(0, value)
            let count = max(3, String(format: "%.0f", ceil(safe)).count)
            let width = min(size * 0.65, bounds.width / Double(count + 1))
            let height = bounds.height
            let start = (bounds.width - width * Double(count + 1)) / 2
            let font = Font.system(size: min(size, width / 0.65), weight: .semibold, design: .rounded).monospacedDigit()
            context.draw(Text("~").font(font), at: CGPoint(x: start + width / 2, y: height / 2))
            for column in 0..<count {
                let place = pow(10, Double(count - column - 1))
                let position = safe / place
                let whole = floor(position)
                let lower = floor(safe).truncatingRemainder(dividingBy: place)
                let fraction = lower >= place - 1 ? safe - floor(safe) : 0
                let digit = Int(whole.truncatingRemainder(dividingBy: 10))
                let x = start + width * Double(column + 1)
                var clipped = context
                clipped.clip(to: Path(CGRect(x: x, y: 0, width: width, height: height)))
                let leading = safe < place && column < count - 1
                if !leading {
                    clipped.draw(Text(String(digit)).font(font), at: CGPoint(x: x + width / 2, y: height / 2 - fraction * height))
                }
                if !leading || safe >= place - 1 {
                    clipped.draw(Text(String((digit + 1) % 10)).font(font), at: CGPoint(x: x + width / 2, y: height * 1.5 - fraction * height))
                }
            }
        }.frame(width: size * 5.2, height: size * 1.25)
    }
}

enum RateDisplay {
    static func compact(_ value: Double) -> String {
        let divisor = value >= 999_950 ? 1_000_000.0 : 1000.0
        let suffix = divisor == 1000 ? "k" : "M"
        let number = String(format: "%.1f", value / divisor)
        return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + suffix
    }
}
