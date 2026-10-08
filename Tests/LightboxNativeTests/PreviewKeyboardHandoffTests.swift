import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

@Test(arguments: [true, false])
@MainActor func previewArrowsSurviveBeforeKeyboardViewAttachment(galleryEnabled: Bool) async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPreviewHandoff-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxPreviewHandoff-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "preview-handoff", name: "Photos", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    for _ in 0..<500 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(5)) }
    try #require(state.libraryLoadingStatus == nil)
    state.sortField = .fileName
    state.sortDirection = .ascending
    let assets = (0..<10).map { index in
        LightboxAsset(id: "handoff-\(index)", originalName: "\(index).png", width: 100, height: 100,
                      tags: [], addedAt: .distantPast, palette: MockPalette.imported[0])
    }
    state.assets = assets
    try #require(state.activeAssetIDList == assets.map(\.id))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = try #require(window.contentView)
    let gallery = AssetInteractionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    gallery.debugSurface = "gallery-card"
    gallery.onKeyboard = { key, modifiers in state.handleGalleryKey(key, modifiers: modifiers, from: assets[0].id) }
    gallery.onPreviewArrow = { state.handlePreviewArrowDuringKeyboardHandoff($0) }
    content.addSubview(gallery)
    try #require(window.makeFirstResponder(gallery))
    let preview = PreviewKeyboardView(frame: .zero)
    preview.onNext = { state.stepPreview(.next) }
    defer {
        state.closePreview()
        preview.requestedFocus = false
        window.makeFirstResponder(nil)
        preview.removeFromSuperview()
        gallery.removeFromSuperview()
        window.close()
    }
    let next = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    state.showPreview(for: assets[0])
    let session = state.previewSessionID
    preview.onFocusAcquired = { state.markPreviewKeyboardFocusAcquired(sessionID: session) }
    gallery.isInteractionEnabled = galleryEnabled
    // No run-loop turn or preview view attachment separates opening from input.
    try #require(window.firstResponder === gallery)
    let excludedModifiers: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
    for modifier in excludedModifiers {
        let modifiedNext = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        window.firstResponder?.keyDown(with: modifiedNext)
    }
    #expect(state.previewAssetID == assets[0].id)
    for _ in 0..<8 { window.firstResponder?.keyDown(with: next) }
    #expect(state.previewAssetID == assets[8].id)
    // The first step finishes opening, but the remaining seven must still route.
    #expect(!state.handlePreviewArrowDuringKeyboardHandoff(125))
    preview.requestedFocus = true
    content.addSubview(preview)
    try #require(window.firstResponder === preview)
    window.firstResponder?.keyDown(with: next)
    #expect(state.previewAssetID == assets[9].id)
    let information = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    content.addSubview(information)
    try #require(window.makeFirstResponder(information))
    window.firstResponder?.keyDown(with: next)
    #expect(state.previewAssetID == assets[9].id)
    window.makeFirstResponder(nil)
    information.removeFromSuperview()
    // Moving focus elsewhere after initial handoff must not re-enable the fallback.
    gallery.isInteractionEnabled = true
    try #require(window.makeFirstResponder(gallery))
    gallery.isInteractionEnabled = false
    window.firstResponder?.keyDown(with: next)
    #expect(state.previewAssetID == assets[9].id)
    state.showPreview(for: assets[0])
    state.markPreviewKeyboardFocusAcquired(sessionID: session) // A stale acknowledgement must not disable the new session.
    window.firstResponder?.keyDown(with: next)
    #expect(state.previewAssetID == assets[1].id)
    #expect(state.beginPreviewClose(after: .seconds(1)))
    window.firstResponder?.keyDown(with: next)
    #expect(state.previewAssetID == assets[1].id)
    #expect(!state.handlePreviewArrowDuringKeyboardHandoff(124))
    state.closePreview()
    #expect(!state.handlePreviewArrowDuringKeyboardHandoff(124))
    state.showPreview(for: assets[0])
    state.comparisonAssets = [assets[0], assets[1]]
    window.firstResponder?.keyDown(with: next)
    #expect(state.previewAssetID == assets[0].id)
    state.comparisonAssets = []
}

@Test @MainActor func disabledGalleryResponderDoesNotPerformUnderlyingActions() throws {
    let view = AssetInteractionView()
    var actions = 0
    view.onCopy = { actions += 1 }
    view.onKeyboard = { _, _ in actions += 1 }
    view.onActivate = { actions += 1 }
    view.onRestore = { actions += 1 }
    view.onMoveToTrash = { actions += 1 }
    view.onRevealInFinder = { actions += 1 }
    view.onOpenWith = { _ in actions += 1 }
    view.onShare = { _ in actions += 1 }
    view.onAddToCompareTray = { actions += 1 }
    view.isInteractionEnabled = false
    view.configureAccessibility(selected: false)
    view.copy(nil)
    view.selectAll(nil)
    for selector in ["restore", "moveToTrash", "revealInFinder", "openWithOtherApplication", "copyAsset", "shareAsset", "addToCompareTray"] {
        _ = view.perform(NSSelectorFromString(selector))
    }
    _ = view.perform(NSSelectorFromString("openWithSelectedApplication:"), with: NSMenuItem())
    #expect(!view.accessibilityPerformPress())
    #expect(!view.accessibilityCopy())
    #expect(!view.accessibilityCompare())
    #expect(!view.accessibilityPerformShowMenu())
    #expect(!view.acceptsFirstResponder)
    #expect(view.hitTest(.zero) == nil)
    #expect(actions == 0)
}

@Test(arguments: [false, true])
@MainActor func previewReturnKeepsGalleryScrollPositionAtViewportEdge(nearBottom: Bool) async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPreviewScroll-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxPreviewScroll-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "preview-scroll", name: "Photos", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    for _ in 0..<500 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(5)) }
    try #require(state.libraryLoadingStatus == nil)
    state.sortField = .fileName
    state.sortDirection = .ascending
    state.thumbnailWidth = 200
    state.assets = (0..<60).map { index in
        LightboxAsset(id: "scroll-\(index)", originalName: String(format: "%03d.jpg", index), width: 400, height: 300,
            tags: [], addedAt: .distantPast, palette: MockPalette.imported[0], metadataLoaded: true)
    }
    let host = NSHostingView(rootView: GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { state.closePreview(); window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }
    let scroll = try #require(findScroll(host))
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 310))
    scroll.reflectScrolledClipView(scroll.contentView)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let asset = try #require(state.activeAssets.first { asset in
        guard let frame = state.previewSpaceFrame(for: asset.id) else { return false }
        if nearBottom {
            let lowerEdge = scroll.contentView.bounds.height - 55
            return frame.minY < lowerEdge && frame.maxY > lowerEdge
        }
        return frame.minY < 52 && frame.maxY > 52
    })
    let originalFrame = try #require(state.previewSpaceFrame(for: asset.id))
    let originalOrigin = scroll.contentView.bounds.origin
    try #require(originalOrigin.y > 0)
    state.showPreview(for: asset, sourceFrame: originalFrame)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    #expect(abs(scroll.contentView.bounds.origin.y - originalOrigin.y) < 0.5)
    try #require(state.beginPreviewClose(after: .milliseconds(30), revealSourceAfter: .milliseconds(10)))
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    #expect(state.previewAssetID == nil)
    #expect(state.galleryKeyboardFocusID == asset.id)
    #expect(abs(scroll.contentView.bounds.origin.y - originalOrigin.y) < 0.5)
    let returnedFrame = try #require(state.previewSpaceFrame(for: asset.id))
    #expect(abs(returnedFrame.minY - originalFrame.minY) < 0.5)
    print("PREVIEW_RETURN_SCROLL edge=\(nearBottom ? "bottom" : "top") before=\(originalOrigin.y) after=\(scroll.contentView.bounds.origin.y) frame_before=\(originalFrame.minY) frame_after=\(returnedFrame.minY)")
}
