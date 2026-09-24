import SwiftUI
import QuartzCore

struct MenuBarDial {
    static let position = NSAttributedString.Key("TokenBar.dialPosition")
    static let available = NSAttributedString.Key("TokenBar.dialAvailable")
    static let accent = NSAttributedString.Key("TokenBar.dialAccent")
    static let identity = NSAttributedString.Key("TokenBar.dialIdentity")
    static func attributed(value: Double, minimum: Double, maximum: Double, available: Bool, accent: NSColor, identity: String) -> NSAttributedString {
        let position = fraction(value: value, minimum: minimum, maximum: maximum)
        let attachment = NSTextAttachment()
        attachment.image = image(value: position, minimum: 0, maximum: 1, available: available, accent: accent)
        attachment.bounds = NSRect(x: 0, y: -3, width: 26, height: 18)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([Self.position: position, Self.available: available, Self.accent: accent, Self.identity: identity], range: NSRange(location: 0, length: result.length))
        return result
    }
    /// AppKit degrees: the rail runs clockwise from 10 o'clock to 4 o'clock.
    static let sweepDegrees = 240.0
    static let startDegrees = 210.0
    static var endDegrees: Double { startDegrees - sweepDegrees }
    static func degrees(at fraction: Double) -> Double {
        startDegrees - fraction * sweepDegrees
    }
    static func fraction(value: Double, minimum: Double, maximum: Double) -> Double {
        guard value.isFinite, minimum.isFinite, maximum.isFinite, maximum > minimum else { return 0 }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }
    static func image(value: Double, minimum: Double, maximum: Double, available: Bool, accent: NSColor = .labelColor) -> NSImage {
        NSImage(size: NSSize(width: 26, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 13, y: 6), radius = 10.0
            func point(_ fraction: Double, _ radius: Double) -> NSPoint {
                let angle = degrees(at: fraction) * Double.pi / 180
                return NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: startDegrees, endAngle: endDegrees, clockwise: true)
            arc.lineWidth = 1.8; arc.lineCapStyle = .round; arc.stroke()
            if available {
                accent.setStroke()
                let active = NSBezierPath()
                active.appendArc(withCenter: center, radius: radius, startAngle: startDegrees,
                    endAngle: degrees(at: fraction(value: value, minimum: minimum, maximum: maximum)), clockwise: true)
                active.lineWidth = 1.8; active.lineCapStyle = .round; active.stroke()
            }
            NSColor.labelColor.setStroke()
            for tick in 0...4 {
                let path = NSBezierPath()
                path.move(to: point(Double(tick) / 4, 8)); path.line(to: point(Double(tick) / 4, 10))
                path.lineWidth = 1; path.stroke()
            }
            let needle = NSBezierPath()
            if available {
                needle.move(to: center)
                needle.line(to: point(fraction(value: value, minimum: minimum, maximum: maximum), 7.5))
            } else {
                needle.move(to: NSPoint(x: 10, y: 6)); needle.line(to: NSPoint(x: 16, y: 6))
            }
            accent.setStroke()
            needle.lineWidth = 1.6; needle.lineCapStyle = .round; needle.stroke()
            if available {
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
            }
            return true
        }
    }
}

/// Shared by the real status button and native previews. Only the dial position is
/// interpolated; text and accessibility always retain an actual reported value. Text
/// crossfades only between glyph-aligned lines; any other change swaps it at once.
final class MenuBarValueAnimator {
    private var target: NSAttributedString?
    private(set) var displayed: NSAttributedString?
    private var timer: Timer?
    private(set) var isAnimating = false
    static func signature(_ value: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: value)
        result.removeAttribute(.attachment, range: NSRange(location: 0, length: result.length))
        return result
    }
    static func frame(from: NSAttributedString, to: NSAttributedString, progress: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: to)
        var previous: [String: Double] = [:]
        from.enumerateAttribute(MenuBarDial.identity, in: NSRange(location: 0, length: from.length)) { value, range, _ in
            if let id = value as? String, from.attribute(MenuBarDial.available, at: range.location, effectiveRange: nil) as? Bool == true,
               let position = from.attribute(MenuBarDial.position, at: range.location, effectiveRange: nil) as? Double {
                previous[id] = position
            }
        }
        to.enumerateAttribute(MenuBarDial.identity, in: NSRange(location: 0, length: to.length)) { value, range, _ in
            guard let id = value as? String, let start = previous[id],
                  to.attribute(MenuBarDial.available, at: range.location, effectiveRange: nil) as? Bool == true,
                  let end = to.attribute(MenuBarDial.position, at: range.location, effectiveRange: nil) as? Double,
                  let color = to.attribute(MenuBarDial.accent, at: range.location, effectiveRange: nil) as? NSColor else { return }
            let fraction = start + (end - start) * min(1, max(0, progress))
            result.replaceCharacters(in: range, with: MenuBarDial.attributed(value: fraction, minimum: 0, maximum: 1, available: true, accent: color, identity: id))
        }
        return result
    }
    /// A crossfade blends two snapshots in place, so it reads as one line only when every glyph keeps
    /// its position: same length, only digits changed, same rendered width. A digit-count change,
    /// different words or proportional digits shift what follows, and blending would draw it twice.
    static func alignsForCrossfade(_ from: NSAttributedString, _ to: NSAttributedString) -> Bool {
        let old = Array(from.string.utf16), new = Array(to.string.utf16)
        guard old.count == new.count else { return false }
        let digits = UInt16(0x30)...UInt16(0x39)
        for (a, b) in zip(old, new) where a != b {
            guard digits.contains(a), digits.contains(b) else { return false }
        }
        return abs(from.size().width - to.size().width) < 0.5
    }
    func cancel() {
        timer?.invalidate(); timer = nil; isAnimating = false
    }
    deinit { timer?.invalidate() }
    func update(_ value: NSAttributedString, in view: NSView, reduceMotion: Bool, apply: @escaping (NSAttributedString) -> Void) {
        let changed = target.map { !Self.signature($0).isEqual(to: Self.signature(value)) } ?? true
        guard changed || (reduceMotion && isAnimating) else { return }
        let from = displayed
        cancel()
        target = value
        // Core Animation files every CATransition under kCATransition, whatever key it is added with.
        // Trust the reduceMotion parameter; do not re-check NSWorkspace mid-animation
        guard let from, !reduceMotion else {
            view.layer?.removeAnimation(forKey: kCATransition)
            displayed = value; apply(value); return
        }
        view.wantsLayer = true
        if Self.alignsForCrossfade(from, value) {
            let fade = CATransition()
            fade.type = .fade; fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(fade, forKey: kCATransition)
        } else {
            // The variable-length status item changes width, so blending would draw the line twice.
            view.layer?.removeAnimation(forKey: kCATransition)
        }
        let start = ProcessInfo.processInfo.systemUptime
        displayed = Self.frame(from: from, to: value, progress: 0)
        apply(displayed!)
        isAnimating = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self, weak view] timer in
            guard let self else { timer.invalidate(); return }
            guard let view else { self.cancel(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.35)
            // Do not re-check NSWorkspace during animation; motion decision was already made
            let finished = progress >= 1
            let eased = progress * progress * (3 - 2 * progress)
            let frame = finished ? value : Self.frame(from: from, to: value, progress: eased)
            self.displayed = frame; apply(frame)
            if finished {
                view.layer?.removeAnimation(forKey: kCATransition)
                self.cancel()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
struct MenuBarPreview: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: NSAttributedString
    func makeCoordinator() -> MenuBarValueAnimator { MenuBarValueAnimator() }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: value)
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        context.coordinator.update(value, in: field, reduceMotion: reduceMotion) { [weak field] in field?.attributedStringValue = $0 }
        // Break accessibility recursion: plain text only, no attachment characters
        let plainLabel = value.string.replacingOccurrences(of: "\u{FFFC}", with: "Speed dial")
        field.setAccessibilityLabel(plainLabel)
    }
    static func dismantleNSView(_ view: NSTextField, coordinator: MenuBarValueAnimator) { coordinator.cancel() }
}
