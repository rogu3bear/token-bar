import SwiftUI

/// Glass belongs to the command layer. Readings and warning surfaces keep their
/// existing opaque backgrounds, and reduced transparency keeps solid controls.
struct GlassControlGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *), !reduceTransparency {
            GlassEffectContainer(spacing: 12) {
                content().buttonStyle(.glass)
            }
        } else {
            content().buttonStyle(.bordered)
        }
    }
}

struct ReportNavigationMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
