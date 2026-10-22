import AppKit
import Foundation
import Testing
@testable import LightboxNative

@Test func cullMarksReplaceEachOtherAndKeepOtherColors() {
    #expect(CullMark.keep.applied(to: ["Red", "Blue"]) == MacColorTag.sort(["Green", "Blue"]))
    #expect(CullMark.reject.applied(to: ["Green"]) == ["Red"])
    #expect(CullMark.clear.applied(to: ["Green", "Red", "Purple"]) == ["Purple"])
    #expect(CullMark.keep.applied(to: ["Green"]) == ["Green"])
}

// P keeps and X rejects the image on screen (Finder tags on the file) and
// move to the next one, not past the last; U clears; ⌘Z puts tags back.
@MainActor
@Test func previewCullingTagsFilesAdvancesAndUndoes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxCulling-\(UUID())")
    let work = root.appendingPathComponent("shoot")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.jpg", "c.jpg"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    #expect(FinderTagStore.setColorTags(["Blue"], for: work.appendingPathComponent("a.jpg")))
    let suite = "LightboxCulling-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager()
    undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         previewDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         renameUndoManager: { undo })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    state.setSortField(.fileName)
    if state.sortDirection == .descending { state.toggleSortDirection() }
    await waitWhile { state.activeAssets.count != 3 || state.libraryLoadingStatus != nil }
    func tags(_ name: String) -> [String] { FinderTagStore.colorTags(for: work.appendingPathComponent(name)) }
    func mark(_ mark: CullMark) async {
        undo.beginUndoGrouping()
        state.markPreviewAsset(mark)
        undo.endUndoGrouping()
        await waitWhile { state.tagMutationTask != nil }
    }

    state.showPreview(for: state.activeAssets[0])
    await waitWhile { state.previewPhase != .open }
    await mark(.keep)
    #expect(tags("a.jpg") == MacColorTag.sort(["Green", "Blue"]))
    #expect(state.cullFeedback?.mark == .keep)
    await waitWhile { state.previewAssetID != state.activeAssets[1].id }
    #expect(state.previewAssetID == state.activeAssets[1].id)

    await mark(.reject)
    #expect(tags("b.jpg") == ["Red"])
    await waitWhile { state.previewAssetID != state.activeAssets[2].id }

    // The last image stays on screen; keep replaces nothing else.
    await mark(.keep)
    #expect(tags("c.jpg") == ["Green"])
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.previewAssetID == state.activeAssets[2].id)
    await mark(.clear)
    #expect(tags("c.jpg").isEmpty)

    // Undo walks back one mark at a time; redo reapplies.
    undo.undo()
    await waitWhile { state.tagMutationTask != nil || tags("c.jpg") != ["Green"] }
    #expect(tags("c.jpg") == ["Green"])
    undo.undo(); undo.undo()
    await waitWhile { state.tagMutationTask != nil || !tags("b.jpg").isEmpty }
    #expect(tags("b.jpg").isEmpty && tags("c.jpg").isEmpty)
    undo.redo()
    await waitWhile { state.tagMutationTask != nil || tags("b.jpg") != ["Red"] }
    #expect(tags("b.jpg") == ["Red"])
    #expect(state.activeAssets.first { $0.originalName == "b.jpg" }?.tags == ["Red"])
}
