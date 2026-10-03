import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import LightboxNative

@Test func recursiveScanReusesDimensionsAndDetectsAtomicReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = child.appendingPathComponent("a.jpg")
    let second = child.appendingPathComponent("b.jpg")
    try Data([1, 2]).write(to: first)
    try Data([1, 2]).write(to: second)
    let cache = RecursiveImageDimensionCache(countLimit: 20)
    var calls = 0
    func scan() -> LightboxSearchScanResult {
        LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
            query: .parse(""), recursive: true, collectsFolders: false, probeDimensions: true,
            maxResults: .max, maxFolderResults: .max, maxVisited: .max,
            dimensionCache: cache, dimensionResolver: { url in
                calls += 1
                guard let byte = (try? Data(contentsOf: url))?.first else { return nil }
                return CGSize(width: Int(byte) * 40, height: Int(byte) * 60)
            })
    }
    #expect(scan().assets.count == 2)
    #expect(calls == 2)
    #expect(scan().assets.allSatisfy { $0.width == 40 && $0.height == 60 && $0.metadataLoaded })
    #expect(calls == 2)
    let original = try #require(FileContentSignature(url: first))
    try Data([3, 4]).write(to: first, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: original.modificationTime)], ofItemAtPath: first.path)
    let replaced = try #require(FileContentSignature(url: first))
    #expect(replaced.fileSize == original.fileSize)
    #expect(replaced.fileSystemIdentifier != original.fileSystemIdentifier)
    let replacedAssets = scan().assets
    #expect(replacedAssets.count == 2)
    let replacedAsset = try #require(replacedAssets.first { $0.originalName == "a.jpg" })
    #expect(replacedAsset.width == 120 && replacedAsset.height == 180)
    #expect(calls == 3)
    try FileManager.default.removeItem(at: second)
    try Data([5]).write(to: child.appendingPathComponent("c.jpg"))
    #expect(scan().assets.map(\.originalName) == ["a.jpg", "c.jpg"])
    #expect(calls == 4)
}

@Test func recursiveDimensionCacheDoesNotCacheFailureOrChangedFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = RecursiveImageDimensionCache(countLimit: 2)
    var calls = 0
    for _ in 0..<2 {
        #expect(cache.dimensions(for: url) { _ in calls += 1; return nil } == nil)
    }
    #expect(calls == 2)
    _ = cache.dimensions(for: url) { _ in
        try? Data([2, 3]).write(to: url, options: .atomic)
        return CGSize(width: 1, height: 2)
    }
    let result = cache.dimensions(for: url) { _ in calls += 1; return CGSize(width: 3, height: 4) }
    #expect(result == CGSize(width: 3, height: 4))
    #expect(calls == 3)
}

@Test func recursiveDimensionCacheSupportsConcurrentAccess() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = RecursiveImageDimensionCache(countLimit: 2)
    await withTaskGroup(of: CGSize?.self) { group in
        for _ in 0..<32 {
            group.addTask { cache.dimensions(for: url) { _ in CGSize(width: 40, height: 60) } }
        }
        for await dimensions in group { #expect(dimensions == CGSize(width: 40, height: 60)) }
    }
    #expect(cache.dimensions(for: url) { _ in Issue.record("Warm cache decoded again"); return nil } == CGSize(width: 40, height: 60))
}

@Test func cancelledRecursiveScanDoesNotPublishPartialResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("a.jpg"))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
            query: .parse(""), recursive: true, probeDimensions: true,
            dimensionCache: RecursiveImageDimensionCache(), dimensionResolver: { _ in
                Issue.record("Cancelled scan decoded an image")
                return nil
            })
    }
    let result = await task.value
    #expect(result.assets.isEmpty)
    #expect(result.limitReached)
}

@Test func cancellationDuringProbeDoesNotPopulateDimensionCache() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = RecursiveImageDimensionCache(countLimit: 2)
    let task = Task {
        cache.dimensions(for: url) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return CGSize(width: 1, height: 2)
        }
    }
    _ = await task.value
    #expect(cache.dimensions(for: url) { _ in CGSize(width: 3, height: 4) } == CGSize(width: 3, height: 4))
}

@Test func recursivePNGScanCachesRealProbesAndPreservesNaturalOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try #require(CGContext(data: nil, width: 40, height: 60, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    for index in 0..<128 {
        let directory = root.appendingPathComponent(index.isMultiple(of: 2) ? "folder2" : "folder10")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("photo-\(index).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
    let cache = RecursiveImageDimensionCache(countLimit: 256)
    var calls = 0
    func scan() -> LightboxSearchScanResult {
        LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
            query: .parse(""), recursive: true, collectsFolders: false, probeDimensions: true,
            maxResults: .max, maxFolderResults: .max, maxVisited: .max,
            dimensionCache: cache, dimensionResolver: { url in
                calls += 1
                return ImageProbe.dimensions(for: url)
            })
    }
    let coldStart = Date()
    let cold = scan()
    let coldSeconds = Date().timeIntervalSince(coldStart)
    #expect(calls == 128)
    let warmStart = Date()
    let warm = scan()
    let warmSeconds = Date().timeIntervalSince(warmStart)
    print("Recursive PNG scan (128): cold=\(coldSeconds)s warm=\(warmSeconds)s")
    #expect(calls == 128)
    #expect(cold.assets.count == 128 && warm.assets.count == 128)
    #expect(warm.assets.allSatisfy { $0.width == 40 && $0.height == 60 && $0.metadataLoaded })
    #expect(cold.assets.map(\.id) == warm.assets.map(\.id))
    let legacySorted = warm.assets.sorted { lhs, rhs in
        let lhsParent = lhs.sourceURL?.deletingLastPathComponent().path ?? ""
        let rhsParent = rhs.sourceURL?.deletingLastPathComponent().path ?? ""
        if lhsParent != rhsParent {
            return lhsParent.localizedStandardCompare(rhsParent) == .orderedAscending
        }
        return lhs.originalName.localizedStandardCompare(rhs.originalName) == .orderedAscending
    }
    #expect(warm.assets.map(\.id) == legacySorted.map(\.id))
    #expect(warm.assets.first?.sourceURL?.deletingLastPathComponent().lastPathComponent == "folder2")
}
