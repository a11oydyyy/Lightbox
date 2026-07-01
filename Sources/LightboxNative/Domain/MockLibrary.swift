import Foundation
import SwiftUI

struct MockPalette: Hashable, Sendable {
    var top: Color
    var bottom: Color
    var accent: Color

    static let imported: [MockPalette] = [
        MockPalette(top: .cyan.opacity(0.75), bottom: .indigo.opacity(0.72), accent: .white.opacity(0.24)),
        MockPalette(top: .mint.opacity(0.72), bottom: .teal.opacity(0.76), accent: .white.opacity(0.22)),
        MockPalette(top: .pink.opacity(0.70), bottom: .purple.opacity(0.70), accent: .white.opacity(0.22))
    ]
}

enum MockLibrary {
    static let importFallbackSizes: [CGSize] = [
        CGSize(width: 1200, height: 1600),
        CGSize(width: 1600, height: 1000),
        CGSize(width: 1100, height: 1320),
        CGSize(width: 1800, height: 2400)
    ]

    static let assets: [LightboxAsset] = [
        asset("wedding-arch-iris.jpg", 1400, 1820, ["Wedding", "Backdrop"], 0),
        asset("velvet-table-rose.png", 1600, 1080, ["Tablescape"], 1),
        asset("garden-entry-mist.jpg", 1100, 1500, ["Backdrop", "Garden"], 2),
        asset("editorial-bouquet-cream.jpg", 1400, 960, ["Floral"], 3),
        asset("coastal-ceremony-wide.jpg", 1800, 1120, ["Wedding", "Outdoor"], 4),
        asset("venue-candle-detail.jpg", 1100, 1460, ["Detail"], 5),
        asset("floral-wall-white.jpg", 1300, 1700, ["Backdrop", "Floral"], 6),
        asset("runner-linen-soft.jpg", 1400, 1000, ["Tablescape"], 7),
        asset("studio-rose-swatch.jpg", 1000, 1300, ["Floral", "Reference"], 8),
        asset("ceremony-aisle-glass.jpg", 1600, 1180, ["Wedding", "Glass"], 9),
        asset("product-closeup-petal.jpg", 980, 1280, ["Detail", "Reference"], 10),
        asset("soft-arch-evening.jpg", 1500, 1900, ["Backdrop"], 11),
        asset("trash-sample-duplicate.jpg", 1200, 1500, ["Reference"], 12, deleted: true)
    ]

    private static func asset(_ name: String, _ width: CGFloat, _ height: CGFloat, _ tags: [String], _ paletteIndex: Int, deleted: Bool = false) -> LightboxAsset {
        LightboxAsset(
            originalName: name,
            width: width,
            height: height,
            tags: tags,
            addedAt: Date(timeIntervalSince1970: TimeInterval(10_000 - paletteIndex)),
            palette: palettes[paletteIndex % palettes.count],
            deletedAt: deleted ? Date() : nil
        )
    }

    private static let palettes: [MockPalette] = [
        MockPalette(top: Color(red: 0.80, green: 0.86, blue: 0.96), bottom: Color(red: 0.50, green: 0.60, blue: 0.76), accent: .white.opacity(0.32)),
        MockPalette(top: Color(red: 0.67, green: 0.38, blue: 0.47), bottom: Color(red: 0.18, green: 0.18, blue: 0.22), accent: .white.opacity(0.18)),
        MockPalette(top: Color(red: 0.58, green: 0.70, blue: 0.62), bottom: Color(red: 0.30, green: 0.38, blue: 0.33), accent: .white.opacity(0.20)),
        MockPalette(top: Color(red: 0.88, green: 0.74, blue: 0.70), bottom: Color(red: 0.50, green: 0.38, blue: 0.42), accent: .white.opacity(0.22)),
        MockPalette(top: Color(red: 0.62, green: 0.76, blue: 0.82), bottom: Color(red: 0.24, green: 0.34, blue: 0.42), accent: .white.opacity(0.24)),
        MockPalette(top: Color(red: 0.73, green: 0.64, blue: 0.50), bottom: Color(red: 0.30, green: 0.25, blue: 0.21), accent: .white.opacity(0.18)),
        MockPalette(top: Color(red: 0.92, green: 0.92, blue: 0.90), bottom: Color(red: 0.54, green: 0.62, blue: 0.64), accent: .white.opacity(0.36)),
        MockPalette(top: Color(red: 0.76, green: 0.78, blue: 0.68), bottom: Color(red: 0.36, green: 0.40, blue: 0.35), accent: .white.opacity(0.18)),
        MockPalette(top: Color(red: 0.88, green: 0.58, blue: 0.62), bottom: Color(red: 0.45, green: 0.25, blue: 0.32), accent: .white.opacity(0.24)),
        MockPalette(top: Color(red: 0.72, green: 0.78, blue: 0.84), bottom: Color(red: 0.34, green: 0.38, blue: 0.46), accent: .white.opacity(0.20)),
        MockPalette(top: Color(red: 0.92, green: 0.70, blue: 0.74), bottom: Color(red: 0.55, green: 0.38, blue: 0.45), accent: .white.opacity(0.20)),
        MockPalette(top: Color(red: 0.68, green: 0.72, blue: 0.78), bottom: Color(red: 0.27, green: 0.30, blue: 0.38), accent: .white.opacity(0.20)),
        MockPalette(top: Color(red: 0.44, green: 0.48, blue: 0.52), bottom: Color(red: 0.18, green: 0.20, blue: 0.22), accent: .white.opacity(0.12))
    ]
}
