import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LightboxNative

// A repeatable performance baseline over a synthetic library, for comparing
// builds. Off in normal runs; run it in release:
//
//   LIGHTBOX_BENCH=1 LIGHTBOX_BENCH_OUT=/tmp/bench.json \
//     swift test -c release -Xswiftc -enable-testing --filter performanceBaseline
//
// The files are clones of two generated JPEGs (24 MP and 2 MP), so reads after
// the first come from the page cache: scan and probe times are the app's own
// work, not the disk's. Each step runs several times; the median is reported.

private let benchEnabled = ProcessInfo.processInfo.environment["LIGHTBOX_BENCH"] != nil
/// Skips the slow whole-app steps.
private let benchSkipsApp = ProcessInfo.processInfo.environment["LIGHTBOX_BENCH_SKIP_APP"] != nil

private struct BenchResult: Codable {
    var name: String
    var detail: String
    var runs: [Double]
    var medianMs: Double
}

private final class BenchRecorder {
    private(set) var results: [BenchResult] = []

    func record(_ name: String, _ detail: String, runs: [Double]) {
        let median = runs.sorted()[runs.count / 2]
        results.append(BenchResult(name: name, detail: detail, runs: runs, medianMs: median))
        print("BENCH \(name) median=\(String(format: "%.1f", median))ms runs=\(runs.map { String(format: "%.1f", $0) }) — \(detail)")
    }

    func measure(_ name: String, _ detail: String, times: Int = 5, _ body: () throws -> Void) rethrows {
        var runs: [Double] = []
        for _ in 0..<times {
            let start = ContinuousClock.now
            try body()
            runs.append(milliseconds(ContinuousClock.now - start))
        }
        record(name, detail, runs: runs)
    }

    func write(to path: String?) throws {
        guard let path else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: path))
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func writeJPEG(width: Int, height: Int, to url: URL) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    var generator = SystemRandomNumberGenerator()
    // Busy content, so the JPEG is photo-sized rather than a flat fill.
    for _ in 0..<4000 {
        context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                             blue: .random(in: 0...1, using: &generator), alpha: 1)
        context.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &generator),
                            y: .random(in: 0..<CGFloat(height), using: &generator),
                            width: .random(in: 4...CGFloat(width) / 8, using: &generator),
                            height: .random(in: 4...CGFloat(height) / 8, using: &generator)))
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

/// `count` clones of the two masters in `folder`, one in five the large one.
private func fillFolder(_ folder: URL, count: Int, large: URL, small: URL, prefix: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<count {
        let master = index % 5 == 0 ? large : small
        let name = String(format: "%@_%05d.jpg", prefix, index)
        try FileManager.default.copyItem(at: master, to: folder.appendingPathComponent(name))
    }
}

private func syntheticAssets(_ count: Int) -> [LightboxAsset] {
    var generator = SystemRandomNumberGenerator()
    let tags = MacColorTag.all.map(\.name)
    return (0..<count).map { index in
        let name = "IMG_\(Int.random(in: 0..<count, using: &generator)).\(["jpg", "JPG", "heic", "dng", "png"][index % 5])"
        return LightboxAsset(
            id: "asset-\(index)", originalName: name,
            width: [1200, 4000, 6000, 8000][Int.random(in: 0..<4, using: &generator)],
            height: [800, 3000, 4000, 6000][Int.random(in: 0..<4, using: &generator)],
            tags: index % 7 == 0 ? [tags[index % tags.count]] : [],
            sourceURL: URL(fileURLWithPath: "/Volumes/Bench/d\(index % 40)/\(index)-\(name)"),
            addedAt: Date(timeIntervalSince1970: Double(Int.random(in: 0..<10_000_000, using: &generator))),
            fileSize: Int64(Int.random(in: 100_000..<80_000_000, using: &generator)),
            palette: MockPalette.imported[0]
        )
    }
}

@MainActor
@Test(.enabled(if: benchEnabled), .timeLimit(.minutes(20)))
func performanceBaseline() async throws {
    let bench = BenchRecorder()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxBench-\(UUID())").standardizedFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let large = root.appendingPathComponent("master-24mp.jpg")
    let small = root.appendingPathComponent("master-2mp.jpg")
    try writeJPEG(width: 6000, height: 4000, to: large)
    try writeJPEG(width: 1800, height: 1200, to: small)

    let flatCount = 20_000
    let flat = root.appendingPathComponent("flat")
    try fillFolder(flat, count: flatCount, large: large, small: small, prefix: "IMG")
    let tree = root.appendingPathComponent("tree")
    for folder in 0..<200 {
        try fillFolder(tree.appendingPathComponent(String(format: "Day %03d", folder)), count: 50,
                       large: large, small: small, prefix: "D\(folder)")
    }
    let source = LibrarySource.favorites(rootURL: flat)

    // Folder scans, as a refresh reads them.
    try bench.measure("scan.flat", "loadFolderSnapshot, \(flatCount) JPEGs, no cached sizes") {
        let snapshot = LocalImageSource.loadFolderSnapshot(in: flat, sourceID: source.id, rootURL: flat)
        #expect(snapshot.assets.count == flatCount)
    }
    var recursiveCount = 0
    var runs: [Double] = []
    for _ in 0..<5 {
        let start = ContinuousClock.now
        let result = await LocalImageSource.scanRecursiveAssets(in: tree, sourceID: source.id, rootURL: tree)
        runs.append(milliseconds(ContinuousClock.now - start))
        recursiveCount = result.assets.count
    }
    #expect(recursiveCount == 10_000)
    bench.record("scan.recursive", "scanRecursiveAssets, 200 folders × 50 JPEGs", runs: runs)

    // Reading sizes: the header probe, then the index's stored sizes.
    let probeURLs = (0..<2000).map { flat.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
    bench.measure("probe.dimensions", "ImageProbe.dimensions × 2000 files") {
        #expect(probeURLs.allSatisfy { ImageProbe.dimensions(for: $0) != nil })
    }

    // Thumbnail decodes, one at a time (the gallery runs several at once).
    let largeURLs = (0..<40).map { flat.appendingPathComponent(String(format: "IMG_%05d.jpg", $0 * 5)) }
    bench.measure("decode.thumbnail", "downsampledImage .thumbnail (1024 px) × 40 × 24 MP", times: 3) {
        #expect(largeURLs.allSatisfy { ImageCache.downsampledImage(for: $0, quality: .thumbnail) != nil })
    }
    bench.measure("decode.preview", "downsampledImage .preview (2400 px) × 20 × 24 MP", times: 3) {
        #expect(largeURLs.prefix(20).allSatisfy { ImageCache.downsampledImage(for: $0, quality: .preview) != nil })
    }

    // Sorting and filtering in memory.
    let assets = syntheticAssets(50_000)
    for field in GallerySortField.allCases {
        bench.measure("sort.\(field.rawValue)", "GalleryAssetSorter, 50,000 assets") {
            _ = GalleryAssetSorter.sorted(assets, field: field, direction: .descending)
        }
    }
    var filter = GalleryAttributeFilter()
    filter.orientation = .landscape
    filter.pixelSize = .atLeast4000
    bench.measure("filter.attributes", "visibleAssets, landscape ≥ 4000 px, 50,000 assets, sorted by time") {
        _ = GalleryContentFilter.visibleAssets(from: assets, filter: .all, attributes: filter,
                                               query: LightboxSearchQuery.parse(""), field: .time,
                                               direction: .descending, reusing: nil)
    }
    bench.measure("search.name", "visibleAssets, name query \"IMG_1\", 50,000 assets") {
        _ = GalleryContentFilter.visibleAssets(from: assets, filter: .all, query: LightboxSearchQuery.parse("IMG_1"),
                                               field: .time, direction: .descending, reusing: nil)
    }

    // The index: writing a folder's snapshot and reading it back.
    let flatSnapshot = LocalImageSource.loadFolderSnapshot(in: flat, sourceID: source.id, rootURL: flat)
    let storeURL = root.appendingPathComponent("bench-index.sqlite")
    let store = LightboxIndexStore(databaseURL: storeURL)
    store.upsertSource(source)
    bench.measure("index.write", "replaceVisibleSnapshot, \(flatCount) items") {
        #expect(store.replaceVisibleSnapshot(source: source, folderURL: flat, folders: [], assets: flatSnapshot.assets))
    }
    bench.measure("index.read", "cachedVisibleSnapshot, \(flatCount) items") {
        #expect(store.cachedVisibleSnapshot(source: source, folderURL: flat)?.assets.count == flatCount)
    }
    // What the size reader saves after each batch of 32.
    let updates = flatSnapshot.assets.prefix(2048).map {
        IndexedAssetMetadata(url: $0.sourceURL!, width: 6000, height: 4000, tags: [])
    }
    bench.measure("index.metadataUpdate", "updateCachedMetadata, 2,048 images in batches of 32, \(flatCount)-item source", times: 3) {
        for start in stride(from: 0, to: updates.count, by: 32) {
            store.updateCachedMetadata(sourceID: source.id, updates: Array(updates[start..<min(start + 32, updates.count)]))
        }
    }

    if benchSkipsApp {
        try bench.write(to: ProcessInfo.processInfo.environment["LIGHTBOX_BENCH_OUT"])
        return
    }

    // The app opening the folder: first listing, then every size read.
    // Cold: a new index; warm: the same index, as on a revisit after relaunch.
    let suite = "LightboxBench-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // A finished run's readers must not compete with the next one.
    func stop(_ state: AppState) {
        state.suspendActiveTabWork()
        state.assetMetadata.cancel()
        state.searchMetadata.cancel()
    }
    func openFolder(index: URL) async -> (listed: Double, sized: Double) {
        let state = AppState(indexDatabaseURL: index, libraryDefaults: defaults)
        let start = ContinuousClock.now
        state.sources = [source]
        state.chooseSource(source.id)
        await waitWhile(timeout: .seconds(120)) { state.activeAssets.count != flatCount }
        let listed = milliseconds(ContinuousClock.now - start)
        await waitWhile(timeout: .seconds(300)) {
            state.libraryLoadingStatus != nil || state.isReadingImageSizes
                || state.assets.contains { !$0.metadataLoaded }
        }
        let sized = milliseconds(ContinuousClock.now - start)
        stop(state)
        return (listed, sized)
    }
    var coldListed: [Double] = [], coldSized: [Double] = []
    for run in 0..<3 {
        let result = await openFolder(index: root.appendingPathComponent("cold-\(run).sqlite"))
        coldListed.append(result.listed)
        coldSized.append(result.sized)
    }
    bench.record("app.open.cold.listed", "AppState opens \(flatCount) JPEGs, new index: all listed", runs: coldListed)
    bench.record("app.open.cold.sized", "…and every image size read", runs: coldSized)
    let warmIndex = root.appendingPathComponent("cold-0.sqlite")
    // Let the first run's scheduled index write land.
    try await Task.sleep(for: .seconds(2))
    var warmListed: [Double] = [], warmSized: [Double] = []
    for _ in 0..<3 {
        let result = await openFolder(index: warmIndex)
        warmListed.append(result.listed)
        warmSized.append(result.sized)
    }
    bench.record("app.open.warm.listed", "AppState reopens \(flatCount) JPEGs, existing index: all listed", runs: warmListed)
    bench.record("app.open.warm.sized", "…and every image size read", runs: warmSized)

    // Re-sorting what is on screen.
    let state = AppState(indexDatabaseURL: warmIndex, libraryDefaults: defaults)
    state.sources = [source]
    state.chooseSource(source.id)
    await waitWhile(timeout: .seconds(120)) { state.activeAssets.count != flatCount || state.isReadingImageSizes }
    bench.measure("app.resort", "sortField time ↔ dimensions on \(flatCount) assets (two re-sorts)") {
        state.setSortField(.dimensions)
        state.setSortField(.time)
    }
    stop(state)

    try bench.write(to: ProcessInfo.processInfo.environment["LIGHTBOX_BENCH_OUT"])
}
