import Foundation
import Testing
@testable import LightboxNative

// With subfolders included, a file appearing anywhere below the folder
// refreshes the results without emptying the gallery first or forgetting
// the dimensions of images that did not change.
@MainActor
@Test func recursiveResultsStayOnScreenWhileAChangeRefreshesThem() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxRecursiveContinuity-\(UUID())")
    let child = work.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for name in ["a.jpg", "b.jpg", "c.jpg"] { try Data([1]).write(to: child.appendingPathComponent(name)) }
    let suite = "LightboxRecursiveContinuity-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    state.galleryLayoutMode = .recursive
    func settled(_ count: Int) -> Bool {
        state.activeAssets.count == count && state.activeAssets.allSatisfy(\.metadataLoaded)
            && state.searchStatus?.isSearching == false && state.searchStatus?.isLoadingMetadata == false
    }
    await waitWhile { !settled(3) }
    #expect(settled(3))

    for (index, folder) in [child, work].enumerated() {
        let before = state.activeAssets.count
        try Data([1]).write(to: folder.appendingPathComponent("new-\(index).jpg"))
        var fewestShown = before
        var forgotDimensions = false
        await waitWhile {
            fewestShown = min(fewestShown, state.activeAssets.count)
            if state.activeAssets.contains(where: { $0.originalName == "a.jpg" && !$0.metadataLoaded }) { forgotDimensions = true }
            return !settled(before + 1)
        }
        #expect(settled(before + 1))
        #expect(fewestShown == before, "the gallery dropped to \(fewestShown) images")
        #expect(!forgotDimensions)
    }
}

// The list shows one folder, as Finder's does; the tab keeps its scope and the
// grid shows the subfolders again.
@MainActor
@Test func listViewShowsThisFolderOnlyAndTheGridGetsSubfoldersBack() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxListScope-\(UUID())")
    let child = work.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    try Data([1]).write(to: work.appendingPathComponent("top.jpg"))
    for name in ["a.jpg", "b.jpg"] { try Data([1]).write(to: child.appendingPathComponent(name)) }
    let suite = "LightboxListScope-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    state.galleryLayoutMode = .recursive
    func names() -> Set<String> { Set(state.activeAssets.map(\.originalName)) }
    await waitWhile { names() != ["top.jpg", "a.jpg", "b.jpg"] }
    #expect(state.includesSubfolders)

    state.galleryViewMode = .list
    #expect(!state.includesSubfolders && state.galleryLayoutMode == .recursive)
    await waitWhile { names() != ["top.jpg"] || state.libraryLoadingStatus != nil }
    #expect(names() == ["top.jpg"])

    state.galleryViewMode = .grid
    #expect(state.includesSubfolders)
    await waitWhile { names() != ["top.jpg", "a.jpg", "b.jpg"] }
    #expect(names() == ["top.jpg", "a.jpg", "b.jpg"])
}
