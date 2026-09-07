import SwiftUI

// Retains the call-site API while keeping gallery geometry fixed under hover.
struct Hover3DModifier: ViewModifier {
    var isReduced = false
    var isEnabled = true
    var isFocused = false
    var isSelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: RadiusTokens.card + 2, style: .continuous)
                    .stroke(isFocused && isSelected ? LightboxColorTokens.accent : LightboxColorTokens.secondaryText.opacity(isFocused ? 1 : (colorScheme == .light ? 0.85 : 0.35)), lineWidth: isFocused ? 2 : 1)
                    .padding(-2)
                    .opacity(isEnabled && (isFocused || (isHovering && !isSelected)) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .onChange(of: isEnabled) { if !$0 { isHovering = false } }
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isHovering)
    }
}

extension View {
    func hover3D(isReduced: Bool = false, isEnabled: Bool = true, isFocused: Bool = false, isSelected: Bool = false) -> some View {
        modifier(Hover3DModifier(isReduced: isReduced, isEnabled: isEnabled, isFocused: isFocused, isSelected: isSelected))
    }
}
