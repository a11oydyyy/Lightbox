import Foundation
import ImageIO

enum ImageProbe {
    static func dimensions(for url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return thumbnailDimensions(from: source)
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        return displaySize(
            pixelWidth: CGFloat(width.doubleValue),
            pixelHeight: CGFloat(height.doubleValue),
            orientation: orientation
        )
    }

    static func displaySize(pixelWidth: CGFloat, pixelHeight: CGFloat, orientation: Int?) -> CGSize {
        let rotatesAxes = orientation.map { [5, 6, 7, 8].contains($0) } ?? false
        if rotatesAxes {
            return CGSize(width: pixelHeight, height: pixelWidth)
        }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private static func thumbnailDimensions(from source: CGImageSource) -> CGSize? {
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return CGSize(width: thumbnail.width, height: thumbnail.height)
    }
}
