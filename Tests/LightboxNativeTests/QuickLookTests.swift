import AppKit
import Foundation
import Testing
@testable import LightboxNative

@MainActor
private final class FakeQuickLookPanel: QuickLookPanelDriving {
    var isVisible = false
    var reloads = 0
    func open() { isVisible = true }
    func close() { isVisible = false }
    func reload() { reloads += 1 }
}

// Space previews images in Lightbox and opens other files in Quick Look;
// ⌘Y quick-looks the selection; arrows in the panel walk the gallery.
@MainActor
@Test func spaceQuickLooksFilesAndArrowsFollowTheGallery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxQuickLook-\(UUID())")
    let work = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "doc.pdf", "notes.txt"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxQuickLook-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let panel = FakeQuickLookPanel()
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         previewDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         quickLookPanel: panel)
    state.showsOtherFiles = true
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    state.setSortField(.fileName)
    if state.sortDirection == .descending { state.toggleSortDirection() }
    await waitWhile { state.activeAssets.count != 3 || state.libraryLoadingStatus != nil }
    #expect(state.activeAssets.map(\.originalName) == ["a.jpg", "doc.pdf", "notes.txt"])
    let image = state.activeAssets[0], doc = state.activeAssets[1], notes = state.activeAssets[2]

    // Space on a file opens Quick Look; Space again closes it.
    state.handleSpace(on: doc)
    #expect(panel.isVisible && state.quickLook.urls.map(\.lastPathComponent) == ["doc.pdf"])
    state.handleSpace(on: doc)
    #expect(!panel.isVisible)

    // An arrow in the panel moves the gallery focus and the panel with it.
    state.handleSpace(on: doc)
    state.followQuickLook(124)
    #expect(state.galleryKeyboardFocusID == notes.id)
    #expect(state.quickLook.urls.map(\.lastPathComponent) == ["notes.txt"] && panel.reloads == 1)
    state.quickLook.close()

    // A selection holding a file is quick-looked together; ⌘Y does the same.
    state.replaceSelection(with: [doc.id, notes.id])
    state.handleSpace(on: doc)
    #expect(state.quickLook.urls.map(\.lastPathComponent) == ["doc.pdf", "notes.txt"])
    state.toggleQuickLook()
    #expect(!panel.isVisible)
    state.replaceSelection(with: [image.id])
    state.toggleQuickLook()
    #expect(panel.isVisible && state.quickLook.urls.map(\.lastPathComponent) == ["a.jpg"])
    state.toggleQuickLook()

    // Space on an image keeps Lightbox's own preview.
    state.clearSelection()
    state.handleSpace(on: image)
    await waitWhile { state.previewAssetID == nil }
    #expect(state.previewAssetID == image.id && !panel.isVisible)
    #expect(!state.canQuickLook)
    state.closeActiveOverlay()
}
