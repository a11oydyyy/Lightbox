import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import LightboxNative

@MainActor
private func makeSelectionState() throws -> (AppState, () -> Void) {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxSelection-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxSelection-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let source = LibrarySource(id: "selection", name: "Selection", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    return (state, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    })
}

@MainActor
private func selectionAsset(_ index: Int) -> LightboxAsset {
    LightboxAsset(id: "selection-\(index)", originalName: "\(index).jpg", width: 400, height: 300,
                  tags: [], addedAt: .distantPast, palette: MockPalette.imported[index % MockPalette.imported.count])
}

// App-state observers (sidebar, header, window chrome) hear only about a
// selection starting, ending or becoming a multi-selection; every other click
// and every arrow key reaches the gallery through the smaller states.
@MainActor
@Test func selectionAndKeyboardFocusRepublishTheAppStateOnlyAtEdges() async throws {
    let (state, cleanUp) = try makeSelectionState()
    defer { cleanUp() }
    await waitWhile { state.libraryLoadingStatus != nil }
    state.assets = (0..<10).map(selectionAsset)
    let ids = state.activeAssets.map(\.id)

    var appStateChanges = 0
    var selectionChanges = 0
    var focusChanges = 0
    let observers = [
        state.objectWillChange.sink { appStateChanges += 1 },
        state.selection.objectWillChange.sink { selectionChanges += 1 },
        state.keyboardFocus.objectWillChange.sink { focusChanges += 1 },
    ]
    defer { observers.forEach { $0.cancel() } }

    state.replaceSelection(with: [ids[0]])
    #expect(appStateChanges == 1)
    for id in ids.dropFirst() { state.replaceSelection(with: [id]) }
    #expect(appStateChanges == 1)
    #expect(selectionChanges > 9)

    state.replaceSelection(with: [ids[0], ids[1]])
    #expect(appStateChanges == 2)
    state.replaceSelection(with: Set(ids.prefix(5)))
    #expect(appStateChanges == 2)
    #expect(state.selectedAssetCount == 5)

    state.clearSelection()
    #expect(appStateChanges == 3)

    for id in ids { state.galleryKeyboardFocusID = id }
    #expect(appStateChanges == 3)
    #expect(focusChanges >= ids.count)

    // An arrow key selects its target: the first press starts a selection,
    // later presses only move it.
    state.handleGalleryKey(124, modifiers: [], from: ids[3])
    #expect(appStateChanges == 4)
    for index in 4..<8 { state.handleGalleryKey(124, modifiers: [], from: ids[index]) }
    #expect(appStateChanges == 4)
    #expect(state.galleryKeyboardFocusID == ids[8])
    #expect(state.selectedAssetIDs == [ids[8]])
}

// The gallery must observe the selection and focus states itself: these
// changes never republish `AppState`.
@MainActor
@Test func galleryCardsFollowSelectionAndFocusWithoutAppStatePublishes() async throws {
    let (state, cleanUp) = try makeSelectionState()
    defer { cleanUp() }
    await waitWhile { state.libraryLoadingStatus != nil }
    state.assets = (0..<12).map(selectionAsset)
    let host = NSHostingView(rootView: GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    defer { window.close() }
    func settle() async throws {
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func cards(_ view: NSView) -> [AssetInteractionView] {
        (view as? AssetInteractionView).map { [$0] } ?? view.subviews.flatMap(cards)
    }
    // By position in the gallery's order, like `ids`.
    func card(_ index: Int) throws -> AssetInteractionView {
        let name = state.activeAssets[index].originalName
        return try #require(cards(host).first { $0.debugTargetName == name })
    }
    try await settle()
    let ids = state.activeAssets.map(\.id)

    state.replaceSelection(with: [ids[0]])
    try await settle()
    var appStateChanges = 0
    let observer = state.objectWillChange.sink { appStateChanges += 1 }
    defer { observer.cancel() }

    // Single selection moves: no app-state publish.
    state.replaceSelection(with: [ids[1]])
    try await settle()
    #expect(try card(1).isAccessibilitySelected())
    #expect(try !card(0).isAccessibilitySelected())

    // Growing a multi-selection: one publish at 1 → 2, none at 2 → 3.
    state.replaceSelection(with: [ids[1], ids[2]])
    try await settle()
    state.replaceSelection(with: [ids[1], ids[2], ids[3]])
    try await settle()
    #expect(appStateChanges == 1)
    #expect(try card(3).isAccessibilitySelected())

    state.galleryKeyboardFocusID = ids[5]
    try await settle()
    #expect(try card(5).requestedKeyboardFocus)
    state.galleryKeyboardFocusID = ids[6]
    try await settle()
    #expect(try card(6).requestedKeyboardFocus)
    #expect(try !card(5).requestedKeyboardFocus)
    #expect(appStateChanges == 1)
}

// The header's count follows the selection while a multi-selection grows,
// which no longer republishes `AppState`: what it draws must already match a
// full app-state refresh.
@MainActor
@Test func headerSelectionCountFollowsTheSelection() async throws {
    let (state, cleanUp) = try makeSelectionState()
    defer { cleanUp() }
    await waitWhile { state.libraryLoadingStatus != nil }
    state.assets = (0..<6).map(selectionAsset)
    let ids = state.activeAssets.map(\.id)
    let host = NSHostingView(rootView: NativeHeaderPanel(appState: state, kind: .selection)
        .transaction { $0.disablesAnimations = true })
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 60),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func settle() async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func pixels() throws -> Data {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.tiffRepresentation)
    }

    state.replaceSelection(with: Set(ids.prefix(2)))
    try await settle()
    let two = try pixels()
    state.replaceSelection(with: Set(ids.prefix(4)))
    try await settle()
    let four = try pixels()
    state.objectWillChange.send()
    try await settle()
    #expect(four != two)
    #expect(try pixels() == four)
}
