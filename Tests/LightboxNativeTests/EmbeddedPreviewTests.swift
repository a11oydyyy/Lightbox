import AppKit
import ImageIO
import Testing
@testable import LightboxNative

// Fast gallery tiers may stand in an embedded preview for the image only
// when it is sharp enough and has the image's proportions.
@Test func embeddedPreviewIsUsedOnlyWhenSharpAndUncropped() {
    let photo = CGSize(width: 6000, height: 4000)
    // A camera's 160 × 120 EXIF thumbnail: far too small, and letterboxed to 4:3.
    #expect(!ImageCache.embeddedPreviewIsUsable(CGSize(width: 160, height: 120), sourceSize: photo, maxPixelSize: 480))
    // Large enough but letterboxed: black bars would show on the card.
    #expect(!ImageCache.embeddedPreviewIsUsable(CGSize(width: 640, height: 480), sourceSize: photo, maxPixelSize: 480))
    // Right proportions but blurry.
    #expect(!ImageCache.embeddedPreviewIsUsable(CGSize(width: 240, height: 160), sourceSize: photo, maxPixelSize: 480))
    // A RAW file's large preview, and one sized to the request.
    #expect(ImageCache.embeddedPreviewIsUsable(CGSize(width: 1620, height: 1080), sourceSize: photo, maxPixelSize: 480))
    #expect(ImageCache.embeddedPreviewIsUsable(CGSize(width: 480, height: 320), sourceSize: photo, maxPixelSize: 480))
    // Portrait after EXIF rotation.
    #expect(ImageCache.embeddedPreviewIsUsable(CGSize(width: 320, height: 480), sourceSize: CGSize(width: 4000, height: 6000), maxPixelSize: 480))
    // An image smaller than the request is fine at its own size.
    #expect(ImageCache.embeddedPreviewIsUsable(CGSize(width: 300, height: 200), sourceSize: CGSize(width: 300, height: 200), maxPixelSize: 480))
}

// A real JPEG with a small embedded EXIF thumbnail (ImageIO writes one
// about 160 pixels long), as cameras do.
@Test func fastTierDecodesTheImageWhenItsEmbeddedThumbnailIsTiny() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxEmbedded-\(UUID()).jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let context = try #require(CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
        kCGImageDestinationEmbedThumbnail: true,
        kCGImagePropertyExifDictionary: [:] as CFDictionary,
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    // The file really carries a small embedded thumbnail.
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let embedded = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 480,
    ] as CFDictionary))
    #expect(max(embedded.width, embedded.height) < 360, "embedded \(embedded.width) × \(embedded.height)")

    // Moving cards take the embedded preview as is: the cheap path.
    let moving = try #require(ImageCache.downsampledImage(for: url, quality: .thumbnailEmbedded))
    #expect(max(moving.size.width, moving.size.height) < 360)

    let decoded = try #require(ImageCache.downsampledImage(for: url, quality: .thumbnailBalanced))
    let cgImage = try #require(decoded.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(max(cgImage.width, cgImage.height) >= 360, "got \(cgImage.width) × \(cgImage.height)")
    #expect(abs(Double(cgImage.width) / Double(cgImage.height) - 1.5) < 0.02, "got \(cgImage.width) × \(cgImage.height)")
}

// A settled card asks for a sharp tier: an embedded preview in the cache
// shows meanwhile, but never counts as the sharp image.
@Test func embeddedPreviewsStandInButNeverSatisfySharpTiers() {
    for sharp in [ImageCacheQuality.thumbnailFast, .thumbnailBalanced, .thumbnail] {
        #expect(sharp.cacheLookupOrder.contains(.thumbnailEmbedded))
        #expect(!sharp.sufficientCacheLookupOrder.contains(.thumbnailEmbedded))
    }
    #expect(ImageCacheQuality.thumbnailEmbedded.sufficientCacheLookupOrder
        == [.thumbnail, .thumbnailBalanced, .thumbnailFast, .thumbnailEmbedded])
}
