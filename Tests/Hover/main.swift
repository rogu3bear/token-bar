import Foundation
let size = CGSize(width: 900, height: 700)
for x in [0.0, 400, 850] {
    for y in [30.0, 300, 640] {
        let layout = ContainedPopupLayout.fit(trigger: CGRect(x: x, y: y, width: 100, height: 30), container: size)
        assert(layout.frame.minX >= ContainedPopupLayout.inset && layout.frame.maxX <= size.width - ContainedPopupLayout.inset)
        assert(layout.frame.minY >= ContainedPopupLayout.inset && layout.frame.maxY <= size.height - ContainedPopupLayout.inset)
        assert(layout.frame.height <= ContainedPopupLayout.maxHeight)
    }
}
assert(ContainedPopupLayout.fit(trigger: CGRect(x: 300, y: 600, width: 200, height: 30), container: size).above)
assert(!ContainedPopupLayout.fit(trigger: CGRect(x: 300, y: 100, width: 200, height: 30), container: size).above)
func advance(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let hover = HoverIntent()
hover.hover(trigger: true, reduceMotion: true)
advance(0.15); assert(!hover.expanded, "Brief pass must not open")
hover.hover(trigger: false, reduceMotion: true)
advance(0.4); assert(!hover.expanded, "Cancelled entry must stay closed")
hover.hover(trigger: true, reduceMotion: true)
advance(0.4); assert(hover.expanded)
hover.hover(trigger: false, reduceMotion: true)
advance(0.1)
hover.hover(panel: true, reduceMotion: true)
advance(0.3); assert(hover.expanded, "Moving into panel must cancel close")
hover.hover(panel: false, reduceMotion: true)
advance(0.1); assert(hover.expanded, "Exit grace must hold")
advance(0.2); assert(!hover.expanded, "Leaving both regions must close")
hover.hover(trigger: true, reduceMotion: true)
hover.cancel(); advance(0.4); assert(!hover.expanded)
print("PASS: window containment, edge placement, delayed entry, cancelled entry, trigger-to-panel transfer, exit grace, close and disappearance cancellation")

hover.hover(trigger: true, reduceMotion: true)
advance(0.4); assert(hover.expanded)
for _ in 0..<4 {
    hover.hover(panel: true, reduceMotion: true)
    hover.hover(panel: false, reduceMotion: true)
    advance(0.3)
    assert(hover.expanded, "Panel exit must not close while trigger remains hovered")
}
hover.hover(panel: true, reduceMotion: true)
hover.hover(trigger: false, reduceMotion: true)
advance(0.3); assert(hover.expanded, "Trigger exit must not close while panel remains hovered")
hover.hover(panel: false, reduceMotion: true)
advance(0.1)
hover.hover(trigger: true, reduceMotion: true)
advance(0.3); assert(hover.expanded, "Re-entry must cancel pending close")
hover.hover(trigger: false, reduceMotion: true)
advance(0.3); assert(!hover.expanded)
print("PASS: repeated panel boundary events, either-region retention, re-entry cancellation, final exit")
