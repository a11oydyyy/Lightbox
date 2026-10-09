import CoreGraphics

enum PreviewGeometry {
    static let horizontalMargin: CGFloat = 88
    static let verticalMargin: CGFloat = 132

    static func previewSize(assetSize: CGSize, viewport: CGSize) -> CGSize {
        // Fill the window: side margins leave room for the step buttons, and the
        // symmetric vertical margin keeps the metadata block below the image.
        let maxWidth = max(220, viewport.width - 2 * horizontalMargin)
        let maxHeight = max(220, viewport.height - 2 * verticalMargin)
        let scale = min(1, maxWidth / max(1, assetSize.width), maxHeight / max(1, assetSize.height))
        return CGSize(width: assetSize.width * scale, height: assetSize.height * scale)
    }

    static func sourceFrame(recordedFrame: CGRect?, fallbackSize: CGSize, viewport: CGSize) -> CGRect {
        guard let recordedFrame, recordedFrame.width > 1, recordedFrame.height > 1 else {
            return centeredFrame(size: fallbackSize, viewport: viewport)
        }
        return recordedFrame
    }

    static func visibleFrame(
        isPresented: Bool,
        sourceFrame: CGRect,
        previewSize: CGSize,
        viewport: CGSize
    ) -> CGRect {
        guard isPresented else { return sourceFrame }
        return centeredFrame(size: previewSize, viewport: viewport)
    }

    static func scale(sourceFrame: CGRect, previewSize: CGSize) -> CGSize {
        CGSize(
            width: sourceFrame.width / max(1, previewSize.width),
            height: sourceFrame.height / max(1, previewSize.height)
        )
    }

    static func compensatedCornerRadius(
        displayRadius: CGFloat,
        scale: CGSize,
        maxRadius: CGFloat
    ) -> CGFloat {
        let minimumScale = max(0.001, min(abs(scale.width), abs(scale.height)))
        return min(maxRadius, displayRadius / minimumScale)
    }

    private static func centeredFrame(size: CGSize, viewport: CGSize) -> CGRect {
        CGRect(
            x: (viewport.width - size.width) / 2,
            y: (viewport.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
