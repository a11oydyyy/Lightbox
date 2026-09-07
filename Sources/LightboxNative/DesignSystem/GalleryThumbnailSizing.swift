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
}
