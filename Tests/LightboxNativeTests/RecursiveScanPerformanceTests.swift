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

@Test func recursiveEnumerationPublishesBeforeCompletionWithoutOpeningImages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<200 { try Data([1]).write(to: child.appendingPathComponent("photo-\(i).jpg")) }
    var progress: [LightboxSearchScanResult] = []
    let result = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
        query: .parse(""), recursive: true, collectsFolders: false, probeDimensions: false,
        dimensionResolver: { _ in Issue.record("Enumeration opened an image"); return nil },
        onProgress: { progress.append($0) })
    let first = try #require(progress.first)
    #expect(first.assets.count > 0 && first.assets.count < result.assets.count)
    #expect(result.assets.count == 200)
    #expect(result.assets.allSatisfy { !$0.metadataLoaded && $0.width == 1 && $0.height == 1 })
    #expect(!result.limitReached)
    #expect(result.assets.map(\.originalName) == result.assets.map(\.originalName).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    })
}

@Test func recursiveEnumerationCanBeCancelledAfterFirstPublication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<200 { try Data([1]).write(to: root.appendingPathComponent("photo-\(i).jpg")) }
    let task = Task {
        var publications = 0
        let result = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
            query: .parse(""), recursive: true, onProgress: { partial in
                publications += 1
                #expect(partial.assets.count == 1)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        return (result, publications)
    }
    let (result, publications) = await task.value
    #expect(publications == 1)
    #expect(result.assets.isEmpty && result.limitReached)
}

@Test func nasRecursiveEnumerationBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["LIGHTBOX_BENCHMARK_FOLDER"] else { return }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let start = Date()
    var firstResultSeconds: TimeInterval?
    let result = LocalImageSource.searchAssets(in: root, sourceID: "benchmark", rootURL: root,
        query: .parse(""), recursive: true, collectsFolders: false, probeDimensions: false,
        skipsPackages: true, maxResults: .max, maxFolderResults: .max, maxVisited: .max,
        dimensionResolver: { _ in Issue.record("Enumeration opened a NAS image"); return nil },
        loadsFinderTags: ProcessInfo.processInfo.environment["LIGHTBOX_BENCHMARK_DEFER_TAGS"] != "1",
        onProgress: { partial in
            if firstResultSeconds == nil, !partial.assets.isEmpty {
                firstResultSeconds = Date().timeIntervalSince(start)
                print("NAS first batch: \(firstResultSeconds!)s, images=\(partial.assets.count)")
            }
        })
    print("NAS enumeration complete: \(Date().timeIntervalSince(start))s, images=\(result.assets.count), visited=\(result.visitedCount)")
    #expect(!result.assets.isEmpty && !result.limitReached)
    #expect(firstResultSeconds != nil)
    #expect(result.assets.allSatisfy { !$0.metadataLoaded })
}

@Test func recursiveEnumerationCanDeferFinderTagsWithoutDroppingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("tagged.jpg")
    try Data([1]).write(to: image)
    #expect(FinderTagStore.setColorTags(["Red"], for: image))
    let fast = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
        query: .parse(""), recursive: true, loadsFinderTags: false)
    let complete = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
        query: .parse(""), recursive: true)
    #expect(fast.assets.map(\.id) == complete.assets.map(\.id))
    #expect(fast.assets.first?.tags == [])
    #expect(complete.assets.first?.tags == ["Red"])
    #expect(fast.assets.first?.fileSize == 1)
    #expect(fast.assets.first?.contentModifiedAt != nil)
}

@Test func scanProgressDistinguishesEnumerationFromMetadataInAllLanguages() {
    let scanning = LightboxSearchStatus(isSearching: true, discoveredCount: 42, visitedCount: 81)
    let metadata = LightboxSearchStatus(isSearching: false, metadataProcessed: 3, metadataTotal: 42)
    for language in [LightboxLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese] {
        let scanText = LightboxLocalization.searchProgress(scanning, recursive: true, language: language)
        #expect(scanText.contains("42") && scanText.contains("81"))
        let detailText = LightboxLocalization.searchProgress(metadata, recursive: true, language: language)
        #expect(detailText.contains("3 / 42") && scanText != detailText)
    }
    #expect(metadata.isLoadingMetadata)
    #expect(!LightboxSearchStatus(isSearching: false, metadataProcessed: 42, metadataTotal: 42).isLoadingMetadata)
}

@Test func concurrentRecursiveScanPreservesCoverageSkipsPackagesAndReportsFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<20 {
        let folder = root.appendingPathComponent("folder\(index)/deep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in 0..<5 { try Data([1]).write(to: folder.appendingPathComponent("photo\(file).jpg")) }
    }
    let package = root.appendingPathComponent("Example.app/Contents")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data([1]).write(to: package.appendingPathComponent("icon.jpg"))
    try Data([1]).write(to: root.appendingPathComponent(".hidden.jpg"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    let serial = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
        query: .parse(""), recursive: true, skipsPackages: true, maxResults: .max,
        maxFolderResults: .max, maxVisited: .max, loadsFinderTags: false)
    let parallel = await LocalImageSource.scanRecursiveAssets(in: root, sourceID: "test", rootURL: root)
    #expect(parallel.assets.count == 100)
    #expect(Set(parallel.assets.map(\.id)) == Set(serial.assets.map(\.id)))
    #expect(Set(parallel.folders.map(\.id)) == Set(serial.folders.map(\.id)))
    #expect(parallel.assets.allSatisfy { !$0.metadataLoaded && $0.width == 1 && $0.height == 1 })
    #expect(!parallel.limitReached)
    let hidden = await LocalImageSource.scanRecursiveAssets(in: root, sourceID: "test", rootURL: root, showsHiddenItems: true)
    #expect(hidden.assets.count == 101)
    let missing = await LocalImageSource.scanRecursiveAssets(in: root.appendingPathComponent("missing"), sourceID: "test", rootURL: root)
    #expect(missing.assets.isEmpty && missing.limitReached)
}

@Test func concurrentRecursiveScanCancellationDiscardsResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("photo.jpg"))
    let progress = ScanProgressRecorder()
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let task = Task {
        await LocalImageSource.scanRecursiveAssets(in: root, sourceID: "test", rootURL: root, onProgress: { partial in
            progress.record(partial)
            _ = gate.wait(timeout: .now() + 5)
        })
    }
    var didStart = false
    for _ in 0..<100 {
        if progress.firstImageCount != nil { didStart = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    gate.signal()
    let result = await task.value
    #expect(didStart)
    #expect(result.assets.isEmpty && result.limitReached)
}

@Test func concurrentScanStreamsImagesWithinOneLargeDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<256 { try Data([1]).write(to: root.appendingPathComponent("photo\(index).jpg")) }
    let progress = ScanProgressRecorder()
    let result = await LocalImageSource.scanRecursiveAssets(in: root, sourceID: "test", rootURL: root,
        onProgress: { progress.record($0) })
    let first = try #require(progress.firstImageCount)
    #expect(first > 0 && first < result.assets.count)
    #expect(result.assets.count == 256)
    #expect(!progress.hadDuplicates)
}

private final class ScanProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    private var duplicates = false
    func record(_ result: LightboxSearchScanResult) {
        lock.lock()
        defer { lock.unlock() }
        counts.append(result.assets.count)
        duplicates = duplicates || Set(result.assets.map(\.id)).count != result.assets.count
    }
    var firstImageCount: Int? { lock.withLock { counts.first { $0 > 0 } } }
    var hadDuplicates: Bool { lock.withLock { duplicates } }
}

@Test func nasConcurrentEnumerationBenchmark() async throws {
    guard let path = ProcessInfo.processInfo.environment["LIGHTBOX_BENCHMARK_FOLDER"] else { return }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let start = Date()
    let workers = Int(ProcessInfo.processInfo.environment["LIGHTBOX_BENCHMARK_WORKERS"] ?? "4") ?? 4
    let result = await LocalImageSource.scanRecursiveAssets(in: root, sourceID: "benchmark", rootURL: root,
        concurrentDirectoryLimit: workers, onProgress: { partial in
            print("NAS progress: \(Date().timeIntervalSince(start))s images=\(partial.assets.count) visited=\(partial.visitedCount)")
        })
    print("NAS concurrent enumeration: \(Date().timeIntervalSince(start))s images=\(result.assets.count) folders=\(result.folders.count) visited=\(result.visitedCount) workers=\(workers)")
    #expect(!result.assets.isEmpty && !result.limitReached)
    #expect(result.assets.count == Set(result.assets.map(\.id)).count)
    #expect(result.assets.allSatisfy { !$0.metadataLoaded })
}
