import SwiftUI

struct HoverIntentState {
    var trigger = false
    var panel = false
    var inside: Bool { trigger || panel }
    static let openDelay = 0.35
    static let closeDelay = 0.25
}
final class HoverIntent: ObservableObject {
    @Published var expanded = false
    private var state = HoverIntentState()
    private var pending: DispatchWorkItem?
    func hover(trigger: Bool? = nil, panel: Bool? = nil, reduceMotion: Bool) {
        if let trigger { state.trigger = trigger }
        if let panel { state.panel = panel }
        pending?.cancel()
        let open = state.inside
        guard open != expanded else { return }
        let work = DispatchWorkItem { [weak self] in self?.setOpen(open, reduceMotion: reduceMotion) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (open ? HoverIntentState.openDelay : HoverIntentState.closeDelay), execute: work)
    }
    func setOpen(_ open: Bool, reduceMotion: Bool) {
        pending?.cancel(); pending = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded = open }
        if !open { state.panel = false }
    }
    func cancel() { pending?.cancel(); pending = nil; state = HoverIntentState(); expanded = false }
    deinit { pending?.cancel() }
}
struct ActivityTriggerKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}
struct ContainedPopupLayout {
    var frame: CGRect
    var above: Bool
    static func fit(trigger: CGRect, container: CGSize) -> ContainedPopupLayout {
        let inset: CGFloat = 12, gap: CGFloat = 4
        let width = max(0, min(500, container.width - 2 * inset))
        let below = max(0, container.height - inset - trigger.maxY - gap)
        let above = max(0, trigger.minY - gap - inset)
        let useAbove = below < min(240, above)
        let height = min(380, useAbove ? above : below)
        let x = min(max(inset, trigger.midX - width / 2), max(inset, container.width - inset - width))
        let y = useAbove ? trigger.minY - gap - height : trigger.maxY + gap
        return ContainedPopupLayout(frame: CGRect(x: x, y: min(max(inset, y), max(inset, container.height - inset - height)), width: width, height: height), above: useAbove)
    }
}
