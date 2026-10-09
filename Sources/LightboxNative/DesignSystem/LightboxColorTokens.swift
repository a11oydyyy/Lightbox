import AppKit
import SwiftUI

/// Neutral image-viewing surfaces; accents and Finder tag colors stay semantic.
/// Dynamic NSColors follow the view appearance, including an app-only theme.
enum LightboxColorTokens {
    /// Graphite: the single interaction color. Neutral, so photographs and
    /// Finder tags carry all of the hue in the window.
    static let accent = adaptive("accent", light: 0x2C2C2E, dark: 0xE8E8EB)
    /// Text and symbols placed on an `accent` fill.
    static let accentForeground = adaptive("accent-foreground", light: 0xFFFFFF, dark: 0x1C1C1E)
    /// Untagged folder and location symbols in the sidebar and gallery.
    static let glyph = adaptive("glyph", light: 0x86868C, dark: 0x8E8E95)
    static func folderColor(_ tags: [String]) -> Color {
        MacColorTag.all.first(where: { tags.contains($0.name) })?.color ?? glyph
    }

    // Fixed sidebar locations carry Apple system hues, as in System Settings.
    // User folders stay `glyph` so Finder tags remain the only folder color.
    static let locationIndigo = adaptive("location-indigo", light: 0x5856D6, dark: 0x5E5CE6)
    static let locationTeal = adaptive("location-teal", light: 0x30B0C7, dark: 0x40C8E0)
    static let locationBlue = adaptive("location-blue", light: 0x007AFF, dark: 0x0A84FF)
    static let locationGreen = adaptive("location-green", light: 0x34C759, dark: 0x30D158)
    static let locationOrange = adaptive("location-orange", light: 0xFF9500, dark: 0xFF9F0A)
    static let locationPurple = adaptive("location-purple", light: 0xAF52DE, dark: 0xBF5AF2)
    static let locationPink = adaptive("location-pink", light: 0xFF2D55, dark: 0xFF375F)
    static let locationCyan = adaptive("location-cyan", light: 0x32ADE6, dark: 0x64D2FF)
    static let locationGray = adaptive("location-gray", light: 0x8E8E93, dark: 0x98989D)

    /// Hue for a `SidebarLocationID.systemImage`; nil for folders and other symbols.
    static func locationColor(_ symbol: String) -> Color? {
        switch symbol {
        case "app": locationIndigo
        case "desktopcomputer": locationTeal
        case "doc": locationBlue
        case "arrow.down.circle": locationGreen
        case "photo.on.rectangle": locationOrange
        case "film": locationPurple
        case "music.note": locationPink
        case "icloud": locationCyan
        case "externaldrive": locationGray
        default: nil
        }
    }

    static let canvas = adaptive("canvas", light: 0xF7F7F8, dark: 0x1C1C1E)
    static let sidebar = adaptive("sidebar", light: 0xEEEEF0, dark: 0x252527)
    static let navigationSelection = adaptive("navigation-selection", light: 0xDDDDDF, dark: 0x3B3B3E)
    static let control = adaptive("control", light: 0xFFFFFF, dark: 0x323234)
    static let inspection = adaptive("inspection", light: 0xF2F2F3, dark: 0x18181A)
    static let currentLocationText = adaptive("current-location", light: 0x000000, dark: 0xFFFFFF)
    static let primaryText = adaptive("primary-text", light: 0x242426, dark: 0xF0F0F2)
    static let secondaryText = adaptive("secondary-text", light: 0x545458, dark: 0xC5C5CA)
    static let mutedText = adaptive("muted-text", light: 0x65656B, dark: 0xA4A4AC)
    static let disabledText = adaptive("disabled-text", light: 0x898991, dark: 0x777780)
    static let border = adaptive("border", light: 0xD8D8DD, dark: 0x48484F)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Lightbox.\(name)")) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
