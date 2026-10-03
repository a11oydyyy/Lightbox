import Testing
@preconcurrency import AppKit
import CoreGraphics
import Foundation
@testable import LightboxNative

@Test @MainActor func imageCacheMetadataHintsUseOnePreviewEntryPerFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let images = try (0..<3).map { _ in try performanceTestImage() }
    let counter = ImagePerformanceCounter()
    let cache = ImageCache(memoryProfile: ImageCacheMemoryProfile(isCompatibilityMode: false)) { url, _ in
        counter.increment()
        return images[Int(url.deletingPathExtension().lastPathComponent)!]
    }
    var sources: [(URL, FileContentSignature, FileContentSignature)] = []
    for index in images.indices {
        let url = root.appendingPathComponent("\(index).jpg")
        try Data("source".utf8).write(to: url)
        let resolved = try #require(FileContentSignature(url: url))
        let asset = LightboxAsset(
            originalName: url.lastPathComponent,
            width: 8, height: 8, tags: [], sourceURL: url,
            addedAt: .now,
            contentModifiedAt: Date(timeIntervalSince1970: resolved.modificationTime),
            fileSize: resolved.fileSize,
            palette: MockPalette.imported[0]
        )
        let hint = try #require(asset.fileContentSignature)
        #expect(hint != resolved)
        sources.append((url, hint, resolved))
        let image = await performanceLoad(cache, url: url, signature: hint)
        #expect(image === images[index])
    }
    // Three files fit the existing five-entry preview budget. Signature aliases must not
    // consume a second entry and evict pixels during this round trip.
    for (index, source) in sources.enumerated() {
        #expect(cache.bestCachedImage(for: source.0, quality: .preview, knownFileSignature: source.1) === images[index])
        #expect(cache.bestCachedImage(for: source.0, quality: .preview, knownFileSignature: source.2) === images[index])
        let image = await performanceLoad(cache, url: source.0, signature: source.1)
        #expect(image === images[index])
    }
    #expect(counter.value == 3)
}

@Test @MainActor func imageCacheMemoryHitsPreserveMetadataHintSeed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("source.jpg")
    try Data("source".utf8).write(to: url)
    let resolved = try #require(FileContentSignature(url: url))
    let hint = FileContentSignature(modificationTime: resolved.modificationTime, fileSize: resolved.fileSize)
    let image = try performanceTestImage()
    let counter = ImagePerformanceCounter()
    let cache = ImageCache { _, _ in
        counter.increment()
        return image
    }
    let first = await performanceLoad(cache, url: url, signature: hint)
    #expect(first === image)
    for signature in [nil, resolved] as [FileContentSignature?] {
        let cached = await performanceLoad(cache, url: url, signature: signature)
        #expect(cached === image)
        #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: hint) === image)
        #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: resolved) === image)
    }
    #expect(counter.value == 1)
}

@Test @MainActor func imageCacheMetadataHintDetectsSameMetadataAtomicReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("source.jpg")
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try Data("first".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
    let original = try #require(FileContentSignature(url: url))
    let hint = FileContentSignature(modificationTime: original.modificationTime, fileSize: original.fileSize)
    let oldImage = try performanceTestImage()
    let newImage = try performanceTestImage()
    let counter = ImagePerformanceCounter()
    let cache = ImageCache { _, _ in
        counter.increment() == 1 ? oldImage : newImage
    }
    let first = await performanceLoad(cache, url: url, signature: hint)
    #expect(first === oldImage)

    try Data("other".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
    let replacement = try #require(FileContentSignature(url: url))
    #expect(original.matchesModificationMetadata(replacement))
    #expect(original != replacement)
    let second = await performanceLoad(cache, url: url, signature: hint)
    #expect(second === newImage)
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: hint) === newImage)
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: original) == nil)
    let third = await performanceLoad(cache, url: url, signature: hint)
    #expect(third === newImage)
    #expect(counter.value == 2)
}

@Test @MainActor func imageCacheOlderSignatureRequestCannotOverwriteNewerEntry() async throws {
    let url = URL(fileURLWithPath: "/tmp/lightbox-image-performance-\(UUID().uuidString).jpg")
    let original = FileContentSignature(modificationTime: 100, fileSize: 8, fileSystemIdentifier: "1:1")
    let replacement = FileContentSignature(modificationTime: 101, fileSize: 8, fileSystemIdentifier: "1:2")
    let originalHint = FileContentSignature(modificationTime: 100, fileSize: 8)
    let replacementHint = FileContentSignature(modificationTime: 101, fileSize: 8)
    let oldImage = try performanceTestImage()
    let newImage = try performanceTestImage()
    let resolverCounter = ImagePerformanceCounter()
    let decodeCounter = ImagePerformanceCounter()
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let cache = ImageCache(
        decodeImage: { _, _ in
            if decodeCounter.increment() == 1 {
                _ = gate.wait(timeout: .now() + 5)
                return oldImage
            }
            return newImage
        },
        fileSignature: { _ in
            resolverCounter.increment() == 1 ? original : replacement
        }
    )
    var firstCompleted = false
    _ = cache.image(for: url, quality: .preview, knownFileSignature: originalHint) { image in
        #expect(image === oldImage)
        firstCompleted = true
    }
    try await performanceWaitUntil { decodeCounter.value == 1 }
    let second = await performanceLoad(cache, url: url, signature: replacementHint)
    #expect(second === newImage)
    gate.signal()
    try await performanceWaitUntil { firstCompleted }
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: replacementHint) === newImage)
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: replacement) === newImage)
    let third = await performanceLoad(cache, url: url, signature: replacementHint)
    #expect(third === newImage)
    #expect(decodeCounter.value == 2)
}

@Test @MainActor func imageCacheSignatureObservationOrderWinsOverSubmissionOrder() async throws {
    let url = URL(fileURLWithPath: "/tmp/lightbox-image-observation-\(UUID().uuidString).jpg")
    let original = FileContentSignature(modificationTime: 100, fileSize: 8, fileSystemIdentifier: "1:1")
    let replacement = FileContentSignature(modificationTime: 101, fileSize: 8, fileSystemIdentifier: "1:2")
    let originalHint = FileContentSignature(modificationTime: 100, fileSize: 8)
    let replacementHint = FileContentSignature(modificationTime: 101, fileSize: 8)
    let oldImage = try performanceTestImage()
    let newImage = try performanceTestImage()
    let resolverCounter = ImagePerformanceCounter()
    let decodeCounter = ImagePerformanceCounter()
    let resolverGate = DispatchSemaphore(value: 0)
    let oldDecodeGate = DispatchSemaphore(value: 0)
    defer {
        resolverGate.signal()
        oldDecodeGate.signal()
    }
    let cache = ImageCache(
        decodeImage: { _, _ in
            if decodeCounter.increment() == 1 {
                _ = oldDecodeGate.wait(timeout: .now() + 5)
                return oldImage
            }
            return newImage
        },
        fileSignature: { _ in
            switch resolverCounter.increment() {
            case 1:
                _ = resolverGate.wait(timeout: .now() + 5)
                return replacement
            case 2:
                return original
            default:
                return replacement
            }
        }
    )
    var newerObservationCompleted = false
    var olderObservationCompleted = false
    // The first submission resolves last and sees the new file.
    _ = cache.image(for: url, quality: .preview, knownFileSignature: replacementHint) { image in
        #expect(image === newImage)
        newerObservationCompleted = true
    }
    try await performanceWaitUntil { resolverCounter.value == 1 }
    _ = cache.image(for: url, quality: .preview, knownFileSignature: originalHint) { image in
        #expect(image === oldImage)
        olderObservationCompleted = true
    }
    try await performanceWaitUntil { decodeCounter.value == 1 }
    resolverGate.signal()
    try await performanceWaitUntil { newerObservationCompleted }
    oldDecodeGate.signal()
    try await performanceWaitUntil { olderObservationCompleted }
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: replacementHint) === newImage)
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: replacement) === newImage)
    #expect(cache.bestCachedImage(for: url, quality: .preview, knownFileSignature: original) == nil)
    let cached = await performanceLoad(cache, url: url, signature: replacementHint)
    #expect(cached === newImage)
    #expect(decodeCounter.value == 2)
}

@MainActor
private func performanceLoad(_ cache: ImageCache, url: URL, signature: FileContentSignature?) async -> NSImage? {
    await withCheckedContinuation { continuation in
        _ = cache.image(for: url, quality: .preview, knownFileSignature: signature) { image in
            continuation.resume(returning: image)
        }
    }
}

@MainActor
private func performanceWaitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}

private func performanceTestImage() throws -> NSImage {
    let context = try #require(CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    return NSImage(cgImage: image, size: NSSize(width: 8, height: 8))
}

private final class ImagePerformanceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
