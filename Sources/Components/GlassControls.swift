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
