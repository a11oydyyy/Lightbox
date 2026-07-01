import Testing
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
@testable import LightboxNative

@Test func previewTargetFrameIsCenteredInViewport() async throws {
    let viewport = CGSize(width: 1600, height: 1000)
    let assetSize = CGSize(width: 750, height: 909)

    let previewSize = PreviewGeometry.previewSize(assetSize: assetSize, viewport: viewport)
    let frame = PreviewGeometry.visibleFrame(
        isPresented: true,
        sourceFrame: CGRect(x: 20, y: 40, width: 200, height: 240),
        previewSize: previewSize,
        viewport: viewport
    )

    #expect(abs(frame.midX - viewport.width / 2) < 0.001)
    #expect(abs(frame.midY - viewport.height / 2) < 0.001)
}

@Test func previewClosedFrameUsesRecordedCardFrame() async throws {
    let source = CGRect(x: 32, y: 88, width: 206, height: 310)
    let frame = PreviewGeometry.visibleFrame(
        isPresented: false,
        sourceFrame: source,
        previewSize: CGSize(width: 640, height: 820),
        viewport: CGSize(width: 1600, height: 1000)
    )

    #expect(frame == source)
}

@Test func missingSourceFrameFallsBackToCenter() async throws {
    let viewport = CGSize(width: 1600, height: 1000)
    let fallback = CGSize(width: 500, height: 700)
    let frame = PreviewGeometry.sourceFrame(
        recordedFrame: nil,
        fallbackSize: fallback,
        viewport: viewport
    )

    #expect(abs(frame.midX - viewport.width / 2) < 0.001)
    #expect(abs(frame.midY - viewport.height / 2) < 0.001)
}

@Test func previewScaleUsesStablePreviewLayerSize() async throws {
    let previewSize = CGSize(width: 800, height: 600)
    let sourceFrame = CGRect(x: 100, y: 120, width: 200, height: 150)
    let scale = PreviewGeometry.scale(sourceFrame: sourceFrame, previewSize: previewSize)

    #expect(abs(scale.width - 0.25) < 0.001)
    #expect(abs(scale.height - 0.25) < 0.001)
}

@Test func previewCornerRadiusCompensatesForClosingScale() async throws {
    let radius = PreviewGeometry.compensatedCornerRadius(
        displayRadius: 10,
        scale: CGSize(width: 0.25, height: 0.25),
        maxRadius: 200
    )

    #expect(abs(radius - 40) < 0.001)
}

@Test func previewCornerRadiusCompensationIsClamped() async throws {
    let radius = PreviewGeometry.compensatedCornerRadius(
        displayRadius: 10,
        scale: CGSize(width: 0.01, height: 0.01),
        maxRadius: 120
    )

    #expect(abs(radius - 120) < 0.001)
}

@Test func previewSourceRevealHappensJustBeforeCloseFinishes() async throws {
    #expect(MotionTokens.previewSourceRevealDelay < MotionTokens.previewGeometryDuration)
}

@Test func previewHighResolutionUpgradeWaitsForGeometryToSettle() async throws {
    #expect(MotionTokens.previewHighResolutionDelay > MotionTokens.previewGeometryDuration)
}

@MainActor
@Test func previewRootClickClosesOpeningPreviewBeforeOverlayIsReady() async throws {
    let appState = AppState()
    let asset = previewRouteAsset(id: "asset-a", name: "a.jpg", addedAt: 0)

    appState.assets = [asset]
    appState.showPreview(for: asset, sourceFrame: CGRect(x: 20, y: 30, width: 120, height: 160))

    #expect(appState.needsPreviewRootClickCatcher)

    appState.handlePreviewRootClick(at: CGPoint(x: 60, y: 90))

    #expect(appState.isPreviewClosing)
    #expect(appState.previewAssetID == asset.id)

    appState.closePreview()
}

@MainActor
@Test func previewRootClickReopensCurrentPreviewDuringEarlyClose() async throws {
    let appState = AppState()
    let asset = previewRouteAsset(id: "asset-a", name: "a.jpg", addedAt: 0)

    appState.assets = [asset]
    appState.showPreview(for: asset, sourceFrame: CGRect(x: 20, y: 30, width: 120, height: 160))
    appState.handlePreviewRootClick(at: CGPoint(x: 60, y: 90))
    appState.handlePreviewRootClick(at: CGPoint(x: 60, y: 90))

    #expect(appState.isPreviewPresented)
    #expect(!appState.isPreviewClosing)
    #expect(appState.previewAssetID == asset.id)

    appState.closePreview()
}

@MainActor
@Test func previewRootClickSwitchesTargetDuringEarlyClose() async throws {
    let appState = AppState()
    let first = previewRouteAsset(id: "asset-a", name: "a.jpg", addedAt: 0)
    let second = previewRouteAsset(id: "asset-b", name: "b.jpg", addedAt: 1)
    let firstFrame = CGRect(x: 20, y: 30, width: 120, height: 160)
    let secondFrame = CGRect(x: 180, y: 30, width: 120, height: 160)

    appState.assets = [first, second]
    appState.updatePreviewSpaceAssetFrames([
        first.id: firstFrame,
        second.id: secondFrame
    ])
    appState.showPreview(for: first, sourceFrame: firstFrame)
    appState.handlePreviewRootClick(at: CGPoint(x: 60, y: 90))
    appState.handlePreviewRootClick(at: CGPoint(x: 220, y: 90))

    #expect(appState.isPreviewPresented)
    #expect(!appState.isPreviewClosing)
    #expect(appState.previewAssetID == second.id)
    #expect(appState.previewSourceFrame == secondFrame)

    appState.closePreview()
}

@MainActor
@Test func previewSpaceFrameReturnsLatestFrame() async throws {
    let appState = AppState()
    let asset = previewRouteAsset(id: "asset-a", name: "a.jpg", addedAt: 0)
    let firstFrame = CGRect(x: 20, y: 30, width: 120, height: 160)
    let secondFrame = CGRect(x: 260, y: 30, width: 120, height: 160)

    appState.assets = [asset]
    appState.updatePreviewSpaceAssetFrames([asset.id: firstFrame])
    #expect(appState.previewSpaceFrame(for: asset.id) == firstFrame)

    appState.updatePreviewSpaceAssetFrames([asset.id: secondFrame])
    #expect(appState.previewSpaceFrame(for: asset.id) == secondFrame)
}

@Test func assetIDIsStableForFileURL() async throws {
    let url = URL(fileURLWithPath: "/tmp/lightbox/example.jpg")
    let first = LightboxAsset(
        originalName: "example.jpg",
        width: 100,
        height: 100,
        tags: [],
        sourceURL: url,
        addedAt: .distantPast,
        palette: MockPalette.imported[0]
    )
    let second = LightboxAsset(
        originalName: "renamed-label.jpg",
        width: 200,
        height: 120,
        tags: ["Red"],
        sourceURL: url,
        addedAt: .now,
        palette: MockPalette.imported[1]
    )

    #expect(first.id == second.id)
}

private func previewRouteAsset(id: String, name: String, addedAt: TimeInterval) -> LightboxAsset {
    LightboxAsset(
        id: id,
        originalName: name,
        width: 120,
        height: 160,
        tags: [],
        addedAt: Date(timeIntervalSince1970: addedAt),
        palette: MockPalette.imported[0]
    )
}

@Test func rubberBandLayerIgnoresClicksAboveFirstAsset() async throws {
    let assetFrames = [
        CGRect(x: 40, y: 240, width: 180, height: 220),
        CGRect(x: 240, y: 260, width: 180, height: 220)
    ]

    #expect(RubberBandSelectionView.isAboveSelectableAssetArea(
        CGPoint(x: 80, y: 180),
        assetFrames: assetFrames
    ))
    #expect(!RubberBandSelectionView.isAboveSelectableAssetArea(
        CGPoint(x: 80, y: 300),
        assetFrames: assetFrames
    ))
}

@Test func rubberBandLayerMapsAppKitPointIntoGalleryCoordinates() async throws {
    let assetFrames = [
        CGRect(x: 320, y: 260, width: 180, height: 220)
    ]
    let mappedPoint = RubberBandSelectionView.selectionPoint(
        from: CGPoint(x: 360, y: 700),
        boundsHeight: 1_000
    )

    #expect(mappedPoint == CGPoint(x: 360, y: 300))
    #expect(RubberBandSelectionView.isInsideAssetFrame(
        mappedPoint,
        assetFrames: assetFrames
    ))
}

@Test func indexStoreReturnsOnlyLoadedDimensions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("loaded.jpg")
    try Data("loaded".utf8).write(to: imageURL)

    let source = LibrarySource.favorites(rootURL: root)
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 321,
        height: 654,
        tags: [],
        sourceURL: imageURL,
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )

    let store = LightboxIndexStore(databaseURL: databaseURL)
    store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [], assets: [asset])

    let cached = store.cachedDimensions(sourceID: source.id, parentPath: root.path)
    #expect(cached[imageURL.standardizedFileURL.path]?.width == 321)
    #expect(cached[imageURL.standardizedFileURL.path]?.height == 654)
}

@Test func indexStoreDoesNotReturnFallbackDimensions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("fallback.jpg")
    try Data("fallback".utf8).write(to: imageURL)

    let source = LibrarySource.favorites(rootURL: root)
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 999,
        height: 999,
        tags: [],
        sourceURL: imageURL,
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: false
    )

    let store = LightboxIndexStore(databaseURL: databaseURL)
    store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [], assets: [asset])

    let cached = store.cachedDimensions(sourceID: source.id, parentPath: root.path)
    #expect(cached[imageURL.standardizedFileURL.path] == nil)
}

@Test func indexStoreIgnoresLegacyDimensionCacheVersions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("rotated-portrait.jpg")
    try Data("rotated".utf8).write(to: imageURL)

    let source = LibrarySource.favorites(rootURL: root)
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 3000,
        height: 2000,
        tags: [],
        sourceURL: imageURL,
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )

    let store = LightboxIndexStore(databaseURL: databaseURL)
    store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [], assets: [asset])
    #expect(store.cachedDimensions(sourceID: source.id, parentPath: root.path).count == 1)

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    sqlite3_exec(database, "UPDATE items SET dimension_version = 1;", nil, nil, nil)
    sqlite3_close(database)

    #expect(store.cachedDimensions(sourceID: source.id, parentPath: root.path).isEmpty)
}

@Test func indexStoreUsesWALJournalMode() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let store = LightboxIndexStore(databaseURL: databaseURL)

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer {
        sqlite3_close(database)
    }

    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "PRAGMA journal_mode;", -1, &statement, nil) == SQLITE_OK)
    defer {
        sqlite3_finalize(statement)
    }

    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let mode = sqlite3_column_text(statement, 0).map { String(cString: $0).lowercased() }
    #expect(mode == "wal")
    _ = store
}

@Test func comparisonQualityUsesHigherResolutionThanPreview() async throws {
    #expect(ImageCacheQuality.comparison.maxPixelSize > ImageCacheQuality.preview.maxPixelSize)
    #expect(ImageCacheQuality.preview.maxPixelSize > ImageCacheQuality.thumbnail.maxPixelSize)
}

@Test func thumbnailQualityCoversTwoXMaximumGalleryTileWidth() async throws {
    #expect(ImageCacheQuality.thumbnail.maxPixelSize >= 1024)
}

@Test @MainActor func imageCacheCoalescesDuplicateRequests() async throws {
    let decodeCounter = LockedCounter()
    let cache = ImageCache { _, _ in
        decodeCounter.increment()
        Thread.sleep(forTimeInterval: 0.05)
        return nil
    }
    let url = URL(fileURLWithPath: "/tmp/lightbox-cache-coalesce.jpg")
    var completionCount = 0

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let recordCompletion: @MainActor @Sendable (NSImage?) -> Void = { image in
            #expect(image == nil)
            completionCount += 1
            if completionCount == 2 {
                continuation.resume()
            }
        }

        _ = cache.image(for: url, quality: .thumbnail, completion: recordCompletion)
        _ = cache.image(for: url, quality: .thumbnail, completion: recordCompletion)
    }

    #expect(decodeCounter.value == 1)
}

@Test func imageCacheThumbnailPromotionRulesExcludePreviewAndComparison() async throws {
    #expect(ImageCache.shouldAttach(requested: .thumbnailFast, toPending: .thumbnail))
    #expect(ImageCache.shouldAttach(requested: .thumbnailBalanced, toPending: .thumbnail))
    #expect(!ImageCache.shouldAttach(requested: .thumbnail, toPending: .thumbnailFast))

    #expect(ImageCache.shouldPromote(pending: .thumbnailFast, to: .thumbnail))
    #expect(ImageCache.shouldPromote(pending: .thumbnailBalanced, to: .thumbnail))
    #expect(!ImageCache.shouldPromote(pending: .thumbnail, to: .thumbnailFast))

    #expect(!ImageCache.shouldAttach(requested: .thumbnail, toPending: .preview))
    #expect(!ImageCache.shouldPromote(pending: .thumbnail, to: .preview))
    #expect(!ImageCache.shouldPromote(pending: .preview, to: .comparison))
}

@Test func thumbnailDiskCacheKeysIncludeFileSignatureAndQuality() async throws {
    let url = URL(fileURLWithPath: "/tmp/lightbox-cache-source.jpg")
    let original = ThumbnailFileSignature(modificationTime: 100, fileSize: 20)
    let changedSize = ThumbnailFileSignature(modificationTime: 100, fileSize: 21)
    let changedTime = ThumbnailFileSignature(modificationTime: 101, fileSize: 20)

    let originalKey = ThumbnailDiskCache.cacheKey(for: url, quality: .thumbnailFast, signature: original)

    #expect(originalKey == ThumbnailDiskCache.cacheKey(for: url, quality: .thumbnailFast, signature: original))
    #expect(originalKey != ThumbnailDiskCache.cacheKey(for: url, quality: .thumbnailBalanced, signature: original))
    #expect(originalKey != ThumbnailDiskCache.cacheKey(for: url, quality: .thumbnailFast, signature: changedSize))
    #expect(originalKey != ThumbnailDiskCache.cacheKey(for: url, quality: .thumbnailFast, signature: changedTime))
}

@Test func thumbnailDiskCacheStoresOnlyThumbnailQualities() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg", isDirectory: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: sourceURL)

    let cache = ThumbnailDiskCache(folder: root.appendingPathComponent("thumbnails", isDirectory: true))
    let image = try #require(makeTestImage())

    cache.store(image, for: sourceURL, quality: .thumbnailFast)

    #expect(cache.image(for: sourceURL, quality: .thumbnailFast) != nil)
    #expect(cache.cacheURL(for: sourceURL, quality: .preview) == nil)
}

@Test func imageCacheTelemetrySummarizesThumbnailHitRate() async throws {
    let telemetry = ImageCacheTelemetry(summaryInterval: 2)

    #expect(telemetry.record(.memoryHit, quality: .preview) == nil)

    let first = try #require(telemetry.record(.memoryHit, quality: .thumbnailFast))
    #expect(first.total == 1)
    #expect(first.memoryHits == 1)
    #expect(abs(first.hitRate - 1.0) < 0.001)

    let second = try #require(telemetry.record(.decoded, quality: .thumbnailFast))
    #expect(second.total == 2)
    #expect(second.decoded == 1)
    #expect(abs(second.hitRate - 0.5) < 0.001)
}

@Test func galleryPriorityPlannerFollowsScrollDirection() async throws {
    let assets = (0..<4).map { index in
        LightboxAsset(
            id: "asset-\(index)",
            originalName: "asset-\(index).jpg",
            width: 100,
            height: 100,
            tags: [],
            addedAt: Date(timeIntervalSince1970: Double(index)),
            palette: MockPalette.imported[0]
        )
    }
    let frames = [
        "asset-0": CGRect(x: 0, y: -410, width: 100, height: 100),
        "asset-1": CGRect(x: 0, y: 100, width: 100, height: 100),
        "asset-2": CGRect(x: 0, y: 820, width: 100, height: 100),
        "asset-3": CGRect(x: 0, y: 1_300, width: 100, height: 100)
    ]

    let scrollingUp = GalleryImagePriorityPlanner.prioritizedAssetIDs(
        activeAssets: assets,
        assetFrames: frames,
        viewportHeight: 600,
        scrollDirection: .up
    )
    let scrollingDown = GalleryImagePriorityPlanner.prioritizedAssetIDs(
        activeAssets: assets,
        assetFrames: frames,
        viewportHeight: 600,
        scrollDirection: .down
    )

    #expect(scrollingUp.contains("asset-0"))
    #expect(!scrollingUp.contains("asset-2"))
    #expect(!scrollingDown.contains("asset-0"))
    #expect(scrollingDown.contains("asset-2"))
}

@Test func galleryPriorityPlannerCapsHighPriorityDecodeWindow() async throws {
    let assets = (0..<80).map { index in
        LightboxAsset(
            id: "asset-\(index)",
            originalName: "asset-\(index).jpg",
            width: 100,
            height: 100,
            tags: [],
            addedAt: Date(timeIntervalSince1970: Double(index)),
            palette: MockPalette.imported[0]
        )
    }
    let frames = Dictionary(uniqueKeysWithValues: assets.enumerated().map { index, asset in
        (asset.id, CGRect(x: 0, y: CGFloat(index * 80), width: 100, height: 70))
    })

    let prioritized = GalleryImagePriorityPlanner.prioritizedAssetIDs(
        activeAssets: assets,
        assetFrames: frames,
        viewportHeight: 4_000,
        scrollDirection: .down
    )

    #expect(prioritized.count <= GalleryImagePriorityPlanner.maxPrioritizedAssetCount)
}

@Test func prioritizedGalleryImagesUpgradeToFullThumbnailQuality() async throws {
    #expect(
        GalleryImagePriorityPlanner.displayQuality(baseQuality: .thumbnailFast, isPrioritized: true)
        == .thumbnail
    )
    #expect(
        GalleryImagePriorityPlanner.displayQuality(baseQuality: .thumbnailBalanced, isPrioritized: true)
        == .thumbnail
    )
    #expect(
        GalleryImagePriorityPlanner.displayQuality(baseQuality: .thumbnailFast, isPrioritized: false)
        == .thumbnailFast
    )
    #expect(
        GalleryImagePriorityPlanner.displayQuality(
            baseQuality: .thumbnailFast,
            isPrioritized: true,
            prefersFastRawThumbnails: true
        )
        == .thumbnailBalanced
    )
    #expect(
        GalleryImagePriorityPlanner.displayQuality(
            baseQuality: .thumbnailBalanced,
            isPrioritized: true,
            prefersFastRawThumbnails: true
        )
        == .thumbnailBalanced
    )
    #expect(
        GalleryImagePriorityPlanner.displayQuality(
            baseQuality: .thumbnailFast,
            isPrioritized: true,
            permitsFullThumbnailPromotion: false
        )
        == .thumbnailBalanced
    )
    #expect(
        GalleryImagePriorityPlanner.displayQuality(
            baseQuality: .thumbnailBalanced,
            isPrioritized: true,
            permitsFullThumbnailPromotion: false
        )
        == .thumbnailBalanced
    )
}

@Test func compatibilityGalleryProfileUsesLighterImageLoadingPolicy() async throws {
    let normal = GalleryPerformanceProfile(isCompatibilityMode: false)
    let compatibility = GalleryPerformanceProfile(isCompatibilityMode: true)

    #expect(normal.initialImageLoadWindow(prefersFastRawThumbnails: false) == 48)
    #expect(compatibility.initialImageLoadWindow(prefersFastRawThumbnails: false) == 30)
    #expect(normal.maxPrioritizedAssetCount == 36)
    #expect(compatibility.maxPrioritizedAssetCount == 24)
    #expect(!normal.reducesHoverEffects)
    #expect(compatibility.reducesHoverEffects)
    #expect(normal.thumbnailQuality(assetCount: 101, isExternalSource: false) == .thumbnail)
    #expect(compatibility.thumbnailQuality(assetCount: 101, isExternalSource: false) == .thumbnailBalanced)
    #expect(compatibility.thumbnailQuality(assetCount: 300, isExternalSource: false) == .thumbnailFast)
    #expect(
        compatibility.preloadMargin(viewportHeight: 1_000, prefersFastRawThumbnails: false)
        < normal.preloadMargin(viewportHeight: 1_000, prefersFastRawThumbnails: false)
    )
}

@Test func compatibilityImageCacheProfileLowersMemoryAndDecodePressure() async throws {
    let normal = ImageCacheMemoryProfile(isCompatibilityMode: false)
    let compatibility = ImageCacheMemoryProfile(isCompatibilityMode: true)

    #expect(compatibility.thumbnailCountLimit < normal.thumbnailCountLimit)
    #expect(compatibility.thumbnailTotalCostLimit < normal.thumbnailTotalCostLimit)
    #expect(compatibility.comparisonCountLimit < normal.comparisonCountLimit)
    #expect(compatibility.comparisonTotalCostLimit < normal.comparisonTotalCostLimit)
    #expect(compatibility.decodeConcurrency < normal.decodeConcurrency)
}

@Test func imageProbeSwapsDimensionsForRotatedOrientations() async throws {
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: 5) == CGSize(width: 2000, height: 3000))
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: 6) == CGSize(width: 2000, height: 3000))
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: 7) == CGSize(width: 2000, height: 3000))
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: 8) == CGSize(width: 2000, height: 3000))
}

@Test func imageProbeKeepsDimensionsForNonRotatedOrientations() async throws {
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: nil) == CGSize(width: 3000, height: 2000))
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: 1) == CGSize(width: 3000, height: 2000))
    #expect(ImageProbe.displaySize(pixelWidth: 3000, pixelHeight: 2000, orientation: 3) == CGSize(width: 3000, height: 2000))
}

@Test func gallerySorterSupportsRequestedFields() async throws {
    let older = LightboxAsset(
        originalName: "b.png",
        width: 100,
        height: 100,
        tags: [],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/b.png"),
        addedAt: Date(timeIntervalSince1970: 10),
        fileSize: 200,
        palette: MockPalette.imported[0]
    )
    let newer = LightboxAsset(
        originalName: "a.jpg",
        width: 100,
        height: 100,
        tags: ["Blue"],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/a.jpg"),
        addedAt: Date(timeIntervalSince1970: 20),
        fileSize: 100,
        palette: MockPalette.imported[1]
    )
    let taggedFirst = LightboxAsset(
        originalName: "c.raw",
        width: 100,
        height: 100,
        tags: ["Red"],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/c.raw"),
        addedAt: Date(timeIntervalSince1970: 15),
        fileSize: 300,
        palette: MockPalette.imported[2]
    )
    let assets = [older, newer, taggedFirst]

    #expect(GalleryAssetSorter.sorted(assets, field: .time, direction: .descending).map(\.originalName) == ["a.jpg", "c.raw", "b.png"])
    #expect(GalleryAssetSorter.sorted(assets, field: .size, direction: .ascending).map(\.originalName) == ["a.jpg", "b.png", "c.raw"])
    #expect(GalleryAssetSorter.sorted(assets, field: .tag, direction: .ascending).map(\.originalName) == ["c.raw", "a.jpg", "b.png"])
    #expect(GalleryAssetSorter.sorted(assets, field: .tag, direction: .descending).map(\.originalName) == ["b.png", "a.jpg", "c.raw"])
    #expect(GalleryAssetSorter.sorted(assets, field: .type, direction: .ascending).map(\.originalName) == ["a.jpg", "b.png", "c.raw"])
}

@Test func localImageSourceRecognizesCommonRawFormats() async throws {
    let extensions = ["DNG", "CR2", "CR3", "NEF", "ARW", "RAF", "RW2", "ORF", "PEF", "SRW", "X3F", "IIQ", "FFF"]
    for pathExtension in extensions {
        let url = URL(fileURLWithPath: "/tmp/lightbox/raw-sample.\(pathExtension)")
        #expect(LocalImageSource.isSupportedImageURL(url))
    }
}

@Test func localImageSourceLoadsSystemTrashImagesFromFolders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxSystemTrashTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let imageURL = root.appendingPathComponent("trashed.jpg")
    let ignoredURL = root.appendingPathComponent("archive.zip")
    try Data("not-real-image-but-supported-extension".utf8).write(to: imageURL)
    try Data("zip".utf8).write(to: ignoredURL)

    let assets = LocalImageSource.loadSystemTrashAssets(in: [root])
    let allAssetsAreDeleted = assets.allSatisfy { $0.isDeleted }

    #expect(assets.map(\.originalName) == ["trashed.jpg"])
    #expect(allAssetsAreDeleted)
}

@Test func libraryStoreRestoreDestinationRoundTrips() async throws {
    let suiteName = "LightboxRestoreDestinationTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let originalURL = URL(fileURLWithPath: "/tmp/lightbox/original/photo.jpg")
    let trashURL = URL(fileURLWithPath: "/tmp/lightbox/.Trash/photo.jpg")

    LightboxLibraryStore.recordRestoreDestination(
        originalURL: originalURL,
        trashURL: trashURL,
        defaults: defaults
    )

    #expect(LightboxLibraryStore.restoreDestination(forTrashURL: trashURL, defaults: defaults) == originalURL)

    LightboxLibraryStore.clearRestoreDestination(forTrashURL: trashURL, defaults: defaults)
    #expect(LightboxLibraryStore.restoreDestination(forTrashURL: trashURL, defaults: defaults) == nil)
}

@Test func libraryStoreRestoresFromRecordedDestination() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxRestoreTests-\(UUID().uuidString)", isDirectory: true)
    let originalFolder = root.appendingPathComponent("original", isDirectory: true)
    let fakeTrashFolder = root.appendingPathComponent(".Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fakeTrashFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let suiteName = "LightboxRestoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let originalURL = originalFolder.appendingPathComponent("photo.jpg")
    let trashURL = fakeTrashFolder.appendingPathComponent("photo.jpg")
    try Data("image".utf8).write(to: trashURL)

    LightboxLibraryStore.recordRestoreDestination(
        originalURL: originalURL,
        trashURL: trashURL,
        defaults: defaults
    )

    #expect(LightboxLibraryStore.restoreFromRecordedDestination(trashURL, defaults: defaults))
    #expect(FileManager.default.fileExists(atPath: originalURL.path))
    #expect(!FileManager.default.fileExists(atPath: trashURL.path))
    #expect(LightboxLibraryStore.restoreDestination(forTrashURL: trashURL, defaults: defaults) == nil)
}

@Test func librarySourceStorePersistsLastSessionFolder() async throws {
    let suiteName = "LightboxLastSessionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let sourceRoot = URL(fileURLWithPath: "/tmp/lightbox/source", isDirectory: true)
    let folderURL = sourceRoot.appendingPathComponent("nested/folder", isDirectory: true)
    let source = LibrarySource(
        id: "external-source",
        name: "Source",
        rootURL: sourceRoot,
        kind: .external
    )

    LibrarySourceStore.saveLastSession(source: source, folderURL: folderURL, defaults: defaults)
    let loaded = try #require(LibrarySourceStore.loadLastSession(defaults: defaults))

    #expect(loaded.sourceID == source.id)
    #expect(loaded.sourceName == source.displayName)
    #expect(loaded.sourceKind == .external)
    #expect(loaded.sourceRootURL == sourceRoot.standardizedFileURL)
    #expect(loaded.folderURL == folderURL.standardizedFileURL)
}

@Test func fastThumbnailOptionsPreferEmbeddedPreviews() async throws {
    let options = ImageCache.thumbnailCreationOptions(
        maxPixelSize: 512,
        prefersEmbeddedPreview: ImageCacheQuality.thumbnailFast.prefersEmbeddedPreview
    )

    #expect(options[kCGImageSourceCreateThumbnailFromImageIfAbsent] as? Bool == true)
    #expect(options[kCGImageSourceCreateThumbnailFromImageAlways] == nil)
    #expect(options[kCGImageSourceThumbnailMaxPixelSize] as? Int == 512)
}

@Test func visibleThumbnailOptionsForceFullImageDownsample() async throws {
    let options = ImageCache.thumbnailCreationOptions(
        maxPixelSize: 1024,
        prefersEmbeddedPreview: ImageCacheQuality.thumbnail.prefersEmbeddedPreview
    )

    #expect(options[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool == true)
    #expect(options[kCGImageSourceCreateThumbnailFromImageIfAbsent] == nil)
    #expect(options[kCGImageSourceThumbnailMaxPixelSize] as? Int == 1024)
}

@Test func glowColorHexUsesSRGBComponentsWithoutChannelDrift() async throws {
    let color = NSColor(srgbRed: 0.25, green: 0.50, blue: 0.75, alpha: 1)
    let hex = LightboxGlowColor.hex(from: color)

    #expect(hex == "#4080BF")
    #expect(LightboxGlowColor.color(fromHex: hex) != nil)
}

@Test func sidebarSettingsClampWidthAndPersistVisibleLocations() async throws {
    #expect(LightboxSettingsStore.clampSidebarWidth(120) == LightboxSettingsStore.sidebarWidthRange.lowerBound)
    #expect(LightboxSettingsStore.clampSidebarWidth(420) == LightboxSettingsStore.sidebarWidthRange.upperBound)

    let previous = LightboxSettingsStore.loadSidebarVisibleLocationIDs()
    let previousShowFolderCards = LightboxSettingsStore.loadShowFolderCards()
    defer {
        LightboxSettingsStore.saveSidebarVisibleLocationIDs(previous)
        LightboxSettingsStore.saveShowFolderCards(previousShowFolderCards)
    }

    let ids: Set<SidebarLocationID> = [.desktop, .pictures]
    LightboxSettingsStore.saveSidebarVisibleLocationIDs(ids)
    LightboxSettingsStore.saveShowFolderCards(false)

    #expect(LightboxSettingsStore.loadSidebarVisibleLocationIDs() == ids)
    #expect(LightboxSettingsStore.loadShowFolderCards() == false)
}

@Test func sidebarLocationIDsCoverFinderStyleFolders() async throws {
    #expect(SidebarLocationID.allCases == [
        .applications,
        .desktop,
        .documents,
        .downloads,
        .movies,
        .music,
        .pictures,
        .iCloudDrive,
        .volumes
    ])

    #expect(SidebarLocationID.applications.defaultURL?.path == "/Applications")
    #expect(SidebarLocationID.volumes.defaultURL?.path == "/Volumes")
    #expect(SidebarLocationID.documents.defaultURL?.lastPathComponent == "Documents")
    #expect(SidebarLocationID.movies.systemImage == "film")
    #expect(SidebarLocationID.music.systemImage == "music.note")
}

@Test func localizationTablesCoverEveryTextKey() async throws {
    for key in LightboxTextKey.allCases {
        #expect(LightboxLocalization.hasTranslation(key, language: .english), "Missing English translation for \(key.rawValue)")
        #expect(LightboxLocalization.hasTranslation(key, language: .simplifiedChinese), "Missing Chinese translation for \(key.rawValue)")
        #expect(LightboxLocalization.hasTranslation(key, language: .japanese), "Missing Japanese translation for \(key.rawValue)")
    }
}

@Test func colorTagNamesAreLocalizedForFilterHelp() async throws {
    #expect(LightboxLocalization.colorTagName("Red", language: .simplifiedChinese) == "红色")
    #expect(LightboxLocalization.colorTagName("Blue", language: .japanese) == "青")
    #expect(LightboxLocalization.filterColorTag("Green", language: .english) == "Filter Green")
    #expect(LightboxLocalization.filterColorTag("Purple", language: .simplifiedChinese) == "筛选紫色标签")
}

@Test func updateCheckerChoosesMainReleaseAsset() async throws {
    let result = try LightboxUpdateChecker.checkResult(
        from: sampleReleaseData(tag: "v1.3.1"),
        currentVersion: "1.3.0",
        compatibility: false
    )

    guard case let .updateAvailable(version, _, assetURL) = result else {
        Issue.record("Expected update to be available")
        return
    }

    #expect(version == "1.3.1")
    #expect(assetURL.lastPathComponent == "Lightbox-v1.3.1.zip")
}

@Test func updateCheckerChoosesIntelReleaseAssetForCompatibilityBuild() async throws {
    let result = try LightboxUpdateChecker.checkResult(
        from: sampleReleaseData(tag: "v1.3.1"),
        currentVersion: "1.3.0",
        compatibility: true
    )

    guard case let .updateAvailable(_, _, assetURL) = result else {
        Issue.record("Expected update to be available")
        return
    }

    #expect(assetURL.lastPathComponent == "Lightbox-Intel-x86-v1.3.1.zip")
}

@Test func updateCheckerComparesSemanticVersionNumbers() async throws {
    #expect(LightboxUpdateChecker.isVersion("1.10.0", newerThan: "1.9.9"))
    #expect(!LightboxUpdateChecker.isVersion("1.3.0", newerThan: "1.3"))
    #expect(!LightboxUpdateChecker.isVersion("v1.3.0", newerThan: "1.3.1"))
}

private func makeTestImage() -> NSImage? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }

    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.addRepresentation(bitmap)
    return image
}

private func sampleReleaseData(tag: String) throws -> Data {
    let json = """
    {
      "tag_name": "\(tag)",
      "html_url": "https://github.com/a11oydyyy/Lightbox/releases/tag/\(tag)",
      "assets": [
        {
          "name": "Lightbox-Intel-x86-v1.3.1.zip",
          "browser_download_url": "https://github.com/a11oydyyy/Lightbox/releases/download/\(tag)/Lightbox-Intel-x86-v1.3.1.zip"
        },
        {
          "name": "Lightbox-v1.3.1.zip",
          "browser_download_url": "https://github.com/a11oydyyy/Lightbox/releases/download/\(tag)/Lightbox-v1.3.1.zip"
        }
      ]
    }
    """

    return try #require(json.data(using: .utf8))
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}
