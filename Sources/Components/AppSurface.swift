import SwiftUI

/// The live popover's neutral canvas and module treatment, shared by every host.
enum AppSurface {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 17/255, green: 19/255, blue: 20/255, alpha: 1)
            : NSColor(srgbRed: 246/255, green: 247/255, blue: 248/255, alpha: 1)
    })
    static let radius: CGFloat = 12
}

private struct ModuleSurface: ViewModifier {
    var padding: CGFloat
    var warning: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(scheme == .dark ? Color.primary.opacity(0.035) : Color.white,
                        in: RoundedRectangle(cornerRadius: AppSurface.radius))
            .overlay(RoundedRectangle(cornerRadius: AppSurface.radius)
                .strokeBorder(warning ? Color.orange.opacity(0.5) : Color.primary.opacity(contrast == .increased ? 0.3 : 0.08)))
    }
}

extension View {
    func appCanvas() -> some View { background(AppSurface.canvas) }
    func moduleSurface(padding: CGFloat = 16, warning: Bool = false) -> some View {
        modifier(ModuleSurface(padding: padding, warning: warning))
    }
}
