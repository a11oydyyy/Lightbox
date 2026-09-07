import AppKit
import SwiftUI

// Color conversion retained for existing import and round-trip compatibility.
enum LightboxGlowColor {
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

/// Shared feedback for ordinary controls: neutral hover/press, without geometry changes.
struct LightboxButtonHoverStyle<S: Shape>: ButtonStyle {
    var shape: S

    func makeBody(configuration: Configuration) -> some View {
        LightboxButtonHoverBody(configuration: configuration, shape: shape)
    }
}

private struct LightboxButtonHoverBody<S: Shape>: View {
    let configuration: ButtonStyle.Configuration
    var shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .background {
                shape.fill(LightboxColorTokens.primaryText.opacity(
                    !isEnabled ? 0 : configuration.isPressed ? LightboxControlMetrics.pressedOpacity
                        : isHovered ? LightboxControlMetrics.hoverOpacity : 0
                ))
                .allowsHitTesting(false)
            }
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isHovered)
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}
