import AppKit
import Foundation
import Testing
@testable import LightboxNative

// "Show Other Files" lists non-image files as square icon tiles. They have no
// preview or comparison yet: a click focuses one, a double click opens it in
// its own app, and preview stepping and comparisons pass over them.

@Test func otherFilesAreSquareTilesWithNothingToLoad() {
    let pdf = LightboxAsset(originalName: "Report.PDF", width: 1, height: 1, tags: [],
                            sourceURL: URL(fileURLWithPath: "/tmp/other/Report.PDF"), addedAt: .distantPast,
                            palette: MockPalette.imported[0], metadataLoaded: false)
    #expect(!pdf.isImage && pdf.metadataLoaded && pdf.aspectRatio == 1)
    let raw = LightboxAsset(originalName: "IMG_1.CR3", width: 1, height: 1, tags: [],
                            sourceURL: URL(fileURLWithPath: "/tmp/other/IMG_1.CR3"), addedAt: .distantPast,
                            palette: MockPalette.imported[0], metadataLoaded: false)
    #expect(raw.isImage && !raw.metadataLoaded)
    // Assets without a file are images (mock and in-memory ones).
    let memory = LightboxAsset(originalName: "Sample", width: 30, height: 20, tags: [], addedAt: .distantPast,
                               palette: MockPalette.imported[0])
    #expect(memory.isImage && memory.width == 30)
    #expect(LightboxAsset.isImageID(raw.id) && !LightboxAsset.isImageID(pdf.id) && LightboxAsset.isImageID(memory.id))
}

@Test func scansListOtherFilesOnlyWhenAsked() throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxOtherFilesScan-\(UUID())")
    let child = work.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for name in ["a.jpg", "b.pdf", "notes.txt"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    for name in ["c.heic", "clip.mov"] { try Data([1]).write(to: child.appendingPathComponent(name)) }

    func names(_ assets: [LightboxAsset]) -> Set<String> { Set(assets.map(\.originalName)) }
    let imagesOnly = LocalImageSource.loadFolderSnapshot(in: work, sourceID: "s", rootURL: work, probeMetadata: false)
    #expect(names(imagesOnly.assets) == ["a.jpg"])
    #expect(imagesOnly.folders.map(\.url.lastPathComponent) == ["child"])
    let everything = LocalImageSource.loadFolderSnapshot(in: work, sourceID: "s", rootURL: work, probeMetadata: false,
                                                         includesOtherFiles: true)
    #expect(names(everything.assets) == ["a.jpg", "b.pdf", "notes.txt"])
    let others = everything.assets.filter { !$0.isImage }
    #expect(others.count == 2 && others.allSatisfy(\.metadataLoaded))

    let recursiveImages = LocalImageSource.searchAssets(in: work, sourceID: "s", rootURL: work, query: .parse(""),
                                                        recursive: true, loadsFinderTags: false)
    #expect(names(recursiveImages.assets) == ["a.jpg", "c.heic"])
    let recursiveEverything = LocalImageSource.searchAssets(in: work, sourceID: "s", rootURL: work, query: .parse(""),
                                                            recursive: true, includesOtherFiles: true, loadsFinderTags: false)
    #expect(names(recursiveEverything.assets) == ["a.jpg", "b.pdf", "notes.txt", "c.heic", "clip.mov"])
}

@MainActor
private final class OpenedFiles {
    var urls: [URL] = []
}

@MainActor
private func click(count: Int) throws -> LightboxClickContext {
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    return LightboxClickContext(event: event, in: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), trigger: .mouseUp)
}

@MainActor
@Test func otherFilesOpenInTheirAppAndStayOutOfPreviewAndComparison() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxOtherFilesState-\(UUID())")
    // The index lives beside the folder: once other files are listed, it would show in it.
    let work = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.jpg", "doc.pdf"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxOtherFiles-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let opened = OpenedFiles()
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         previewDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         defaultApplicationOpener: { opened.urls.append(contentsOf: $0) })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    func settled(_ count: Int) -> Bool {
        state.activeAssets.count == count && state.libraryLoadingStatus == nil
    }
    await waitWhile { !settled(2) }
    #expect(settled(2) && state.activeAssets.allSatisfy(\.isImage))

    state.showsOtherFiles = true
    #expect(LightboxSettingsStore.loadShowsOtherFiles(defaults: defaults))
    await waitWhile { !settled(3) }
    #expect(settled(3))
    let doc = try #require(state.activeAssets.first { !$0.isImage })
    let images = state.activeAssets.filter(\.isImage)

    // A click focuses the file without starting a selection or a preview.
    state.handleAssetClick(doc, modifiers: [], click: try click(count: 1), sourceFrame: nil)
    #expect(state.selectedAssetID == doc.id && state.selectedAssetIDs.isEmpty && state.previewAssetID == nil)
    #expect(opened.urls.isEmpty)
    // A double click, or Return/Space through the preview path, opens it.
    state.handleAssetClick(doc, modifiers: [], click: try click(count: 2), sourceFrame: nil)
    await waitWhile { opened.urls.isEmpty }
    #expect(opened.urls.map(\.lastPathComponent) == ["doc.pdf"])
    state.showPreview(for: doc)
    await waitWhile { opened.urls.count < 2 }
    #expect(opened.urls.count == 2 && state.previewAssetID == nil)

    // Preview steps between the images only.
    state.showPreview(for: images[0])
    await waitWhile { state.previewAssetID == nil }
    #expect(state.previewAssetID == images[0].id)
    var shown: [LightboxAsset.ID] = []
    for _ in 0..<3 {
        state.stepPreview(.next)
        await waitWhile { state.pendingPreviewStepAssetID != nil }
        shown.append(try #require(state.previewAssetID))
    }
    #expect(Set(shown) == Set(images.map(\.id)))
    state.closeActiveOverlay()

    // The tray turns the file away; comparing a selection leaves it out.
    let rejects = state.compareTray.rejectGeneration
    state.addToCompareTray(doc)
    #expect(state.compareTrayAssets.isEmpty && state.compareTray.rejectGeneration == rejects + 1)
    state.replaceSelection(with: [images[0].id, doc.id])
    #expect(!state.canCompareSelection)
    state.replaceSelection(with: Set(state.activeAssets.map(\.id)))
    #expect(state.canCompareSelection)
    state.showComparisonFromSelection()
    #expect(Set(state.comparisonAssets.map(\.id)) == Set(images.map(\.id)))
    state.closeComparison()

    state.showsOtherFiles = false
    await waitWhile { !settled(2) }
    #expect(settled(2) && state.activeAssets.allSatisfy(\.isImage))
}

// Apps and other packages are files to the user, as in Finder: a folder scan
// never lists them as folders to open or summarize.
@Test func packagesAreNotListedAsFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPackages-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Album"), withIntermediateDirectories: true)
    try Data([1]).write(to: root.appendingPathComponent("a.jpg"))

    let snapshot = LocalImageSource.loadFolderSnapshot(in: root, sourceID: "test", rootURL: root, includesOtherFiles: true)
    #expect(snapshot.folders.map(\.name) == ["Album"])
    #expect(snapshot.assets.map(\.originalName) == ["a.jpg"])
    #expect(LocalImageSource.folders(in: root, sourceID: "test", rootURL: root).map(\.name) == ["Album"])
}
