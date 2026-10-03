import Testing
@preconcurrency import AppKit
import CoreGraphics
import Foundation
@testable import LightboxNative

@Test @MainActor func imageDeliveryDoesNotWaitForThumbnailDiskWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxDelivery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let signature = FileContentSignature(modificationTime: 100, fileSize: 8)
    let image = try deliveryTestImage()
    let gate = DispatchSemaphore(value: 0)
    let writes = DeliveryTestCounter()
    let decodes = DeliveryTestCounter()
    let writer = ThumbnailWriteScheduler(store: { _, _, _, _ in
        if writes.increment() == 1 {
            #expect(gate.wait(timeout: .now() + 5) == .success)
        }
    }, removeAll: {})
    defer {
        gate.signal()
        writer.waitUntilIdle()
    }
    let cache = ImageCache(
        diskCache: ThumbnailDiskCache(folder: root),
        diskWriter: writer,
        decodeImage: { _, _ in
            decodes.increment()
            return image
        },
        fileSignature: { _ in signature }
    )
    var completed = 0
    func request(_ index: Int, quality: ImageCacheQuality) {
        _ = cache.image(for: root.appendingPathComponent("source-\(index).jpg"), quality: quality,
                        knownFileSignature: signature) { result in
            #expect(result === image)
            completed += 1
        }
    }
    request(0, quality: .thumbnailFast)
    try await waitForDelivery { writes.value == 1 }
    try await waitForDelivery { completed == 1 }
    // More than the decode concurrency and writer capacity still finish while the first write is blocked.
    for index in 1...12 { request(index, quality: .thumbnailFast) }
    request(13, quality: .preview)
    try await waitForDelivery { completed == 14 }
    #expect(decodes.value == 14)
    #expect(writes.value == 1)
    cache.removeMemoryObjects(reason: "delivery-test")
    gate.signal()
    await Task.detached { writer.waitUntilIdle() }.value
    #expect(writes.value > 1)
    #expect(writes.value <= 9)
}

@MainActor
private func waitForDelivery(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}

private func deliveryTestImage() throws -> NSImage {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
        bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 8, height: 8))
}

private final class DeliveryTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
