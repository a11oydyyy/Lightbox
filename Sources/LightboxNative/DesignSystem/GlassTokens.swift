import SwiftUI

enum GlassTokens {
    static let sidebarOpacity: Double = 0.78
    static let controlOpacity: Double = 0.72
    static let strokeOpacity: Double = 0.18
    static let shadowOpacity: Double = 0.14

    static func floatingCapsuleMaterialOpacity(_ glassOpacity: Double) -> Double {
        glassOpacity
    }

    static func floatingCapsuleFillOpacity(_ glassOpacity: Double, colorScheme: ColorScheme) -> Double {
        glassOpacity * (colorScheme == .dark ? 0.18 : 0.24)
    }

    static func floatingCapsuleStrokeOpacity(_ glassOpacity: Double) -> Double {
        0.025 + glassOpacity * 0.08
    }

    static func floatingCapsuleShadowOpacity(_ glassOpacity: Double) -> Double {
        0.035 + glassOpacity * 0.09
    }
}

private struct LightboxGlassOpacityKey: EnvironmentKey {
    static let defaultValue = LightboxSettingsStore.defaultGlassOpacity
}

extension EnvironmentValues {
    var lightboxGlassOpacity: Double {
        get { self[LightboxGlassOpacityKey.self] }
        set { self[LightboxGlassOpacityKey.self] = LightboxSettingsStore.clampGlassOpacity(newValue) }
    }
}

extension View {
    func lightboxGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(LightboxGlassModifier(shape: shape, interactive: interactive))
    }
}

private struct LightboxGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.lightboxGlassOpacity) private var glassOpacity

    var shape: S
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(.ultraThinMaterial.opacity(glassOpacity * 0.34), in: shape)
                .glassEffect(.regular.interactive(interactive), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(GlassTokens.strokeOpacity * glassOpacity), lineWidth: 1)
                }
        } else {
            content
                .background(.ultraThinMaterial.opacity(glassOpacity), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(GlassTokens.strokeOpacity), lineWidth: 1)
                }
        }
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
