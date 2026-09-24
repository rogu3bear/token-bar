import SwiftUI

/// Click feedback is quicker than a change of selection; expansion has room to settle.
/// Live measurement interpolation keeps its separate, data-driven timing.
enum InteractionMotion {
    static func press(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeOut(duration: 0.09)
    }
    static func selection(_ reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)
    }
    static func disclosure(_ reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    }
}

/// Custom module/navigation buttons share a restrained press response.
/// System glass and bordered buttons retain their platform behavior.
struct PressFeedbackStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .background(Color.primary.opacity(pressed ? 0.06 : 0), in: RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .animation(InteractionMotion.press(reduceMotion), value: pressed)
    }
}

/// Measure the full content throughout an interruption so the same view can
/// reveal or retract from its current height without reflowing or remounting.
struct DisclosureReveal<Content: View>: View {
    var expanded: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureLayout(progress: expanded ? 1 : 0) { content() }
            .clipped()
            .opacity(expanded ? 1 : 0)
            .animation(InteractionMotion.disclosure(reduceMotion), value: expanded)
            .allowsHitTesting(expanded)
            .disabled(!expanded)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!expanded)
    }
}

struct DisclosureLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
