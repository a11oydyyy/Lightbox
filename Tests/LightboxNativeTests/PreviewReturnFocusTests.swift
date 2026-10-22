import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

// Closing the preview returns keyboard focus to the image it was showing,
// not the one it was opened from, scrolling to it when it stepped offscreen.
@Test(arguments: [2, 30])
@MainActor func previewCloseFocusesTheImageItWasShowing(steps: Int) async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPreviewFocus-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxPreviewFocus-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    let source = LibrarySource(id: "preview-focus", name: "Photos", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    await waitWhile { state.libraryLoadingStatus != nil }
    state.sortField = .fileName
    state.sortDirection = .ascending
    state.assets = (0..<80).map { index in
        LightboxAsset(id: "focus-\(index)", originalName: String(format: "%02d.jpg", index), width: 600, height: 400,
            tags: [], addedAt: .distantPast, palette: MockPalette.imported[0], metadataLoaded: true)
    }
    let host = NSHostingView(rootView: ZStack {
        GalleryView()
        PreviewOverlayHost(preview: state.preview)
    }
    .environmentObject(state)
    .coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { state.closePreview(); window.close() }
    func settle(_ rounds: Int = 30) async throws {
        for _ in 0..<rounds { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func cards(_ view: NSView) -> [AssetInteractionView] {
        (view as? AssetInteractionView).map { [$0] } ?? view.subviews.flatMap(cards)
    }
    try await settle()
    let assets = state.activeAssets
    // Clicking a card focuses it, then opens the preview from it.
    let opened = try #require(cards(host).first { $0.debugTargetName == assets[0].originalName && $0.debugSurface == "gallery-card" })
    window.makeFirstResponder(opened)
    state.galleryKeyboardFocusID = assets[0].id
    state.showPreview(for: assets[0], sourceFrame: state.previewSpaceFrame(for: assets[0].id))
    try await Task.sleep(for: MotionTokens.previewGeometryDuration + .milliseconds(100))
    try await settle()
    for _ in 0..<steps {
        state.stepPreview(.next)
        try await settle(3)
    }
    try await settle()
    let shown = assets[steps]
    #expect(state.previewAssetID == shown.id)
    try #require(state.beginPreviewClose(after: .milliseconds(30), revealSourceAfter: .milliseconds(10)))
    try await Task.sleep(for: .milliseconds(150))
    try await settle()

    #expect(state.galleryKeyboardFocusID == shown.id)
    let focused = window.firstResponder as? AssetInteractionView
    #expect(focused?.debugTargetName == shown.originalName, "focused \(focused?.debugTargetName ?? String(describing: window.firstResponder))")
    let frame = try #require(state.previewSpaceFrame(for: shown.id))
    #expect(frame.intersects(host.bounds), "frame \(frame)")
}
