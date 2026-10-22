import SwiftUI

enum GalleryThumbnailSizing {
    static let minimumWidth: CGFloat = 96
    static let maximumStoredWidth: CGFloat = 1_200
    static let maximumZoomColumnCount = 2
    static let horizontalPadding: CGFloat = 18

    static func maximumWidth(
        viewportWidth: CGFloat,
        columnCount: Int = maximumZoomColumnCount
    ) -> CGFloat {
        let columns = max(1, columnCount)
        let availableWidth = max(minimumWidth, viewportWidth - horizontalPadding * 2)
        let totalSpacing = CGFloat(columns - 1) * SpacingTokens.regular
        let width = floor((availableWidth - totalSpacing) / CGFloat(columns))
        return min(maximumStoredWidth, max(minimumWidth, width))
    }

    static func clampedStoredWidth(_ width: CGFloat) -> CGFloat {
        min(maximumStoredWidth, max(minimumWidth, width))
    }

    /// Columns the grid shows at rest for `width` across `availableWidth`
    /// (the nearest whole count, as the gallery lays out).
    static func columns(forWidth width: CGFloat, availableWidth: CGFloat) -> Int {
        let spacing = SpacingTokens.regular
        return max(maximumZoomColumnCount, Int(((availableWidth + spacing) / (width + spacing)).rounded()))
    }

    /// A thumbnail width that gives exactly `columns` at rest, or nil when no
    /// allowed width does (fewer than two columns, or smaller than the minimum).
    static func width(forColumns columns: Int, availableWidth: CGFloat) -> CGFloat? {
        guard columns >= maximumZoomColumnCount, availableWidth > 0 else { return nil }
        let spacing = SpacingTokens.regular
        // Just under the exact width, so rounding lands on `columns`.
        let width = floor((availableWidth + spacing) / CGFloat(columns) - spacing)
        guard width >= minimumWidth, width <= maximumStoredWidth else { return nil }
        return width
    }
}
