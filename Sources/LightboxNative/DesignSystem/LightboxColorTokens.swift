import AppKit
import SwiftUI

/// Neutral image-viewing surfaces; accents and Finder tag colors stay semantic.
/// Dynamic NSColors follow the view appearance, including an app-only theme.
enum LightboxColorTokens {
    static let accent = adaptive("accent", light: 0x246BCE, dark: 0x70A9FF)
    static let iconTeal = adaptive("icon-teal", light: 0x197D86, dark: 0x73BDC3)
    static let iconOrange = adaptive("icon-orange", light: 0xB77528, dark: 0xE0B06F)
    static func folderColor(_ tags: [String]) -> Color {
        MacColorTag.all.first(where: { tags.contains($0.name) })?.color ?? accent
    }
    static let iconGreen = adaptive("icon-green", light: 0x27805B, dark: 0x70C69C)
    static let iconPurple = adaptive("icon-purple", light: 0x8258BB, dark: 0xBC9BEA)
    static let iconRose = adaptive("icon-rose", light: 0xBE4B72, dark: 0xEF92AE)
    static let iconMusicRed = adaptive("icon-music-red", light: 0xFA243C, dark: 0xFF5B6E)
    static let iconCloudBlue = adaptive("icon-cloud-blue", light: 0x007AFF, dark: 0x64ADFF)
    static let iconAmber = adaptive("icon-amber", light: 0x9E721C, dark: 0xDCB75E)

    static func sidebarIcon(_ symbol: String) -> Color {
        if symbol.contains("music") { return iconRose }
        if symbol.contains("film") || symbol.contains("play") { return iconPurple }
        if symbol.contains("photo") { return iconAmber }
        if symbol.contains("arrow.down") { return iconGreen }
        if symbol.contains("drive") && !symbol.contains("cloud") { return iconPurple }
        return accent
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
