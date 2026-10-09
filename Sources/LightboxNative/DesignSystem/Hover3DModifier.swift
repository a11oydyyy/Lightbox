import SwiftUI

// Retains the call-site API while keeping gallery geometry fixed under hover.
struct Hover3DModifier: ViewModifier {
    var isReduced = false
    var isEnabled = true
    var isFocused = false
    var isSelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @LightboxViewState private var isHovering = false

    private var showsOutline: Bool {
        isEnabled && (isFocused || isSelected || isHovering)
    }

    private var outlineAnimation: Animation {
        isFocused ? MotionTokens.chromeReveal : MotionTokens.feedback
    }

    /// Focus without selection sits further out, so a gap separates it from the
    /// graphite selection ring that hugs the card at the same tone.
    private var outlineOffset: CGFloat {
        isFocused && !isSelected ? 4 : 2
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: RadiusTokens.card + outlineOffset, style: .continuous)
                    .stroke(isSelected ? LightboxColorTokens.accent : LightboxColorTokens.secondaryText.opacity(isFocused ? 1 : (colorScheme == .light ? 0.42 : 0.35)), lineWidth: isFocused ? 2 : (isSelected ? LightboxControlMetrics.focusLineWidth : 1))
                    .padding(-outlineOffset)
                    .opacity(showsOutline ? 1 : 0)
                    // Keep one resident outline through selection and focus handoff.
                    // Scope feedback to the outline so the returning image stays solid.
                    .animation(MotionTokens.ifAllowed(outlineAnimation, reduceMotion: reduceMotion), value: showsOutline)
                    .animation(MotionTokens.ifAllowed(outlineAnimation, reduceMotion: reduceMotion), value: isFocused)
                    .animation(MotionTokens.ifAllowed(outlineAnimation, reduceMotion: reduceMotion), value: isSelected)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .onChange(of: isEnabled) { if !$0 { isHovering = false } }
    }
}

extension View {
    func hover3D(isReduced: Bool = false, isEnabled: Bool = true, isFocused: Bool = false, isSelected: Bool = false) -> some View {
        modifier(Hover3DModifier(isReduced: isReduced, isEnabled: isEnabled, isFocused: isFocused, isSelected: isSelected))
    }
}
