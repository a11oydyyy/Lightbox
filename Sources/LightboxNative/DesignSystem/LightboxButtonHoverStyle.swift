import AppKit
import SwiftUI

// Hover glow color preference. Persisted in UserDefaults so it can be read both
// by the button style (every hover body) and by Settings without threading state
// through AppState. Default mode = system accent color.
// TODO: Fold these keys into the central LightboxSettingsStore.
enum LightboxGlowColor {
    static let modeKey = "Lightbox.hoverGlowMode"
    static let hexKey = "Lightbox.hoverGlowHex"
    static let systemMode = "system"
    static let customMode = "custom"

    static func resolved(mode: String, hex: String) -> Color {
        guard mode == customMode, let color = color(fromHex: hex) else {
            return .accentColor
        }
        return color
    }

    static func color(fromHex hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func hex(from color: Color) -> String {
        let nsColor = NSColor(color)
        let converted = nsColor.cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        )
        let components = converted?.components ?? nsColor.usingColorSpace(.sRGB)?.cgColor.components
        let red = Self.byteValue(components?.first ?? 0)
        let green = Self.byteValue(components?.dropFirst().first ?? 0)
        let blue = Self.byteValue(components?.dropFirst(2).first ?? 0)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func hex(from nsColor: NSColor) -> String {
        hex(from: Color(nsColor))
    }

    private static func byteValue(_ component: CGFloat) -> Int {
        Int((min(1, max(0, component)) * 255).rounded())
    }
}

struct LightboxButtonHoverStyle<S: Shape>: ButtonStyle {
    var shape: S
    var hoverScale: CGFloat = 1.025
    var pressedScale: CGFloat = 0.97
    var glowOpacity: Double = 0.20

    func makeBody(configuration: Configuration) -> some View {
        LightboxButtonHoverBody(
            configuration: configuration,
            shape: shape,
            hoverScale: hoverScale,
            pressedScale: pressedScale,
            glowOpacity: glowOpacity
        )
    }
}

private struct LightboxButtonHoverBody<S: Shape>: View {
    let configuration: ButtonStyle.Configuration
    var shape: S
    var hoverScale: CGFloat
    var pressedScale: CGFloat
    var glowOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LightboxGlowColor.modeKey) private var glowModeRaw = LightboxGlowColor.systemMode
    @AppStorage(LightboxGlowColor.hexKey) private var glowHex = ""
    @State private var hoverPoint: CGPoint?

    private var isHovered: Bool {
        hoverPoint != nil
    }

    private var glowColor: Color {
        LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex)
    }

    var body: some View {
        configuration.label
            .contentShape(shape)
            .background {
                GeometryReader { proxy in
                    if let hoverPoint {
                        let size = proxy.size
                        let unitPoint = UnitPoint(
                            x: min(1, max(0, hoverPoint.x / max(1, size.width))),
                            y: min(1, max(0, hoverPoint.y / max(1, size.height)))
                        )

                        shape
                            .fill(
                                // Tinted halo with normal blend so the cursor glow is
                                // visible on the light/white surfaces. Color is the
                                // user preference (system accent by default).
                                RadialGradient(
                                    colors: [
                                        glowColor.opacity(glowOpacity * 1.7),
                                        glowColor.opacity(glowOpacity * 0.55),
                                        .clear
                                    ],
                                    center: unitPoint,
                                    startRadius: 0,
                                    endRadius: max(size.width, size.height) * 0.95
                                )
                            )
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .overlay {
                if isHovered || configuration.isPressed {
                    shape
                        .stroke(glowColor.opacity(configuration.isPressed ? 0.32 : 0.46), lineWidth: 0.9)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(configuration.isPressed ? pressedScale : (isHovered ? hoverScale : 1))
            .shadow(
                // Constant radius/offset, fade via opacity only — animating the
                // blur radius re-rasterizes the shadow every frame.
                color: .black.opacity(isHovered ? 0.08 : 0),
                radius: 5,
                y: 2
            )
            .animation(MotionTokens.ifAllowed(MotionTokens.hover(isHovered), reduceMotion: reduceMotion), value: isHovered)
            .animation(MotionTokens.ifAllowed(MotionTokens.press(configuration.isPressed), reduceMotion: reduceMotion), value: configuration.isPressed)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                case .ended:
                    hoverPoint = nil
                }
            }
    }
}
