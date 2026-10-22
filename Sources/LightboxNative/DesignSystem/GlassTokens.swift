import SwiftUI

enum GlassTokens {
    static let sidebarOpacity: Double = 0.78
    static let controlOpacity: Double = 0.72
    static let strokeOpacity: Double = 0.18
    static let shadowOpacity: Double = 0.14

    static func sidebarStrokeOpacity(_ glassOpacity: Double) -> Double {
        0.45 + glassOpacity * 0.20
    }

    static func sidebarShadowOpacity(_ glassOpacity: Double) -> Double {
        0.015 + glassOpacity * 0.035
    }

    static func floatingCapsuleMaterialOpacity(_ glassOpacity: Double) -> Double {
        glassOpacity
    }

    static func floatingCapsuleFillOpacity(_ glassOpacity: Double, colorScheme: ColorScheme) -> Double {
        glassOpacity * (colorScheme == .dark ? 0.76 : 0.82)
    }

    static func floatingCapsuleStrokeOpacity(_ glassOpacity: Double) -> Double {
        0.025 + glassOpacity * 0.08
    }

    /// macOS 26 floating capsules: canvas tint over system glass, enough to
    /// keep labels legible over busy images. The glass still turns dark over
    /// dark photos, so what sits on it uses hierarchical (adaptive) styles.
    static let floatingCapsuleTintOpacity: Double = 0.6

    /// Gallery popovers: canvas over the popover's glass. Their small gray
    /// labels sit right over photos, so they need more than the capsules.
    static let popoverTintOpacity: Double = 0.88

    static func floatingCapsuleShadowOpacity(_ glassOpacity: Double) -> Double {
        // System glass draws its own depth on macOS 26 and later.
        if #available(macOS 26.0, *) { return 0 }
        return 0.035 + glassOpacity * 0.09
    }
}

private struct LightboxGlassOpacityKey: EnvironmentKey {
    static let defaultValue = LightboxSettingsStore.defaultGlassOpacity
}

extension EnvironmentValues {
    var lightboxGlassOpacity: Double {
        get { self[LightboxGlassOpacityKey.self] }
        set { self[LightboxGlassOpacityKey.self] = min(1, max(0, newValue)) }
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    /// A gallery popover's content: tinted with the canvas so its labels stay
    /// legible over dark or busy photos.
    func lightboxPopoverSurface() -> some View {
        background(LightboxColorTokens.canvas.opacity(GlassTokens.popoverTintOpacity))
    }
}
