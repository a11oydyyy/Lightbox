import AppKit
import Combine
import SwiftUI
import Testing
@testable import LightboxNative

// Stepping between a portrait and a landscape image must size each one for
// itself, not keep the previous image's box. Steps don't republish
// `AppState`, so this also checks that the preview host follows them.
@Test @MainActor func previewStepSizesEachImageForItsOwnAspectRatio() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPreviewStep-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxPreviewStep-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    let source = LibrarySource(id: "preview-step", name: "Photos", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    await waitWhile { state.libraryLoadingStatus != nil }
    state.sortField = .fileName
    state.sortDirection = .ascending
    state.assets = (0..<4).map { index in
        let portrait = index.isMultiple(of: 2)
        return LightboxAsset(id: "step-\(index)", originalName: "\(index).jpg",
            width: portrait ? 4000 : 6000, height: portrait ? 6000 : 4000,
            tags: [], addedAt: .distantPast, palette: MockPalette.imported[0], metadataLoaded: true)
    }
    let viewport = CGSize(width: 1400, height: 900)
    let host = NSHostingView(rootView: PreviewOverlayHost(preview: state.preview)
        .environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { state.closePreview(); window.close() }
    func settle() async throws {
        for _ in 0..<60 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func previewImageSize() throws -> CGSize {
        func find(_ view: NSView) -> AssetInteractionView? {
            if let view = view as? AssetInteractionView, view.debugSurface == "preview-image" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(host)).frame.size
    }
    func expectFitted(_ asset: LightboxAsset) throws {
        let expected = PreviewGeometry.previewSize(assetSize: CGSize(width: asset.width, height: asset.height), viewport: viewport)
        let actual = try previewImageSize()
        #expect(abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1,
                "\(asset.originalName): expected \(expected), got \(actual)")
    }

    let assets = state.activeAssets
    state.showPreview(for: assets[0])
    try await settle()
    try expectFitted(assets[0])
    for index in 1..<4 {
        state.stepPreview(.next)
        try await settle()
        try expectFitted(assets[index])
    }

    // Real dimensions arriving after the preview opened resize it too.
    let shown = try #require(state.previewAsset)
    let index = try #require(state.assets.firstIndex { $0.id == shown.id })
    state.assets[index].width = 600
    state.assets[index].height = 400
    try await settle()
    try expectFitted(state.assets[index])
}

// Stepping reaches the preview and gallery through `appState.preview`; the
// sidebar, header and window chrome hear only that a preview opened or closed.
@Test @MainActor func previewStepsDoNotRepublishTheAppState() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPreviewPublish-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxPreviewPublish-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    let source = LibrarySource(id: "preview-publish", name: "Photos", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    await waitWhile { state.libraryLoadingStatus != nil }
    state.assets = (0..<6).map { index in
        LightboxAsset(id: "publish-\(index)", originalName: "\(index).jpg", width: 600, height: 400,
            tags: [], addedAt: .distantPast, palette: MockPalette.imported[0], metadataLoaded: true)
    }
    let first = try #require(state.activeAssets.first)
    state.showPreview(for: first)
    // Wait for the open to finish rather than for its nominal duration: a
    // first step during opening also marks the preview open, a real publish.
    await waitWhile { state.previewPhase != .open }
    #expect(state.previewPhase == .open)

    var appStateChanges = 0
    var previewChanges = 0
    let observers = [
        state.objectWillChange.sink { appStateChanges += 1 },
        state.preview.objectWillChange.sink { previewChanges += 1 },
    ]
    defer { observers.forEach { $0.cancel() } }
    for _ in 0..<5 { state.stepPreview(.next) }
    #expect(appStateChanges == 0)
    #expect(previewChanges >= 5)
    #expect(state.previewAssetID == state.activeAssets[5].id)

    state.closePreview()
    #expect(appStateChanges > 0)
    #expect(state.previewAssetID == nil)
}

// The details under the image keep a fixed gap below it, and never crowd
// the window's bottom edge however tall the image is.
@Test func previewDetailsKeepTheirGapAndBottomMargin() {
    let viewport = CGSize(width: 1200, height: 800)
    for assetSize in [CGSize(width: 6000, height: 4000), CGSize(width: 4000, height: 6000), CGSize(width: 3000, height: 3000)] {
        let size = PreviewGeometry.previewSize(assetSize: assetSize, viewport: viewport)
        let imageBottom = (viewport.height + size.height) / 2
        for height in [CGFloat(48), 64, 88, 104] {
            let top = PreviewGeometry.controlsTop(imageBottom: imageBottom, controlsHeight: height, viewportHeight: viewport.height)
            #expect(top + height <= viewport.height - PreviewGeometry.controlsBottomMargin)
            #expect(top >= imageBottom + 8, "\(assetSize) height \(height): top \(top), image bottom \(imageBottom)")
            #expect(top <= imageBottom + PreviewGeometry.controlsGap)
        }
    }
}
