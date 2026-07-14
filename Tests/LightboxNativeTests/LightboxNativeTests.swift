import Testing
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SQLite3
@testable import LightboxNative

private final class LightboxTestUserDefaults: UserDefaults {
    private let storageLock = NSLock()
    private var storage: [String: Any] = [:]

    init?(testSuiteName: String = "LightboxTests-\(UUID().uuidString)") {
        super.init(suiteName: testSuiteName)
    }

    override func object(forKey defaultName: String) -> Any? {
        storageLock.withLock { storage[defaultName] }
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storageLock.withLock {
            storage[defaultName] = value
        }
    }

    override func removeObject(forKey defaultName: String) {
        _ = storageLock.withLock {
            storage.removeValue(forKey: defaultName)
        }
    }
}

@MainActor
private func makeTestAppState(
    indexDatabaseURL: URL? = nil,
    libraryDefaults: UserDefaults? = nil,
    previewDimensionProbe: @escaping @Sendable (URL) -> CGSize? = {
        ImageProbe.dimensions(for: $0)
    },
    systemTrashMover: @escaping @Sendable (URL) -> Bool = {
        LightboxLibraryStore.moveToSystemTrash($0)
    },
    finderTagWriter: @escaping @Sendable ([String], URL) -> Bool = {
        FinderTagStore.setColorTags($0, for: $1)
    }
) -> AppState {
    let databaseURL = indexDatabaseURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxAppStateTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("index.sqlite")
    let defaults = libraryDefaults ?? LightboxTestUserDefaults()!
    return AppState(
        indexDatabaseURL: databaseURL,
        libraryDefaults: defaults,
        previewDimensionProbe: previewDimensionProbe,
        systemTrashMover: systemTrashMover,
        finderTagWriter: finderTagWriter
    )
}

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
    let appState = makeTestAppState()
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
    let appState = makeTestAppState()
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
    let appState = makeTestAppState()
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
    let appState = makeTestAppState()
    let asset = previewRouteAsset(id: "asset-a", name: "a.jpg", addedAt: 0)
    let firstFrame = CGRect(x: 20, y: 30, width: 120, height: 160)
    let secondFrame = CGRect(x: 260, y: 30, width: 120, height: 160)

    appState.assets = [asset]
    appState.updatePreviewSpaceAssetFrames([asset.id: firstFrame])
    #expect(appState.previewSpaceFrame(for: asset.id) == firstFrame)

    appState.updatePreviewSpaceAssetFrames([asset.id: secondFrame])
    #expect(appState.previewSpaceFrame(for: asset.id) == secondFrame)
}

@MainActor
@Test func previewCanOpenAssetOutsideCurrentFolderSnapshot() async throws {
    let appState = makeTestAppState()
    let searchResultAsset = previewRouteAsset(id: "search-result-a", name: "result.jpg", addedAt: 0)

    appState.assets = []
    appState.showPreview(for: searchResultAsset, sourceFrame: CGRect(x: 40, y: 80, width: 120, height: 160))

    #expect(appState.previewAssetID == searchResultAsset.id)
    #expect(appState.previewAsset?.id == searchResultAsset.id)

    appState.closePreview()
}

@MainActor
@Test func previewCanResolveAndOpenAssetOutsideCurrentFolderSnapshot() async throws {
    let appState = makeTestAppState(previewDimensionProbe: { _ in
        CGSize(width: 640, height: 480)
    })
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    let imageURL = URL(fileURLWithPath: "/tmp/lightbox-preview-search-result.jpg")
    let searchResultAsset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 1,
        height: 1,
        tags: [],
        sourceURL: imageURL,
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: false
    )

    appState.assets = []
    appState.showPreview(for: searchResultAsset)

    #expect(await waitForLightboxState {
        appState.previewAssetID == searchResultAsset.id
            && appState.previewAsset?.metadataLoaded == true
    })
    #expect(appState.previewAsset?.width == 640)
    #expect(appState.previewAsset?.height == 480)
    appState.closePreview()
}

@MainActor
@Test func previewDimensionResolveDoesNotBlockMainActorAndPresentsCorrectSize() async throws {
    let probeGate = DispatchSemaphore(value: 0)
    let appState = makeTestAppState(previewDimensionProbe: { _ in
        probeGate.wait()
        return CGSize(width: 640, height: 480)
    })
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    let imageURL = URL(fileURLWithPath: "/tmp/lightbox-preview-background-probe.jpg")
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 1,
        height: 1,
        tags: [],
        sourceURL: imageURL,
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: false
    )
    appState.assets = [asset]

    Task.detached {
        try? await Task.sleep(for: .milliseconds(300))
        probeGate.signal()
    }

    let clock = ContinuousClock()
    let startedAt = clock.now
    appState.showPreview(for: asset, sourceFrame: CGRect(x: 20, y: 30, width: 120, height: 160))
    let callDuration = startedAt.duration(to: clock.now)

    #expect(callDuration < .milliseconds(100))
    #expect(await waitForLightboxState {
        appState.previewAsset?.metadataLoaded == true
    })
    #expect(appState.previewAsset?.width == 640)
    #expect(appState.previewAsset?.height == 480)
    appState.closePreview()
}

@MainActor
@Test func consecutivePreviewStepsAdvancePastPendingSlowProbe() async throws {
    let appState = makeTestAppState(previewDimensionProbe: { url in
        Thread.sleep(forTimeInterval: 0.2)
        return url.lastPathComponent == "b.jpg"
            ? CGSize(width: 200, height: 100)
            : CGSize(width: 300, height: 100)
    })
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    let root = URL(fileURLWithPath: "/tmp/lightbox-preview-step-sequence", isDirectory: true)
    let first = LightboxAsset(
        originalName: "a.jpg",
        width: 100,
        height: 100,
        tags: [],
        sourceURL: root.appendingPathComponent("a.jpg"),
        addedAt: Date(timeIntervalSince1970: 3),
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )
    let second = LightboxAsset(
        originalName: "b.jpg",
        width: 1,
        height: 1,
        tags: [],
        sourceURL: root.appendingPathComponent("b.jpg"),
        addedAt: Date(timeIntervalSince1970: 2),
        palette: MockPalette.imported[1],
        metadataLoaded: false
    )
    let third = LightboxAsset(
        originalName: "c.jpg",
        width: 1,
        height: 1,
        tags: [],
        sourceURL: root.appendingPathComponent("c.jpg"),
        addedAt: Date(timeIntervalSince1970: 1),
        palette: MockPalette.imported[2],
        metadataLoaded: false
    )
    appState.assets = [first, second, third]
    appState.showPreview(for: first)

    appState.stepPreview(.next)
    appState.stepPreview(.next)

    #expect(await waitForLightboxState {
        appState.previewAssetID == third.id && appState.previewAsset?.metadataLoaded == true
    })
    #expect(appState.previewAsset?.width == 300)
    appState.closePreview()
}

@MainActor
@Test func previewDimensionResolveDoesNotOpenOldAssetAfterFolderNavigation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxPreviewFolderNavigationTests-\(UUID().uuidString)", isDirectory: true)
    let nextFolder = root.appendingPathComponent("Next", isDirectory: true)
    try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let probeStarted = DispatchSemaphore(value: 0)
    let probeGate = DispatchSemaphore(value: 0)
    defer { probeGate.signal() }
    let appState = makeTestAppState(previewDimensionProbe: { _ in
        probeStarted.signal()
        probeGate.wait()
        return CGSize(width: 640, height: 480)
    })
    let source = LibrarySource.favorites(rootURL: root)
    appState.sources = [source]
    appState.chooseSource(source.id)
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })

    let oldAsset = LightboxAsset(
        originalName: "old.jpg",
        width: 1,
        height: 1,
        tags: [],
        sourceURL: root.appendingPathComponent("old.jpg"),
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: false
    )
    appState.assets = [oldAsset]
    appState.showPreview(for: oldAsset)
    #expect(await waitForLightboxState {
        probeStarted.wait(timeout: .now()) == .success
    })

    appState.openFolder(LibraryFolderEntry(
        sourceID: source.id,
        url: nextFolder,
        rootURL: root
    ))
    #expect(await waitForLightboxState {
        appState.currentFolderURL == nextFolder.standardizedFileURL
            && appState.libraryLoadingStatus == nil
    })
    probeGate.signal()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(appState.previewAssetID == nil)
}

@MainActor
@Test func previewDimensionResolveDoesNotOpenOldAssetAfterSourceNavigation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxPreviewSourceNavigationTests-\(UUID().uuidString)", isDirectory: true)
    let firstRoot = root.appendingPathComponent("First", isDirectory: true)
    let secondRoot = root.appendingPathComponent("Second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let probeStarted = DispatchSemaphore(value: 0)
    let probeGate = DispatchSemaphore(value: 0)
    defer { probeGate.signal() }
    let appState = makeTestAppState(previewDimensionProbe: { _ in
        probeStarted.signal()
        probeGate.wait()
        return CGSize(width: 640, height: 480)
    })
    let firstSource = LibrarySourceStore.makeExternalSource(rootURL: firstRoot)
    let secondSource = LibrarySourceStore.makeExternalSource(rootURL: secondRoot)
    appState.sources = [firstSource, secondSource]
    appState.chooseSource(firstSource.id)
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })

    let oldAsset = LightboxAsset(
        originalName: "old.jpg",
        width: 1,
        height: 1,
        tags: [],
        sourceURL: firstRoot.appendingPathComponent("old.jpg"),
        addedAt: .now,
        palette: MockPalette.imported[0],
        metadataLoaded: false
    )
    appState.assets = [oldAsset]
    appState.showPreview(for: oldAsset)
    #expect(await waitForLightboxState {
        probeStarted.wait(timeout: .now()) == .success
    })

    appState.chooseSource(secondSource.id)
    #expect(await waitForLightboxState {
        appState.selectedSourceID == secondSource.id
            && appState.currentFolderURL == secondRoot.standardizedFileURL
            && appState.libraryLoadingStatus == nil
    })
    probeGate.signal()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(appState.previewAssetID == nil)
}

@MainActor
@Test func movingSelectionToTrashDoesNotBlockAndKeepsFailures() async throws {
    let successURL = URL(fileURLWithPath: "/tmp/lightbox-trash-success.jpg")
    let failureURL = URL(fileURLWithPath: "/tmp/lightbox-trash-failure.jpg")
    let appState = makeTestAppState(systemTrashMover: { url in
        if url.standardizedFileURL == successURL.standardizedFileURL {
            Thread.sleep(forTimeInterval: 0.3)
            return true
        }
        return false
    })
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    let success = LightboxAsset(
        originalName: successURL.lastPathComponent,
        width: 100,
        height: 100,
        tags: [],
        sourceURL: successURL,
        addedAt: Date(timeIntervalSince1970: 2),
        palette: MockPalette.imported[0]
    )
    let failure = LightboxAsset(
        originalName: failureURL.lastPathComponent,
        width: 100,
        height: 100,
        tags: [],
        sourceURL: failureURL,
        addedAt: Date(timeIntervalSince1970: 1),
        palette: MockPalette.imported[1]
    )
    appState.assets = [success, failure]
    appState.selectedAssetIDs = [success.id, failure.id]
    appState.selectedAssetID = success.id

    let clock = ContinuousClock()
    let startedAt = clock.now
    appState.deleteSelectedAssets()
    let callDuration = startedAt.duration(to: clock.now)

    #expect(callDuration < .milliseconds(100))
    #expect(await waitForLightboxState {
        appState.assets.map(\.id) == [failure.id]
    })
    #expect(appState.selectedAssetIDs == [failure.id])
    #expect(appState.selectedAssetID == failure.id)
}

@MainActor
@Test func movingAssetsToTrashQueuesSecondOperation() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/lightbox-trash-queue-first.jpg")
    let secondURL = URL(fileURLWithPath: "/tmp/lightbox-trash-queue-second.jpg")
    let firstStarted = DispatchSemaphore(value: 0)
    let firstGate = DispatchSemaphore(value: 0)
    let secondStarted = LockedCounter()
    defer { firstGate.signal() }
    let appState = makeTestAppState(systemTrashMover: { url in
        if url.standardizedFileURL == firstURL.standardizedFileURL {
            firstStarted.signal()
            firstGate.wait()
            return true
        }
        if url.standardizedFileURL == secondURL.standardizedFileURL {
            secondStarted.increment()
            return true
        }
        return false
    })
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    let first = LightboxAsset(
        originalName: firstURL.lastPathComponent,
        width: 100,
        height: 100,
        tags: [],
        sourceURL: firstURL,
        addedAt: Date(timeIntervalSince1970: 2),
        palette: MockPalette.imported[0]
    )
    let second = LightboxAsset(
        originalName: secondURL.lastPathComponent,
        width: 100,
        height: 100,
        tags: [],
        sourceURL: secondURL,
        addedAt: Date(timeIntervalSince1970: 1),
        palette: MockPalette.imported[1]
    )
    appState.assets = [first, second]

    appState.markDeleted(first)
    #expect(await waitForLightboxState {
        firstStarted.wait(timeout: .now()) == .success
    })
    appState.markDeleted(second)

    #expect(secondStarted.value == 0)
    firstGate.signal()
    #expect(await waitForLightboxState { appState.assets.isEmpty })
    #expect(secondStarted.value == 1)
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

@Test func indexStoreReturnsVisibleSnapshotWithoutTrustingDimensions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("cached.jpg")
    let folderURL = root.appendingPathComponent("Nested", isDirectory: true)
    try Data("cached".utf8).write(to: imageURL)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    let source = LibrarySource.favorites(rootURL: root)
    let folder = LibraryFolderEntry(sourceID: source.id, url: folderURL, rootURL: root, tags: ["Red"])
    let addedAt = Date(timeIntervalSince1970: 1_600_000_123)
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 321,
        height: 654,
        tags: ["Blue"],
        sourceURL: imageURL,
        addedAt: addedAt,
        fileSize: 6,
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )

    let store = LightboxIndexStore(databaseURL: databaseURL)
    store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [folder], assets: [asset])

    let snapshot = try #require(store.cachedVisibleSnapshot(source: source, folderURL: root))
    #expect(snapshot.folders.map(\.url.standardizedFileURL.path) == [folderURL.standardizedFileURL.path])
    #expect(snapshot.folders.first?.tags == ["Red"])
    #expect(snapshot.assets.map(\.sourceURL?.standardizedFileURL.path) == [imageURL.standardizedFileURL.path])
    #expect(snapshot.assets.first?.width == 1)
    #expect(snapshot.assets.first?.height == 1)
    #expect(snapshot.assets.first?.tags == ["Blue"])
    #expect(snapshot.assets.first?.addedAt == addedAt)
    #expect(snapshot.assets.first?.metadataLoaded == false)
}

@Test func indexStoreFallsBackToModificationTimeForLegacyAddedDate() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreLegacyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("legacy.jpg")
    let modificationTime: TimeInterval = 1_650_000_321
    try Data("legacy".utf8).write(to: imageURL)
    let source = LibrarySource.favorites(rootURL: root)

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let createSQL = """
    CREATE TABLE items (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        path TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        parent_path TEXT NOT NULL,
        is_directory INTEGER NOT NULL,
        mtime REAL,
        file_size INTEGER,
        width REAL,
        height REAL,
        tags TEXT NOT NULL DEFAULT '',
        metadata_loaded INTEGER NOT NULL DEFAULT 0,
        dimension_version INTEGER NOT NULL DEFAULT 0,
        indexed_at REAL NOT NULL
    );
    INSERT INTO items (
        id, source_id, path, relative_path, parent_path, is_directory,
        mtime, file_size, width, height, tags, metadata_loaded, dimension_version, indexed_at
    ) VALUES (
        'legacy-item', '\(source.id)', '\(imageURL.path)', 'legacy.jpg', '\(root.path)', 0,
        \(modificationTime), 6, NULL, NULL, '', 0, 0, \(modificationTime)
    );
    """
    #expect(sqlite3_exec(database, createSQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let store = LightboxIndexStore(databaseURL: databaseURL)
    let snapshot = try #require(store.cachedVisibleSnapshot(source: source, folderURL: root))
    #expect(snapshot.assets.first?.addedAt == Date(timeIntervalSince1970: modificationTime))
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

@Test func indexStoreIgnoresDimensionsAfterFileModificationTimeChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("modified.jpg")
    let originalModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    try Data("same-size".utf8).write(to: imageURL)
    try FileManager.default.setAttributes(
        [.modificationDate: originalModificationDate],
        ofItemAtPath: imageURL.path
    )

    let source = LibrarySource.favorites(rootURL: root)
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 1200,
        height: 800,
        tags: [],
        sourceURL: imageURL,
        addedAt: originalModificationDate,
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )
    let store = LightboxIndexStore(databaseURL: databaseURL)
    store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [], assets: [asset])

    try FileManager.default.setAttributes(
        [.modificationDate: originalModificationDate.addingTimeInterval(60)],
        ofItemAtPath: imageURL.path
    )

    #expect(store.cachedDimensions(sourceID: source.id, parentPath: root.path).isEmpty)
    let snapshot = try #require(store.cachedVisibleSnapshot(source: source, folderURL: root))
    #expect(snapshot.assets.first?.metadataLoaded == false)
    #expect(snapshot.assets.first?.width == 1)
    #expect(snapshot.assets.first?.height == 1)
}

@Test func indexStoreIgnoresDimensionsAfterFileSizeChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let imageURL = root.appendingPathComponent("replaced.jpg")
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    try Data("small".utf8).write(to: imageURL)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: imageURL.path)

    let source = LibrarySource.favorites(rootURL: root)
    let asset = LightboxAsset(
        originalName: imageURL.lastPathComponent,
        width: 3000,
        height: 2000,
        tags: [],
        sourceURL: imageURL,
        addedAt: modificationDate,
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )
    let store = LightboxIndexStore(databaseURL: databaseURL)
    store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [], assets: [asset])

    try Data("replacement-with-a-different-size".utf8).write(to: imageURL)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: imageURL.path)

    #expect(store.cachedDimensions(sourceID: source.id, parentPath: root.path).isEmpty)
}

@Test func indexStoreStopsSignatureValidationAfterCancellation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    let imageURLs = try (0..<3).map { index in
        let url = root.appendingPathComponent("cancel-\(index).jpg")
        try Data(repeating: UInt8(index), count: 8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
        return url
    }
    let source = LibrarySource.favorites(rootURL: root)
    let assets = imageURLs.enumerated().map { index, url in
        LightboxAsset(
            originalName: url.lastPathComponent,
            width: CGFloat(100 + index),
            height: CGFloat(200 + index),
            tags: [],
            sourceURL: url,
            addedAt: modificationDate,
            palette: MockPalette.imported[index % MockPalette.imported.count],
            metadataLoaded: true
        )
    }
    do {
        let seedStore = LightboxIndexStore(databaseURL: databaseURL)
        seedStore.replaceVisibleSnapshot(source: source, folderURL: root, folders: [], assets: assets)
    }

    let expectedSignature = FileContentSignature(
        modificationTime: modificationDate.timeIntervalSince1970,
        fileSize: 8
    )
    let cancelledBeforeReadCounter = TestCounter()
    let cancelledBeforeRead = await Task.detached {
        let store = LightboxIndexStore(
            databaseURL: databaseURL,
            fileSignatureResolver: { _ in
                cancelledBeforeReadCounter.increment()
                return expectedSignature
            }
        )
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return store.cachedDimensions(sourceID: source.id, parentPath: root.path)
    }.value

    #expect(cancelledBeforeRead.isEmpty)
    #expect(cancelledBeforeReadCounter.count == 0)

    let cancelledDuringReadCounter = TestCounter()
    let cancelledDuringRead = await Task.detached {
        let store = LightboxIndexStore(
            databaseURL: databaseURL,
            fileSignatureResolver: { _ in
                cancelledDuringReadCounter.increment()
                if cancelledDuringReadCounter.count == 1 {
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
                return expectedSignature
            }
        )
        return store.cachedDimensions(sourceID: source.id, parentPath: root.path)
    }.value

    #expect(cancelledDuringRead.isEmpty)
    #expect(cancelledDuringReadCounter.count == 1)
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

@Test @MainActor func assetImageDisplayStateKeepsThumbnailDuringQualityUpgrade() throws {
    let assetID = "file:/tmp/lightbox-preview-upgrade.jpg"
    let thumbnail = try #require(makeTestImage(size: 8))
    var state = AssetImageDisplayState(assetID: assetID, image: thumbnail)

    state.prepare(for: assetID, seed: nil)
    #expect(state.image === thumbnail)

    state.applyDecoded(nil, for: assetID)
    #expect(state.image === thumbnail)
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

@Test @MainActor func imageCacheReloadsFileReplacedAtSamePathWhenKnownSignatureIsStale() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg")
    try Data("first".utf8).write(to: sourceURL)
    let originalSignature = try #require(FileContentSignature(url: sourceURL))
    let firstImage = try #require(makeTestImage(size: 8))
    let replacementImage = try #require(makeTestImage(size: 16))
    let decodeCounter = LockedCounter()
    let cache = ImageCache { _, _ in
        decodeCounter.increment()
        return decodeCounter.value == 1 ? firstImage : replacementImage
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(
            for: sourceURL,
            quality: .preview,
            knownFileSignature: originalSignature
        ) { image in
            #expect(image?.size.width == 8)
            continuation.resume()
        }
    }

    try Data("replacement-with-a-different-size".utf8).write(to: sourceURL)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(
            for: sourceURL,
            quality: .preview,
            knownFileSignature: originalSignature
        ) { image in
            #expect(image?.size.width == 16)
            continuation.resume()
        }
    }
    #expect(decodeCounter.value == 2)
}

@Test @MainActor func imageCacheReloadsAtomicReplacementWithSameSizeAndModificationTime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg")
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try Data("first".utf8).write(to: sourceURL)
    try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sourceURL.path)
    let originalSignature = try #require(FileContentSignature(url: sourceURL))
    let firstImage = try #require(makeTestImage(size: 8))
    let replacementImage = try #require(makeTestImage(size: 16))
    let decodeCounter = LockedCounter()
    let cache = ImageCache { _, _ in
        decodeCounter.increment()
        return decodeCounter.value == 1 ? firstImage : replacementImage
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(
            for: sourceURL,
            quality: .preview,
            knownFileSignature: originalSignature
        ) { image in
            #expect(image?.size.width == 8)
            continuation.resume()
        }
    }

    try Data("other".utf8).write(to: sourceURL, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sourceURL.path)
    let replacementSignature = try #require(FileContentSignature(url: sourceURL))
    #expect(replacementSignature.fileSize == originalSignature.fileSize)
    #expect(replacementSignature.modificationTime == originalSignature.modificationTime)
    #expect(replacementSignature.cacheKeyComponent != originalSignature.cacheKeyComponent)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(
            for: sourceURL,
            quality: .preview,
            knownFileSignature: originalSignature
        ) { image in
            #expect(image?.size.width == 16)
            continuation.resume()
        }
    }
    #expect(decodeCounter.value == 2)
}

@Test @MainActor func imageCacheDoesNotCoalescePendingRequestsAcrossFileSignatures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg")
    try Data("first".utf8).write(to: sourceURL)
    let image = try #require(makeTestImage())
    let decodeCounter = LockedCounter()
    let cache = ImageCache(
        decodeImage: { _, _ in
            decodeCounter.increment()
            Thread.sleep(forTimeInterval: 0.1)
            return image
        },
        fileSignature: { _ in nil }
    )
    let firstSignature = FileContentSignature(modificationTime: 100, fileSize: 5)
    let replacementSignature = FileContentSignature(modificationTime: 101, fileSize: 33)
    var completionCount = 0

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let completion: @MainActor @Sendable (NSImage?) -> Void = { decodedImage in
            #expect(decodedImage != nil)
            completionCount += 1
            if completionCount == 2 {
                continuation.resume()
            }
        }

        _ = cache.image(
            for: sourceURL,
            quality: .preview,
            knownFileSignature: firstSignature,
            completion: completion
        )
        try? Data("replacement-with-a-different-size".utf8).write(to: sourceURL)
        _ = cache.image(
            for: sourceURL,
            quality: .preview,
            knownFileSignature: replacementSignature,
            completion: completion
        )
    }

    #expect(decodeCounter.value == 2)
}

@Test @MainActor func imageCacheValidatesKnownFileSignatureOffMainThread() async throws {
    let signatureResolveCounter = LockedCounter()
    let resolverRanOnMainThread = LockedFlag()
    let image = try #require(makeTestImage())
    let knownSignature = FileContentSignature(modificationTime: 100, fileSize: 200)
    let cache = ImageCache(
        decodeImage: { _, _ in image },
        fileSignature: { _ in
            signatureResolveCounter.increment()
            resolverRanOnMainThread.record(Thread.isMainThread)
            return knownSignature
        }
    )
    let missingURL = URL(fileURLWithPath: "/tmp/lightbox-known-signature-\(UUID().uuidString).jpg")

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(
            for: missingURL,
            quality: .preview,
            knownFileSignature: knownSignature
        ) { decodedImage in
            #expect(decodedImage != nil)
            continuation.resume()
        }
    }

    #expect(signatureResolveCounter.value == 1)
    #expect(!resolverRanOnMainThread.value)
    #expect(cache.bestCachedImage(
        for: missingURL,
        quality: .preview,
        knownFileSignature: knownSignature
    ) != nil)
    #expect(signatureResolveCounter.value == 1)

    #expect(cache.bestCachedImage(for: missingURL, quality: .preview) == nil)
    #expect(signatureResolveCounter.value == 1)
}

@Test @MainActor func imageCacheKeepsDecodedThumbnailReachableThroughKnownSignature() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let image = try #require(makeTestImage(size: 12))
    let knownSignature = FileContentSignature(modificationTime: 100, fileSize: 200)
    let resolvedSignature = FileContentSignature(
        modificationTime: 100,
        fileSize: 200,
        fileSystemIdentifier: "1:2",
        statusChangeTime: 101
    )
    let cache = ImageCache(
        diskCache: ThumbnailDiskCache(folder: root.appendingPathComponent("thumbnails", isDirectory: true)),
        decodeImage: { _, _ in image },
        fileSignature: { _ in resolvedSignature }
    )
    let url = root.appendingPathComponent("source.jpg")

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(
            for: url,
            quality: .thumbnail,
            knownFileSignature: knownSignature
        ) { decodedImage in
            #expect(decodedImage?.size.width == 12)
            continuation.resume()
        }
    }

    #expect(cache.bestCachedImage(
        for: url,
        quality: .preview,
        knownFileSignature: knownSignature
    )?.size.width == 12)
}

@Test @MainActor func assetImageRequestIdentityUsesContentModificationTimeInsteadOfAddedDate() async throws {
    let addedAt = Date(timeIntervalSince1970: 50)
    let sourceURL = URL(fileURLWithPath: "/tmp/lightbox-same-path.jpg")
    let original = LightboxAsset(
        originalName: sourceURL.lastPathComponent,
        width: 100,
        height: 100,
        tags: [],
        sourceURL: sourceURL,
        addedAt: addedAt,
        contentModifiedAt: Date(timeIntervalSince1970: 100),
        fileSize: 200,
        palette: MockPalette.imported[0]
    )
    var replacement = original
    replacement.contentModifiedAt = Date(timeIntervalSince1970: 101)

    #expect(replacement.addedAt == original.addedAt)
    #expect(replacement.fileSize == original.fileSize)
    #expect(AssetImageView.knownFileSignature(for: replacement) != AssetImageView.knownFileSignature(for: original))
    #expect(
        AssetImageView.imageRequestIdentity(for: replacement, quality: .preview, loadsImage: true)
            != AssetImageView.imageRequestIdentity(for: original, quality: .preview, loadsImage: true)
    )
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
    let original = FileContentSignature(modificationTime: 100, fileSize: 20)
    let changedSize = FileContentSignature(modificationTime: 100, fileSize: 21)
    let changedTime = FileContentSignature(modificationTime: 101, fileSize: 20)

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

@Test func thumbnailDiskCachePrunesOldestFilesWhenOverLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let oldestURL = root.appendingPathComponent("oldest.jpg")
    let middleURL = root.appendingPathComponent("middle.jpg")
    let newestURL = root.appendingPathComponent("newest.jpg")
    let files = [oldestURL, middleURL, newestURL]
    let futureDate = Date().addingTimeInterval(600)
    for (index, url) in files.enumerated() {
        try Data(repeating: UInt8(index), count: 60).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: futureDate.addingTimeInterval(TimeInterval(index))],
            ofItemAtPath: url.path
        )
    }

    let cache = ThumbnailDiskCache(
        folder: root,
        maxDiskBytes: 100,
        pruneInterval: 3600
    )
    cache.pruneIfNeeded(force: true)

    #expect(!FileManager.default.fileExists(atPath: oldestURL.path))
    #expect(!FileManager.default.fileExists(atPath: middleURL.path))
    #expect(FileManager.default.fileExists(atPath: newestURL.path))
}

@Test @MainActor func imageCacheMemoryResetKeepsThumbnailDiskCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg", isDirectory: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: sourceURL)

    let diskCache = ThumbnailDiskCache(folder: root.appendingPathComponent("thumbnails", isDirectory: true))
    let image = try #require(makeTestImage())
    let cache = ImageCache(diskCache: diskCache) { _, _ in image }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .thumbnailFast) { decodedImage in
            #expect(decodedImage != nil)
            continuation.resume()
        }
    }
    #expect(diskCache.image(for: sourceURL, quality: .thumbnailFast) != nil)

    cache.removeMemoryObjects(reason: "test")

    #expect(diskCache.image(for: sourceURL, quality: .thumbnailFast) != nil)
}

@Test @MainActor func imageCacheThumbnailMemoryResetKeepsPreviewAndComparisonCaches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg", isDirectory: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: sourceURL)
    let sourceSignature = try #require(FileContentSignature(url: sourceURL))

    let thumbnailImage = try #require(makeTestImage(size: 8))
    let previewImage = try #require(makeTestImage(size: 24))
    let comparisonImage = try #require(makeTestImage(size: 16))
    let cache = ImageCache(diskCache: ThumbnailDiskCache(folder: root.appendingPathComponent("thumbnails", isDirectory: true))) { _, quality in
        switch quality {
        case .preview:
            previewImage
        case .comparison:
            comparisonImage
        default:
            thumbnailImage
        }
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .thumbnailFast) { decodedImage in
            #expect(decodedImage?.size.width == 8)
            continuation.resume()
        }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .preview) { decodedImage in
            #expect(decodedImage?.size.width == 24)
            continuation.resume()
        }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .comparison) { decodedImage in
            #expect(decodedImage?.size.width == 16)
            continuation.resume()
        }
    }

    cache.removeThumbnailMemoryObjects(reason: "test")

    #expect(cache.bestCachedImage(
        for: sourceURL,
        quality: .thumbnailFast,
        knownFileSignature: sourceSignature
    ) == nil)
    #expect(cache.bestCachedImage(
        for: sourceURL,
        quality: .preview,
        knownFileSignature: sourceSignature
    )?.size.width == 24)
    #expect(cache.bestCachedImage(
        for: sourceURL,
        quality: .comparison,
        knownFileSignature: sourceSignature
    )?.size.width == 16)
}

@Test @MainActor func imageCacheSourceMemoryResetClearsComparisonButKeepsPreviewCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let sourceURL = root.appendingPathComponent("source.jpg", isDirectory: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: sourceURL)
    let sourceSignature = try #require(FileContentSignature(url: sourceURL))

    let thumbnailImage = try #require(makeTestImage(size: 8))
    let previewImage = try #require(makeTestImage(size: 24))
    let comparisonImage = try #require(makeTestImage(size: 16))
    let comparisonDecodeCount = TestCounter()
    let cache = ImageCache(diskCache: ThumbnailDiskCache(folder: root.appendingPathComponent("thumbnails", isDirectory: true))) { _, quality in
        switch quality {
        case .preview:
            return previewImage
        case .comparison:
            comparisonDecodeCount.increment()
            return comparisonImage
        default:
            return thumbnailImage
        }
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .thumbnailFast) { decodedImage in
            #expect(decodedImage?.size.width == 8)
            continuation.resume()
        }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .preview) { decodedImage in
            #expect(decodedImage?.size.width == 24)
            continuation.resume()
        }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .comparison) { decodedImage in
            #expect(decodedImage?.size.width == 16)
            continuation.resume()
        }
    }
    #expect(comparisonDecodeCount.count == 1)

    cache.removeSourceMemoryObjects(reason: "test")

    #expect(cache.bestCachedImage(
        for: sourceURL,
        quality: .thumbnailFast,
        knownFileSignature: sourceSignature
    ) == nil)
    #expect(cache.bestCachedImage(
        for: sourceURL,
        quality: .preview,
        knownFileSignature: sourceSignature
    )?.size.width == 24)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = cache.image(for: sourceURL, quality: .comparison) { decodedImage in
            #expect(decodedImage?.size.width == 16)
            continuation.resume()
        }
    }
    #expect(comparisonDecodeCount.count == 2)
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

@Test func galleryFrameLifecycleFiltersFramesForInactiveAssets() async throws {
    let previous = [
        "visible": CGRect(x: 0, y: 0, width: 100, height: 100),
        "offscreen": CGRect(x: 0, y: 120, width: 100, height: 100)
    ]

    let replacement = try #require(GalleryAssetFrameLifecycle.replacementFrames(
        current: previous,
        incoming: previous,
        activeAssetIDs: ["visible"]
    ))

    #expect(replacement == ["visible": previous["visible"]!])
}

@Test func galleryFrameLifecycleDropsFramesNoLongerReportedByLayout() async throws {
    let visibleFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let previous = [
        "visible": visibleFrame,
        "offscreen": CGRect(x: 0, y: 120, width: 100, height: 100)
    ]

    #expect(GalleryAssetFrameLifecycle.replacementFrames(
        current: previous,
        incoming: ["visible": visibleFrame],
        activeAssetIDs: Set(previous.keys)
    ) == ["visible": visibleFrame])
}

@Test func galleryFrameLifecycleReplacesFramesAfterItemReflow() async throws {
    let previous = [
        "first": CGRect(x: 0, y: 0, width: 100, height: 100),
        "second": CGRect(x: 0, y: 120, width: 100, height: 100)
    ]
    let reflowed = [
        "first": CGRect(x: 0, y: 0, width: 100, height: 160),
        "second": CGRect(x: 0, y: 180, width: 100, height: 100)
    ]

    #expect(GalleryAssetFrameLifecycle.replacementFrames(
        current: previous,
        incoming: reflowed,
        activeAssetIDs: Set(reflowed.keys)
    ) == reflowed)
}

@Test func galleryFrameLifecycleThrottlesSmallUniformScrollTranslations() async throws {
    let previous = [
        "first": CGRect(x: 0, y: 0, width: 100, height: 100),
        "second": CGRect(x: 0, y: 120, width: 100, height: 100)
    ]
    let scrolled = previous.mapValues { $0.offsetBy(dx: 0, dy: -8) }

    #expect(GalleryAssetFrameLifecycle.replacementFrames(
        current: previous,
        incoming: scrolled,
        activeAssetIDs: Set(scrolled.keys)
    ) == nil)
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
    #expect(normal.thumbnailQuality(assetCount: 101, usesConservativeExternalLoading: false) == .thumbnail)
    #expect(normal.thumbnailQuality(assetCount: 79, usesConservativeExternalLoading: true) == .thumbnail)
    #expect(normal.thumbnailQuality(assetCount: 80, usesConservativeExternalLoading: true) == .thumbnailBalanced)
    #expect(normal.thumbnailQuality(assetCount: 320, usesConservativeExternalLoading: true) == .thumbnailFast)
    #expect(compatibility.thumbnailQuality(assetCount: 101, usesConservativeExternalLoading: false) == .thumbnailBalanced)
    #expect(compatibility.thumbnailQuality(assetCount: 300, usesConservativeExternalLoading: false) == .thumbnailFast)
    #expect(normal.permitsFullThumbnailPromotion(assetCount: 79, usesConservativeExternalLoading: true))
    #expect(!normal.permitsFullThumbnailPromotion(assetCount: 80, usesConservativeExternalLoading: true))
    #expect(normal.permitsFullThumbnailPromotion(assetCount: 300, usesConservativeExternalLoading: false))
    #expect(!compatibility.permitsFullThumbnailPromotion(assetCount: 12, usesConservativeExternalLoading: false))
    #expect(
        compatibility.preloadMargin(viewportHeight: 1_000, prefersFastRawThumbnails: false)
        < normal.preloadMargin(viewportHeight: 1_000, prefersFastRawThumbnails: false)
    )
}

@Test func userFolderExternalSourcesKeepLocalImageLoadingPolicy() async throws {
    let fileManager = FileManager.default
    let home = FileManager.default.homeDirectoryForCurrentUser
    let gr3x = LibrarySource(
        id: "gr3x",
        name: "GR3X",
        rootURL: home.appendingPathComponent("Pictures/GR3X", isDirectory: true),
        kind: .external
    )
    let nas = LibrarySource(
        id: "nas",
        name: "NAS",
        rootURL: URL(fileURLWithPath: "/Volumes/home/Photos", isDirectory: true),
        kind: .external
    )
    let outsideHomeTarget = fileManager.temporaryDirectory
        .appendingPathComponent("LightboxSymlinkTarget-\(UUID().uuidString)", isDirectory: true)
    let homeSymlink = home
        .appendingPathComponent("Library/Caches/LightboxSymlinkSource-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: outsideHomeTarget, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: homeSymlink, withDestinationURL: outsideHomeTarget)
    defer {
        try? fileManager.removeItem(at: homeSymlink)
        try? fileManager.removeItem(at: outsideHomeTarget)
    }
    let symlinkedExternal = LibrarySource(
        id: "symlinked-external",
        name: "Symlinked External",
        rootURL: homeSymlink,
        kind: .external
    )
    let profile = GalleryPerformanceProfile(isCompatibilityMode: false)

    #expect(!gr3x.usesConservativeExternalLoading)
    #expect(nas.usesConservativeExternalLoading)
    #expect(symlinkedExternal.usesConservativeExternalLoading)
    #expect(
        profile.thumbnailQuality(
            assetCount: 120,
            usesConservativeExternalLoading: gr3x.usesConservativeExternalLoading
        ) == .thumbnail
    )
    #expect(
        profile.thumbnailQuality(
            assetCount: 120,
            usesConservativeExternalLoading: nas.usesConservativeExternalLoading
        ) == .thumbnailBalanced
    )
    #expect(
        profile.permitsFullThumbnailPromotion(
            assetCount: 120,
            usesConservativeExternalLoading: gr3x.usesConservativeExternalLoading
        )
    )
    #expect(
        !profile.permitsFullThumbnailPromotion(
            assetCount: 120,
            usesConservativeExternalLoading: nas.usesConservativeExternalLoading
        )
    )
}

@Test func assetMetadataRefreshPolicyLimitsExternalAssetTagsDuringNormalBrowsing() async throws {
    let local = AssetMetadataRefreshPolicy(usesConservativeExternalLoading: false)
    let external = AssetMetadataRefreshPolicy(usesConservativeExternalLoading: true)
    let externalTagFilter = AssetMetadataRefreshPolicy(
        usesConservativeExternalLoading: true,
        requiresCompleteAssetTags: true
    )

    #expect(local.dimensionLimit(assetCount: 110) == 110)
    #expect(local.tagLimit(assetCount: 110) == 110)
    #expect(local.startDelayMilliseconds == 650)
    #expect(external.dimensionLimit(assetCount: 110) == 110)
    #expect(external.dimensionLimit(assetCount: 3) == 3)
    #expect(external.tagLimit(assetCount: 110) == 12)
    #expect(external.tagLimit(assetCount: 20) == 12)
    #expect(external.startDelayMilliseconds == 1_600)
    #expect(externalTagFilter.tagLimit(assetCount: 110) == 110)
}

@MainActor
@Test func selectingTagFilterLoadsTagsBeyondExternalBrowsingLimit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxCompleteTagFilterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let testImage = try #require(makeTestImage(size: 8))
    let bitmap = try #require(testImage.representations.first as? NSBitmapImageRep)
    let imageData = try #require(bitmap.representation(using: .png, properties: [:]))
    for index in 0..<13 {
        try imageData.write(
            to: root.appendingPathComponent("image-\(index).png")
        )
    }

    let source = LibrarySourceStore.makeExternalSource(rootURL: root)
    let initialSnapshot = LocalImageSource.loadFolderSnapshot(
        in: root,
        sourceID: source.id,
        rootURL: root,
        probeMetadata: false
    )
    let taggedAsset = try #require(initialSnapshot.assets.dropFirst(12).first)
    let taggedURL = try #require(taggedAsset.sourceURL)
    #expect(FinderTagStore.setColorTags(["Red"], for: taggedURL))

    let appState = makeTestAppState()
    appState.openSource(source)
    #expect(await waitForLightboxState { appState.assets.count == 13 })
    #expect(appState.assets.first { $0.id == taggedAsset.id }?.tags.isEmpty == true)

    appState.selectedFilter = .tag("Red")

    #expect(await waitForLightboxState {
        appState.activeAssets.map(\.id) == [taggedAsset.id]
            && appState.assets.allSatisfy(\.metadataLoaded)
    })
}

@Test func libraryRefreshPolicyDelaysExternalScanWhenCachedSnapshotExists() async throws {
    #expect(
        LibraryRefreshPolicy(usesConservativeExternalLoading: true, hasCachedVisibleSnapshot: true).scanStartDelayMilliseconds
        == 1_200
    )
    #expect(
        LibraryRefreshPolicy(usesConservativeExternalLoading: true, hasCachedVisibleSnapshot: false).scanStartDelayMilliseconds
        == 0
    )
    #expect(
        LibraryRefreshPolicy(usesConservativeExternalLoading: false, hasCachedVisibleSnapshot: true).scanStartDelayMilliseconds
        == 0
    )
}

@Test func compatibilityImageCacheProfileLowersMemoryAndDecodePressure() async throws {
    let normal = ImageCacheMemoryProfile(isCompatibilityMode: false)
    let compatibility = ImageCacheMemoryProfile(isCompatibilityMode: true)

    #expect(compatibility.thumbnailCountLimit < normal.thumbnailCountLimit)
    #expect(compatibility.thumbnailTotalCostLimit < normal.thumbnailTotalCostLimit)
    #expect(compatibility.previewCountLimit < normal.previewCountLimit)
    #expect(compatibility.previewTotalCostLimit < normal.previewTotalCostLimit)
    #expect(compatibility.comparisonCountLimit < normal.comparisonCountLimit)
    #expect(compatibility.comparisonTotalCostLimit < normal.comparisonTotalCostLimit)
    #expect(compatibility.decodeConcurrency < normal.decodeConcurrency)
}

@Test func imageDecodePriorityMapsLowPriorityWorkToUtilityQoS() async throws {
    #expect(ImageDecodePriority.high.qualityOfService == .userInitiated)
    #expect(ImageDecodePriority.normal.qualityOfService == .userInitiated)
    #expect(ImageDecodePriority.low.qualityOfService == .utility)
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

    let equalTimeAssets = assets.map {
        LightboxAsset(
            originalName: $0.originalName,
            width: $0.width,
            height: $0.height,
            tags: $0.tags,
            sourceURL: $0.sourceURL,
            addedAt: Date(timeIntervalSince1970: 10),
            fileSize: $0.fileSize,
            palette: $0.palette
        )
    }
    #expect(GalleryAssetSorter.sorted(equalTimeAssets, field: .time, direction: .ascending).map(\.originalName) == ["a.jpg", "b.png", "c.raw"])
    #expect(GalleryAssetSorter.sorted(equalTimeAssets, field: .time, direction: .descending).map(\.originalName) == ["c.raw", "b.png", "a.jpg"])
}

@MainActor
@Test func appStateRebuildsActiveAssetsWhenSortChanges() async throws {
    let appState = makeTestAppState()
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
        tags: [],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/a.jpg"),
        addedAt: Date(timeIntervalSince1970: 20),
        fileSize: 100,
        palette: MockPalette.imported[1]
    )
    let middle = LightboxAsset(
        originalName: "c.raw",
        width: 100,
        height: 100,
        tags: [],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/c.raw"),
        addedAt: Date(timeIntervalSince1970: 15),
        fileSize: 300,
        palette: MockPalette.imported[2]
    )

    appState.assets = [older, newer, middle]

    #expect(appState.activeAssets.map(\.originalName) == ["a.jpg", "c.raw", "b.png"])

    appState.setSortField(.fileName)
    #expect(appState.activeAssets.map(\.originalName) == ["c.raw", "b.png", "a.jpg"])

    appState.toggleSortDirection()
    #expect(appState.activeAssets.map(\.originalName) == ["a.jpg", "b.png", "c.raw"])
}

@MainActor
@Test func appStateSortsActiveFoldersWhenSortDirectionChanges() async throws {
    let appState = makeTestAppState()
    let root = URL(fileURLWithPath: "/tmp/lightbox/source", isDirectory: true)
    appState.folderEntries = [
        LibraryFolderEntry(
            sourceID: "source",
            url: root.appendingPathComponent("Beta", isDirectory: true),
            rootURL: root
        ),
        LibraryFolderEntry(
            sourceID: "source",
            url: root.appendingPathComponent("Alpha", isDirectory: true),
            rootURL: root
        )
    ]

    appState.sortField = .fileName
    appState.sortDirection = .ascending
    #expect(appState.activeFolderEntries.map(\.name) == ["Alpha", "Beta"])

    appState.toggleSortDirection()
    #expect(appState.activeFolderEntries.map(\.name) == ["Beta", "Alpha"])
}

@MainActor
@Test func removingCurrentFilterTagFromAllVisibleAssetsClearsFilter() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxTagFilterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let firstURL = root.appendingPathComponent("first.jpg")
    let secondURL = root.appendingPathComponent("second.jpg")
    try Data("first".utf8).write(to: firstURL)
    try Data("second".utf8).write(to: secondURL)
    try writeFinderTags(["Red\n6"], to: firstURL)
    try writeFinderTags(["Red\n6"], to: secondURL)

    let first = LightboxAsset(
        originalName: "first.jpg",
        width: 100,
        height: 100,
        tags: ["Red"],
        sourceURL: firstURL,
        addedAt: Date(timeIntervalSince1970: 10),
        palette: MockPalette.imported[0]
    )
    let second = LightboxAsset(
        originalName: "second.jpg",
        width: 100,
        height: 100,
        tags: ["Red"],
        sourceURL: secondURL,
        addedAt: Date(timeIntervalSince1970: 20),
        palette: MockPalette.imported[1]
    )
    let appState = makeTestAppState()
    let source = LibrarySource.favorites(rootURL: root)
    appState.sources = [source]
    appState.chooseSource(source.id)
    #expect(await waitForLightboxState {
        Set(appState.assets.map(\.id)) == Set([first.id, second.id])
            && appState.assets.allSatisfy { $0.tags == ["Red"] }
            && appState.libraryLoadingStatus == nil
    })
    appState.selectedFilter = .tag("Red")

    appState.selectedAssetIDs = [first.id]
    appState.selectedAssetID = first.id
    appState.toggleTagForSelection("Red")
    #expect(await waitForLightboxState {
        appState.selectedFilter == .tag("Red")
            && appState.activeAssets.map(\.id) == [second.id]
    })

    appState.selectedAssetIDs = [second.id]
    appState.selectedAssetID = second.id
    appState.toggleTagForSelection("Red")
    #expect(await waitForLightboxState {
        appState.selectedFilter == .all
            && Set(appState.activeAssets.map(\.id)) == Set([first.id, second.id])
            && appState.activeAssets.allSatisfy { !$0.tags.contains("Red") }
    })
}

@MainActor
@Test func tagMutationsRunOffMainActorAndRemainSerialized() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxTagMutationTests-\(UUID().uuidString)", isDirectory: true)
    let imageURL = root.appendingPathComponent("image.jpg")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("image".utf8).write(to: imageURL)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let writeCounter = LockedCounter()
    let appState = makeTestAppState(finderTagWriter: { _, _ in
        writeCounter.increment()
        Thread.sleep(forTimeInterval: 0.12)
        return true
    })
    let source = LibrarySource.favorites(rootURL: root)
    appState.sources = [source]
    appState.chooseSource(source.id)
    #expect(await waitForLightboxState {
        appState.assets.contains { $0.sourceURL?.standardizedFileURL == imageURL.standardizedFileURL }
            && appState.libraryLoadingStatus == nil
    })
    let asset = try #require(appState.assets.first { $0.sourceURL?.standardizedFileURL == imageURL.standardizedFileURL })

    let startedAt = Date()
    appState.toggleTag("Red", to: asset)
    appState.toggleTag("Red", to: asset)
    #expect(Date().timeIntervalSince(startedAt) < 0.08)
    #expect(await waitForLightboxState {
        writeCounter.value == 2
            && appState.assets.first(where: { $0.id == asset.id })?.tags.isEmpty == true
    })
}

@Test func localImageSourceRecognizesCommonRawFormats() async throws {
    let extensions = ["DNG", "CR2", "CR3", "NEF", "ARW", "RAF", "RW2", "ORF", "PEF", "SRW", "X3F", "IIQ", "FFF"]
    for pathExtension in extensions {
        let url = URL(fileURLWithPath: "/tmp/lightbox/raw-sample.\(pathExtension)")
        #expect(LocalImageSource.isSupportedImageURL(url))
    }
}

@Test func searchQueryMatchesNamesOnly() async throws {
    let asset = LightboxAsset(
        originalName: "R0000305.JPG",
        width: 6_000,
        height: 4_000,
        tags: ["Red"],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/R0000305.JPG"),
        addedAt: .now,
        fileSize: 12 * 1024 * 1024,
        palette: MockPalette.imported[0],
        metadataLoaded: true
    )

    let query = LightboxSearchQuery.parse("r000")

    #expect(query.matches(asset))
    #expect(!LightboxSearchQuery.parse("kind:jpg").matches(asset))
    #expect(!LightboxSearchQuery.parse("tag:红色").matches(asset))
}

@Test func searchQueryFallsBackToFilenameForUnknownTokens() async throws {
    let asset = LightboxAsset(
        originalName: "camera:fuji-rose.jpg",
        width: 100,
        height: 100,
        tags: [],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/camera:fuji-rose.jpg"),
        addedAt: .now,
        palette: MockPalette.imported[0]
    )

    #expect(LightboxSearchQuery.parse("camera:fuji").matches(asset))
    #expect(!LightboxSearchQuery.parse("lens:canon").matches(asset))
}

@Test func searchQueryTreatsColonTokensAsNameTerms() async throws {
    let query = LightboxSearchQuery.parse("rose tag:red camera:fuji width:>3000")
    let asset = LightboxAsset(
        originalName: "rose tag:red camera:fuji width:>3000.jpg",
        width: 100,
        height: 100,
        tags: [],
        sourceURL: URL(fileURLWithPath: "/tmp/lightbox/rose tag:red camera:fuji width:>3000.jpg"),
        addedAt: .now,
        palette: MockPalette.imported[0]
    )

    #expect(query.matches(asset))
}

@Test func searchStatusDefaultsToCompleteResults() async throws {
    #expect(!LightboxSearchStatus(isSearching: false).limitReached)
}

@Test func searchQueryMatchesFolderNamesOnly() async throws {
    let root = URL(fileURLWithPath: "/tmp/lightbox/source", isDirectory: true)
    let folder = LibraryFolderEntry(
        sourceID: "source",
        url: root.appendingPathComponent("Trips/Rose Picks", isDirectory: true),
        rootURL: root,
        tags: ["Green"]
    )

    #expect(LightboxSearchQuery.parse("rose").matches(folder))
    #expect(!LightboxSearchQuery.parse("trips").matches(folder))
    #expect(!LightboxSearchQuery.parse("green").matches(folder))
    #expect(!LightboxSearchQuery.parse("tag:green").matches(folder))
}

@Test func localImageSourceFastFolderSnapshotKeepsSortMetadata() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxSortMetadataTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let image = root.appendingPathComponent("rose.jpg")
    try Data("image".utf8).write(to: image)

    let source = LibrarySourceStore.makeExternalSource(rootURL: root)
    let snapshot = LocalImageSource.loadFolderSnapshot(
        in: root,
        sourceID: source.id,
        rootURL: root,
        probeMetadata: false
    )

    let asset = try #require(snapshot.assets.first)
    #expect(asset.fileSize == 5)
    #expect(asset.addedAt != .distantPast)
}

@Test func localImageSourceCancelledFolderSnapshotStopsBeforeClassification() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxCancelledSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    for index in 0..<8 {
        try Data("image-\(index)".utf8).write(
            to: root.appendingPathComponent("image-\(index).jpg")
        )
    }

    let task = Task.detached {
        try? await Task.sleep(for: .milliseconds(200))
        return LocalImageSource.loadFolderSnapshot(
            in: root,
            sourceID: "cancelled-source",
            rootURL: root,
            probeMetadata: false,
            initialMetadataLimit: 8
        )
    }
    task.cancel()

    let snapshot = await task.value
    #expect(snapshot.availability == .unavailable(.cancelled))
    #expect(snapshot.entryCount == 0)
    #expect(snapshot.folders.isEmpty)
    #expect(snapshot.assets.isEmpty)
}

@Test func localImageSourceDistinguishesEmptyAndOfflineFolders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxFolderAvailabilityTests-\(UUID().uuidString)", isDirectory: true)
    let emptyFolder = root.appendingPathComponent("empty", isDirectory: true)
    let offlineFolder = root.appendingPathComponent("offline", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let emptySnapshot = LocalImageSource.loadFolderSnapshot(
        in: emptyFolder,
        sourceID: "empty-source",
        rootURL: emptyFolder,
        probeMetadata: false
    )
    let offlineSnapshot = LocalImageSource.loadFolderSnapshot(
        in: offlineFolder,
        sourceID: "offline-source",
        rootURL: offlineFolder,
        probeMetadata: false
    )

    #expect(emptySnapshot.availability == .available)
    #expect(emptySnapshot.entryCount == 0)
    #expect(offlineSnapshot.availability == .unavailable(.sourceUnavailable))
}

@Test func localImageSourcePreservesAccessDeniedStatus() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxFolderDeniedTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    let snapshot = LocalImageSource.loadFolderSnapshot(
        in: root,
        sourceID: "denied-source",
        rootURL: root,
        probeMetadata: false
    )

    #expect(snapshot.availability == .unavailable(.accessDenied))
}

@Test func finderColorTagsPreserveCustomNamesWithColorCodes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxFinderTagTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let image = root.appendingPathComponent("rose.jpg")
    try Data("image".utf8).write(to: image)
    try writeFinderTags(["\u{5ba2}\u{6237}A\n6", "Blue\n4"], to: image)

    #expect(FinderTagStore.colorTags(for: image) == ["Red", "Blue"])
    #expect(FinderTagStore.setColorTags(["Red"], for: image))
    #expect(try readFinderTags(from: image) == ["\u{5ba2}\u{6237}A\n6"])

    #expect(FinderTagStore.setColorTags([], for: image))
    #expect(try readFinderTags(from: image) == ["\u{5ba2}\u{6237}A\n0"])
    #expect(FinderTagStore.colorTags(for: image).isEmpty)
}

@Test func finderColorTagRemovalReportsErrorsExceptMissingAttribute() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxFinderTagRemovalTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let image = root.appendingPathComponent("rose.jpg")
    try Data("image".utf8).write(to: image)

    #expect(FinderTagStore.setColorTags([], for: image))
    #expect(!FinderTagStore.setColorTags([], for: root.appendingPathComponent("missing.jpg")))
}

@Test func localImageSourceSearchAssetsSupportsRecursiveFolderSearch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxSearchTests-\(UUID().uuidString)", isDirectory: true)
    let child = root.appendingPathComponent("child", isDirectory: true)
    let nestedFolder = child.appendingPathComponent("rose-picks", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let nestedMatch = child.appendingPathComponent("rose-red.jpg")
    let nestedMiss = child.appendingPathComponent("rose-blue.png")
    let ignored = child.appendingPathComponent("notes.txt")
    try Data("image".utf8).write(to: nestedMatch)
    try Data("image".utf8).write(to: nestedMiss)
    try Data("notes".utf8).write(to: ignored)

    let recursiveResult = LocalImageSource.searchAssets(
        in: root,
        sourceID: "source",
        rootURL: root,
        query: LightboxSearchQuery.parse("rose-red"),
        recursive: true
    )
    let currentFolderResult = LocalImageSource.searchAssets(
        in: root,
        sourceID: "source",
        rootURL: root,
        query: LightboxSearchQuery.parse("rose-red"),
        recursive: false
    )
    let folderResult = LocalImageSource.searchAssets(
        in: root,
        sourceID: "source",
        rootURL: root,
        query: LightboxSearchQuery.parse("rose-picks"),
        recursive: true
    )
    let folderPreviewResult = LocalImageSource.searchFolders(
        in: root,
        sourceID: "source",
        rootURL: root,
        query: LightboxSearchQuery.parse("rose-picks"),
        recursive: true
    )

    #expect(recursiveResult.assets.map(\.originalName) == ["rose-red.jpg"])
    #expect(recursiveResult.visitedCount > 0)
    #expect(!recursiveResult.limitReached)
    #expect(currentFolderResult.assets.isEmpty)
    #expect(folderResult.folders.map(\.name) == ["rose-picks"])
    #expect(folderResult.assets.isEmpty)
    #expect(folderPreviewResult.folders.map(\.name) == ["rose-picks"])
    #expect(folderPreviewResult.assets.isEmpty)
}

@Test func localImageSourceSearchAssetsKeepsTagsAndContinuesAfterFolderLimit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxSearchLimitTests-\(UUID().uuidString)", isDirectory: true)
    let matchingFolder = root.appendingPathComponent("rose-folder", isDirectory: true)
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: matchingFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let image = nested.appendingPathComponent("rose-photo.jpg")
    try Data("image".utf8).write(to: image)
    #expect(FinderTagStore.setColorTags(["Red"], for: image))

    let result = LocalImageSource.searchAssets(
        in: root,
        sourceID: "source",
        rootURL: root,
        query: LightboxSearchQuery.parse("rose"),
        recursive: true,
        maxResults: 10,
        maxFolderResults: 0
    )

    #expect(result.limitReached)
    #expect(result.folders.isEmpty)
    #expect(result.assets.map(\.originalName) == ["rose-photo.jpg"])
    #expect(result.assets.first?.tags == ["Red"])
    #expect(result.assets.first?.fileSize == 5)
    #expect(result.assets.first?.addedAt != .distantPast)
}

@Test func localImageSourceSearchMarksUnreadableSubfoldersAsIncomplete() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxUnreadableSearchTests-\(UUID().uuidString)", isDirectory: true)
    let unreadable = root.appendingPathComponent("Blocked", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    try Data("image".utf8).write(to: unreadable.appendingPathComponent("hidden.jpg"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        try? FileManager.default.removeItem(at: root)
    }

    let result = LocalImageSource.searchAssets(
        in: root,
        sourceID: "source",
        rootURL: root,
        query: LightboxSearchQuery.parse("hidden"),
        recursive: true
    )

    #expect(result.assets.isEmpty)
    #expect(result.limitReached)
}

@Test func localImageSourceLoadsFolderTagsWithoutAssetMetadataProbe() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxFolderTagTests-\(UUID().uuidString)", isDirectory: true)
    let taggedFolder = root.appendingPathComponent("RoseMorning", isDirectory: true)
    try FileManager.default.createDirectory(at: taggedFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    #expect(FinderTagStore.setColorTags(["Red"], for: taggedFolder))

    let source = LibrarySourceStore.makeExternalSource(rootURL: root)
    let snapshot = LocalImageSource.loadFolderSnapshot(
        in: root,
        sourceID: source.id,
        rootURL: root,
        probeMetadata: false
    )

    let folder = try #require(snapshot.folders.first { $0.url == taggedFolder.standardizedFileURL })
    #expect(folder.tags == ["Red"])
    #expect(snapshot.assets.isEmpty)
}

@Test func sidebarFolderTagCacheReadsAndStoresFolderTags() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxSidebarTagCacheTests-\(UUID().uuidString)", isDirectory: true)
    let taggedFolder = root.appendingPathComponent("RoseMorning", isDirectory: true)
    try FileManager.default.createDirectory(at: taggedFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    #expect(FinderTagStore.setColorTags(["Red"], for: taggedFolder))

    let cache = SidebarFolderTagCache()
    #expect(await cache.tags(for: taggedFolder) == ["Red"])

    cache.store(["Blue"], for: taggedFolder)
    #expect(cache.cachedTags(for: taggedFolder) == ["Blue"])
}

@Test func sidebarFolderTagCacheEvictsOldEntriesAndClears() async throws {
    let cache = SidebarFolderTagCache(maxEntries: 2)
    let first = URL(fileURLWithPath: "/tmp/lightbox-sidebar-tags-first", isDirectory: true)
    let second = URL(fileURLWithPath: "/tmp/lightbox-sidebar-tags-second", isDirectory: true)
    let third = URL(fileURLWithPath: "/tmp/lightbox-sidebar-tags-third", isDirectory: true)

    cache.store(["Red"], for: first)
    cache.store(["Blue"], for: second)
    cache.store(["Green"], for: third)

    #expect(cache.cachedTags(for: first) == nil)
    #expect(cache.cachedTags(for: second) == ["Blue"])
    #expect(cache.cachedTags(for: third) == ["Green"])

    cache.clear()

    #expect(cache.cachedTags(for: second) == nil)
    #expect(cache.cachedTags(for: third) == nil)
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
    let defaults = try #require(LightboxTestUserDefaults())

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

    let defaults = try #require(LightboxTestUserDefaults())

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
    let defaults = try #require(LightboxTestUserDefaults())

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

@Test func librarySourceStoreDoesNotInjectLegacyFavoritesSource() async throws {
    let defaults = try #require(LightboxTestUserDefaults())

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxExternalSourceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let external = LibrarySourceStore.makeExternalSource(rootURL: root)
    LibrarySourceStore.saveExternalSources(
        [LibrarySource.favorites(rootURL: root), external],
        defaults: defaults
    )

    let loaded = LibrarySourceStore.loadSources(defaults: defaults)

    #expect(loaded == [external])
    #expect(!loaded.contains { $0.kind == .favorites })
}

@Test func librarySourceStoreKeepsOfflineExternalSources() async throws {
    let defaults = try #require(LightboxTestUserDefaults())

    let offlineRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxOfflineSource-\(UUID().uuidString)", isDirectory: true)
    let source = LibrarySource(
        id: "offline-source",
        name: "Offline NAS",
        rootURL: offlineRoot,
        kind: .external
    )

    LibrarySourceStore.saveExternalSources([source], defaults: defaults)

    #expect(LibrarySourceStore.loadSources(defaults: defaults) == [source])
}

@MainActor
@Test func sidebarOpenKeepsTemporarySourceWhenEnteringChildFolder() async throws {
    let defaults = try #require(LightboxTestUserDefaults())

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxTemporarySourceTests-\(UUID().uuidString)", isDirectory: true)
    let child = root.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let appState = makeTestAppState(libraryDefaults: defaults)
    appState.sources = []
    appState.openSidebarFolder(root)
    let temporarySourceID = try #require(appState.selectedSource?.id)

    appState.openSidebarFolder(child)

    #expect(appState.selectedSource?.id == temporarySourceID)
    #expect(appState.selectedSource?.rootURL == root.standardizedFileURL)
    #expect(appState.currentFolderURL == child.standardizedFileURL)
}

@MainActor
@Test func missingCurrentFolderFallbackRebindsDirectoryMonitor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxMonitorFallbackTests-\(UUID().uuidString)", isDirectory: true)
    let child = root.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let source = LibrarySource.favorites(rootURL: root)
    let appState = makeTestAppState()
    appState.sources = [source]
    appState.chooseSource(source.id)
    appState.openFolder(LibraryFolderEntry(sourceID: source.id, url: child, rootURL: root))
    #expect(appState.currentFolderURL == child.standardizedFileURL)

    try FileManager.default.removeItem(at: child)
    appState.refreshLibrary()
    #expect(await waitForLightboxState {
        appState.currentFolderURL == root.standardizedFileURL && appState.libraryLoadingStatus == nil
    })
    try? await Task.sleep(for: .milliseconds(700))

    let newImage = root.appendingPathComponent("after-fallback.jpg")
    try Data("new-image".utf8).write(to: newImage)

    #expect(await waitForLightboxState {
        appState.assets.contains { $0.sourceURL?.standardizedFileURL == newImage.standardizedFileURL }
    })
}

@MainActor
@Test func offlineExternalRootPreservesCurrentChildFolderAndCache() async throws {
    let container = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxOfflineChildTests-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("source", isDirectory: true)
    let child = root.appendingPathComponent("Nested", isDirectory: true)
    let imageURL = child.appendingPathComponent("cached.jpg")
    let databaseURL = container.appendingPathComponent("index.sqlite")
    let defaults = try #require(LightboxTestUserDefaults())
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data("cached-image".utf8).write(to: imageURL)
    defer {
        try? FileManager.default.removeItem(at: container)
    }

    let source = LibrarySourceStore.makeExternalSource(rootURL: root)
    LibrarySourceStore.saveExternalSources([source], defaults: defaults)
    LibrarySourceStore.saveSelectedSourceID(source.id, defaults: defaults)
    let appState = makeTestAppState(
        indexDatabaseURL: databaseURL,
        libraryDefaults: defaults
    )
    appState.openFolder(LibraryFolderEntry(sourceID: source.id, url: child, rootURL: root))
    #expect(await waitForLightboxState {
        appState.currentFolderURL == child.standardizedFileURL
            && appState.assets.map(\.sourceURL) == [imageURL]
            && appState.libraryLoadingStatus == nil
    })
    #expect(await waitForLightboxState {
        LightboxIndexStore(databaseURL: databaseURL)
            .cachedVisibleSnapshot(source: source, folderURL: child)?
            .assets.count == 1
    })

    try FileManager.default.removeItem(at: root)
    appState.refreshLibrary()

    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    #expect(appState.currentFolderURL == child.standardizedFileURL)
    #expect(appState.assets.map(\.sourceURL) == [imageURL])
    #expect(LibrarySourceStore.loadLastSession(defaults: defaults)?.folderURL == child.standardizedFileURL)
    #expect(
        LightboxIndexStore(databaseURL: databaseURL)
            .cachedVisibleSnapshot(source: source, folderURL: child)?
            .assets.count == 1
    )
}

@MainActor
@Test func startupRestoresLastChildFolderWhenExternalRootIsOffline() async throws {
    let container = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxOfflineStartupTests-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("source", isDirectory: true)
    let child = root.appendingPathComponent("Nested", isDirectory: true)
    let defaults = try #require(LightboxTestUserDefaults())
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: container)
    }

    let source = LibrarySourceStore.makeExternalSource(rootURL: root)
    LibrarySourceStore.saveExternalSources([source], defaults: defaults)
    LibrarySourceStore.saveSelectedSourceID(source.id, defaults: defaults)
    LibrarySourceStore.saveLastSession(source: source, folderURL: child, defaults: defaults)
    try FileManager.default.removeItem(at: root)

    let appState = makeTestAppState(libraryDefaults: defaults)
    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    #expect(appState.selectedSourceID == source.id)
    #expect(appState.currentFolderURL == child.standardizedFileURL)
    #expect(LibrarySourceStore.loadLastSession(defaults: defaults)?.folderURL == child.standardizedFileURL)
}

@MainActor
@Test func unavailableFolderRefreshPreservesVisibleCacheAndIndex() async throws {
    let container = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxUnavailableRefreshTests-\(UUID().uuidString)", isDirectory: true)
    let sourceRoot = container.appendingPathComponent("source", isDirectory: true)
    let databaseURL = container.appendingPathComponent("index.sqlite")
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: container)
    }

    let imageURL = sourceRoot.appendingPathComponent("cached.jpg")
    try Data("cached-image".utf8).write(to: imageURL)
    let source = LibrarySourceStore.makeExternalSource(rootURL: sourceRoot)
    let appState = makeTestAppState(indexDatabaseURL: databaseURL)
    appState.sources = [source]
    appState.chooseSource(source.id)

    #expect(await waitForLightboxState {
        appState.assets.map(\.sourceURL) == [imageURL]
            && appState.libraryLoadingStatus == nil
    })
    #expect(await waitForLightboxState {
        LightboxIndexStore(databaseURL: databaseURL)
            .cachedVisibleSnapshot(source: source, folderURL: sourceRoot)?
            .assets.count == 1
    })

    try FileManager.default.removeItem(at: sourceRoot)
    appState.refreshLibrary()

    #expect(await waitForLightboxState { appState.libraryLoadingStatus == nil })
    #expect(appState.assets.map(\.sourceURL) == [imageURL])
    #expect(
        LightboxIndexStore(databaseURL: databaseURL)
            .cachedVisibleSnapshot(source: source, folderURL: sourceRoot)?
            .assets.count == 1
    )

    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    appState.refreshLibrary()

    #expect(await waitForLightboxState {
        appState.assets.isEmpty && appState.libraryLoadingStatus == nil
    })
    #expect(await waitForLightboxState {
        let indexedSnapshot = LightboxIndexStore(databaseURL: databaseURL)
            .cachedVisibleSnapshot(source: source, folderURL: sourceRoot)
        return indexedSnapshot?.assets.isEmpty ?? true
    })
}

@Test func fastThumbnailOptionsPreferEmbeddedPreviews() async throws {
    let options = ImageCache.thumbnailCreationOptions(
        maxPixelSize: 512,
        prefersEmbeddedPreview: ImageCacheQuality.thumbnailFast.prefersEmbeddedPreview
    )

    #expect(options[kCGImageSourceCreateThumbnailFromImageIfAbsent] as? Bool == true)
    #expect(options[kCGImageSourceCreateThumbnailFromImageAlways] == nil)
    #expect(options[kCGImageSourceThumbnailMaxPixelSize] as? Int == 512)
    #expect(options[kCGImageSourceShouldCache] as? Bool == false)
    #expect(options[kCGImageSourceShouldCacheImmediately] as? Bool == true)
}

@Test func visibleThumbnailOptionsForceFullImageDownsample() async throws {
    let options = ImageCache.thumbnailCreationOptions(
        maxPixelSize: 1024,
        prefersEmbeddedPreview: ImageCacheQuality.thumbnail.prefersEmbeddedPreview
    )

    #expect(options[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool == true)
    #expect(options[kCGImageSourceCreateThumbnailFromImageIfAbsent] == nil)
    #expect(options[kCGImageSourceThumbnailMaxPixelSize] as? Int == 1024)
    #expect(options[kCGImageSourceShouldCache] as? Bool == false)
    #expect(options[kCGImageSourceShouldCacheImmediately] as? Bool == true)
}

@Test func imageSourceOptionsAvoidImageIOPersistentCache() async throws {
    let options = ImageCache.imageSourceOptions()

    #expect(options[kCGImageSourceShouldCache] as? Bool == false)
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

    guard case let .updateAvailable(version, _, assetURL, digest) = result else {
        Issue.record("Expected update to be available")
        return
    }

    #expect(version == "1.3.1")
    #expect(assetURL.lastPathComponent == "Lightbox-v1.3.1.zip")
    #expect(digest == "sha256:" + String(repeating: "b", count: 64))
}

@Test func updateCheckerChoosesIntelReleaseAssetForCompatibilityBuild() async throws {
    let result = try LightboxUpdateChecker.checkResult(
        from: sampleReleaseData(tag: "v1.3.1"),
        currentVersion: "1.3.0",
        compatibility: true
    )

    guard case let .updateAvailable(_, _, assetURL, digest) = result else {
        Issue.record("Expected update to be available")
        return
    }

    #expect(assetURL.lastPathComponent == "Lightbox-Intel-x86-v1.3.1.zip")
    #expect(digest == "sha256:" + String(repeating: "a", count: 64))
}

@Test func updateCheckerRejectsReleaseWithoutExactCompatibleAsset() async throws {
    let json = """
    {
      "tag_name": "v1.3.1",
      "html_url": "https://github.com/a11oydyyy/Lightbox/releases/tag/v1.3.1",
      "assets": [
        {
          "name": "Lightbox-Intel-x86-v1.3.1.zip.sha256",
          "browser_download_url": "https://example.com/Lightbox-Intel-x86-v1.3.1.zip.sha256",
          "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }
      ]
    }
    """

    do {
        _ = try LightboxUpdateChecker.checkResult(
            from: try #require(json.data(using: .utf8)),
            currentVersion: "1.3.0",
            compatibility: true
        )
        Issue.record("Expected an exact compatible asset to be required")
    } catch let error as UpdateError {
        guard case .compatibleAssetMissing = error else {
            Issue.record("Expected compatibleAssetMissing, got \(error)")
            return
        }
    }
}

@Test func updateInstallerValidatesSHA256Digest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxDigestTest-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("update.zip")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("update".utf8).write(to: fileURL)
    try LightboxUpdateInstaller.validateDigest(
        of: fileURL,
        expectedDigest: "sha256:2937013f2181810606b2a799b05bda2849f3e369a20982a4138f0e0a55984ce4"
    )

    do {
        try LightboxUpdateInstaller.validateDigest(
            of: fileURL,
            expectedDigest: "sha256:" + String(repeating: "0", count: 64)
        )
        Issue.record("Expected a digest mismatch")
    } catch let error as UpdateInstallError {
        guard case .digestMismatch = error else {
            Issue.record("Expected digestMismatch, got \(error)")
            return
        }
    }
}

@Test func updateInstallerValidatesBundleIdentityAndVersion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxBundleValidationTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let validAppURL = try makeTestAppBundle(
        in: root.appendingPathComponent("valid", isDirectory: true),
        identifier: "io.github.a11oydyyy.Lightbox",
        version: "1.4.0"
    )
    try LightboxUpdateInstaller.validateBundleMetadata(
        for: validAppURL,
        currentBundleIdentifier: "io.github.a11oydyyy.Lightbox",
        expectedVersion: "v1.4.0"
    )

    let wrongVersionAppURL = try makeTestAppBundle(
        in: root.appendingPathComponent("wrong-version", isDirectory: true),
        identifier: "io.github.a11oydyyy.Lightbox",
        version: "1.3.4"
    )
    do {
        try LightboxUpdateInstaller.validateBundleMetadata(
            for: wrongVersionAppURL,
            currentBundleIdentifier: "io.github.a11oydyyy.Lightbox",
            expectedVersion: "1.4.0"
        )
        Issue.record("Expected a staged app version mismatch")
    } catch let error as UpdateInstallError {
        guard case .appVersionMismatch = error else {
            Issue.record("Expected appVersionMismatch, got \(error)")
            return
        }
    }
}

@Test func updateInstallScriptRestoresCurrentAppWhenCopyFails() async throws {
    #expect(!LightboxUpdateInstaller.installScript.contains("/usr/bin/xattr"))
    #expect(LightboxUpdateInstaller.installScript.contains(LightboxUpdateHealth.markerArgument))
    #expect(!LightboxUpdateInstaller.installScript.contains("MOVED_CURRENT"))
    #expect(LightboxUpdateInstaller.installScript.contains("NEW_APP_PID=$!"))

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("LightboxInstallRollbackTest-\(UUID().uuidString)", isDirectory: true)
    let currentAppURL = root.appendingPathComponent("Lightbox.app", isDirectory: true)
    let markerURL = currentAppURL.appendingPathComponent("marker")
    let missingStagedAppURL = root
        .appendingPathComponent("staging", isDirectory: true)
        .appendingPathComponent("Lightbox.app", isDirectory: true)
    let scriptURL = root.appendingPathComponent("install.sh")
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: currentAppURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(
        at: missingStagedAppURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("original".utf8).write(to: markerURL)
    try LightboxUpdateInstaller.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptURL.path, currentAppURL.path, missingStagedAppURL.path, "99999999"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus != 0)
    #expect(fileManager.fileExists(atPath: markerURL.path))
    #expect(!fileManager.fileExists(atPath: scriptURL.path))
    #expect(!fileManager.fileExists(atPath: missingStagedAppURL.deletingLastPathComponent().path))
    let leftovers = try fileManager.contentsOfDirectory(atPath: root.path)
    #expect(!leftovers.contains { $0.hasPrefix("Lightbox.app.old-") })
}

@Test func updateInstallScriptTerminatesFailedNewAppBeforeRollback() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("LightboxInstallHealthTimeoutTest-\(UUID().uuidString)", isDirectory: true)
    let currentAppURL = root.appendingPathComponent("Lightbox.app", isDirectory: true)
    let originalMarkerURL = currentAppURL.appendingPathComponent("original")
    let stagingRootURL = root
        .appendingPathComponent("LightboxUpdate-\(UUID().uuidString)", isDirectory: true)
    let stagedAppURL = stagingRootURL.appendingPathComponent("Lightbox.app", isDirectory: true)
    let stagedContentsURL = stagedAppURL.appendingPathComponent("Contents", isDirectory: true)
    let stagedMacOSURL = stagedContentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let stagedExecutableURL = stagedMacOSURL.appendingPathComponent("LightboxTest")
    let launchedPIDURL = root.appendingPathComponent("launched-pid")
    let terminatedURL = root.appendingPathComponent("terminated")
    let scriptURL = root.appendingPathComponent("install.sh")
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: currentAppURL, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: originalMarkerURL)
    try fileManager.createDirectory(at: stagedMacOSURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleExecutable": "LightboxTest",
        "CFBundleIdentifier": "io.github.a11oydyyy.Lightbox",
        "CFBundlePackageType": "APPL"
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try infoData.write(to: stagedContentsURL.appendingPathComponent("Info.plist"))
    let executable = """
        #!/bin/sh
        /bin/echo "$$" > "\(launchedPIDURL.path)"
        trap '/bin/echo terminated > "\(terminatedURL.path)"; exit 0' TERM
        while :; do
          /bin/sleep 0.05
        done
        """
    try executable.write(to: stagedExecutableURL, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagedExecutableURL.path)
    try LightboxUpdateInstaller.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        scriptURL.path,
        currentAppURL.path,
        stagedAppURL.path,
        "99999999",
        "50",
        "0.02"
    ]
    process.standardOutput = Pipe()
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let installerError = String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    #expect(process.terminationStatus != 0)
    #expect(fileManager.fileExists(atPath: originalMarkerURL.path))
    #expect(fileManager.fileExists(atPath: terminatedURL.path), "Installer stderr: \(installerError)")
    let launchedPIDString = try String(contentsOf: launchedPIDURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let launchedPID = try #require(pid_t(launchedPIDString))
    let processCheck = kill(launchedPID, 0)
    let processCheckError = errno
    #expect(processCheck == -1)
    #expect(processCheckError == ESRCH)
    #expect(!fileManager.fileExists(atPath: scriptURL.path))
    #expect(!fileManager.fileExists(atPath: stagingRootURL.path))
    let leftovers = try fileManager.contentsOfDirectory(atPath: root.path)
    #expect(!leftovers.contains { $0.hasPrefix("Lightbox.app.old-") })
}

@Test func updateHealthMarkerOnlyWritesInsidePreparedStagingRoot() async throws {
    let fileManager = FileManager.default
    let stagingRoot = fileManager.temporaryDirectory
        .appendingPathComponent("LightboxUpdate-\(UUID().uuidString)", isDirectory: true)
    let markerURL = stagingRoot.appendingPathComponent("launch-healthy")
    let rejectedRoot = fileManager.temporaryDirectory
        .appendingPathComponent("Untrusted-\(UUID().uuidString)", isDirectory: true)
    let rejectedMarkerURL = rejectedRoot.appendingPathComponent("launch-healthy")
    let symlinkDestination = fileManager.temporaryDirectory
        .appendingPathComponent("LightboxHealthDestination-\(UUID().uuidString)", isDirectory: true)
    let symlinkRoot = fileManager.temporaryDirectory
        .appendingPathComponent("LightboxUpdate-\(UUID().uuidString)", isDirectory: true)
    let symlinkMarkerURL = symlinkRoot.appendingPathComponent("launch-healthy")
    defer {
        try? fileManager.removeItem(at: stagingRoot)
        try? fileManager.removeItem(at: rejectedRoot)
        try? fileManager.removeItem(at: symlinkRoot)
        try? fileManager.removeItem(at: symlinkDestination)
    }

    try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: rejectedRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: symlinkDestination, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: symlinkDestination)

    #expect(LightboxUpdateHealth.isRequested(
        arguments: ["Lightbox", LightboxUpdateHealth.markerArgument, markerURL.path]
    ))
    #expect(LightboxUpdateHealth.recordLaunch(
        arguments: ["Lightbox", LightboxUpdateHealth.markerArgument, markerURL.path]
    ))
    #expect(fileManager.fileExists(atPath: markerURL.path))
    #expect(!LightboxUpdateHealth.recordLaunch(
        arguments: ["Lightbox", LightboxUpdateHealth.markerArgument, rejectedMarkerURL.path]
    ))
    #expect(!fileManager.fileExists(atPath: rejectedMarkerURL.path))
    #expect(!LightboxUpdateHealth.recordLaunch(
        arguments: ["Lightbox", LightboxUpdateHealth.markerArgument, symlinkMarkerURL.path]
    ))
    #expect(!fileManager.fileExists(atPath: symlinkDestination.appendingPathComponent("launch-healthy").path))
}

@Test func updateCheckerComparesSemanticVersionNumbers() async throws {
    #expect(LightboxUpdateChecker.isVersion("1.10.0", newerThan: "1.9.9"))
    #expect(!LightboxUpdateChecker.isVersion("1.3.0", newerThan: "1.3"))
    #expect(!LightboxUpdateChecker.isVersion("v1.3.0", newerThan: "1.3.1"))
}

private func makeTestImage(size: Int = 8) -> NSImage? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
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

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(bitmap)
    return image
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private func sampleReleaseData(tag: String) throws -> Data {
    let json = """
    {
      "tag_name": "\(tag)",
      "html_url": "https://github.com/a11oydyyy/Lightbox/releases/tag/\(tag)",
      "assets": [
        {
          "name": "Lightbox-Intel-x86-v1.3.1.zip",
          "browser_download_url": "https://github.com/a11oydyyy/Lightbox/releases/download/\(tag)/Lightbox-Intel-x86-v1.3.1.zip",
          "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        {
          "name": "Lightbox-v1.3.1.zip",
          "browser_download_url": "https://github.com/a11oydyyy/Lightbox/releases/download/\(tag)/Lightbox-v1.3.1.zip",
          "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
      ]
    }
    """

    return try #require(json.data(using: .utf8))
}

private func makeTestAppBundle(in root: URL, identifier: String, version: String) throws -> URL {
    let appURL = root.appendingPathComponent("Lightbox.app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": identifier,
        "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL"
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return appURL
}

@MainActor
private func waitForLightboxState(
    timeout: Duration = .seconds(6),
    condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

private let finderUserTagsAttribute = "com.apple.metadata:_kMDItemUserTags"

private func writeFinderTags(_ tags: [String], to url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: tags,
        format: .binary,
        options: 0
    )
    let result = data.withUnsafeBytes { buffer in
        setxattr(url.path, finderUserTagsAttribute, buffer.baseAddress, data.count, 0, 0)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func readFinderTags(from url: URL) throws -> [String] {
    let size = getxattr(url.path, finderUserTagsAttribute, nil, 0, 0, 0)
    guard size >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var data = Data(count: size)
    let readSize = data.withUnsafeMutableBytes { buffer in
        getxattr(url.path, finderUserTagsAttribute, buffer.baseAddress, size, 0, 0)
    }
    guard readSize >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if readSize < data.count {
        data.removeSubrange(readSize..<data.count)
    }

    return try #require(
        PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String]
    )
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Bool) {
        lock.lock()
        storedValue = storedValue || value
        lock.unlock()
    }
}
