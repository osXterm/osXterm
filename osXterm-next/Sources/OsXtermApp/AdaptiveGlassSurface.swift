import SwiftUI

/// Applies the macOS 26 glass material only where the interface benefits from
/// a navigation or control surface. The standard view background remains in
/// place for people who ask macOS to reduce transparency.
private struct AdaptiveGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
        } else {
            content.glassEffect()
        }
    }
}

extension View {
    func osXtermGlassSurface() -> some View {
        modifier(AdaptiveGlassSurface())
    }
}
