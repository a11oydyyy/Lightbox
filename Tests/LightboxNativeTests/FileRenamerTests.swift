import Foundation
import Testing
@testable import LightboxNative

private func makeFolder(_ names: [String]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxRename-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
    return folder
}

private func contents(_ folder: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
        result[name] = String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
    }
    return result
}

@Test func batchRuleNamesKeepExtensions() {
    let names = ["IMG_0001.JPG", "IMG_0002.jpg", "notes", "archive.tar.gz"]
    #expect(FileRenamer.names(for: names, rule: .replace(find: "IMG_", with: "京都 ")) ==
            ["京都 0001.JPG", "京都 0002.jpg", "notes", "archive.tar.gz"])
    #expect(FileRenamer.names(for: names, rule: .replace(find: "", with: "x")) == names)
    #expect(FileRenamer.names(for: names, rule: .add(text: "-edit", atEnd: true)) ==
            ["IMG_0001-edit.JPG", "IMG_0002-edit.jpg", "notes-edit", "archive.tar-edit.gz"])
    #expect(FileRenamer.names(for: ["a.jpg"], rule: .add(text: "2026 ", atEnd: false)) == ["2026 a.jpg"])
    // Numbers pad to the widest one, so names sort in order anywhere.
    let twelve = (1...12).map { "x\($0).heic" }
    #expect(FileRenamer.names(for: twelve, rule: .format(name: "海邊", start: 1)).prefix(2) == ["海邊 01.heic", "海邊 02.heic"])
    #expect(FileRenamer.names(for: twelve, rule: .format(name: "", start: 1)).last == "12.heic")
    #expect(FileRenamer.names(for: ["a.jpg", "b.jpg"], rule: .format(name: "Trip", start: 9)) == ["Trip 09.jpg", "Trip 10.jpg"])
}

@Test func namesAreCheckedBeforeTouchingTheDisk() {
    let folder = URL(fileURLWithPath: "/tmp/rename-check")
    func item(_ old: String, _ new: String) -> FileRenameItem { FileRenameItem(url: folder.appendingPathComponent(old), newName: new) }
    #expect(FileRenamer.issue(in: [item("a.jpg", "  ")]) == .empty)
    #expect(FileRenamer.issue(in: [item("a.jpg", "a/b.jpg")]) == .invalidCharacter)
    #expect(FileRenamer.issue(in: [item("a.jpg", "a:b.jpg")]) == .invalidCharacter)
    #expect(FileRenamer.issue(in: [item("a.jpg", ".a.jpg")]) == .leadingDot)
    #expect(FileRenamer.issue(in: [item("a.jpg", String(repeating: "長", count: 90))]) == .tooLong)
    // Case and Unicode composition do not tell names apart.
    #expect(FileRenamer.issue(in: [item("a.jpg", "Same.jpg"), item("b.jpg", "same.JPG")]) == .duplicate("same.JPG"))
    #expect(FileRenamer.issue(in: [item("a.jpg", "Cafe\u{301}.jpg"), item("b.jpg", "Caf\u{e9}.jpg")]) == .duplicate("Caf\u{e9}.jpg"))
    #expect(FileRenamer.issue(in: [item("a.jpg", "b.jpg"), item("b.jpg", "a.jpg")]) == nil)
}

@Test func renamingSwapsChangesCaseAndUndoes() throws {
    let folder = try makeFolder(["a.jpg", "b.jpg", "c.txt"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let items = [
        FileRenameItem(url: folder.appendingPathComponent("a.jpg"), newName: "b.jpg"),
        FileRenameItem(url: folder.appendingPathComponent("b.jpg"), newName: "a.jpg"),
        FileRenameItem(url: folder.appendingPathComponent("c.txt"), newName: "C.txt")
    ]
    let moves = try FileRenamer.perform(items).get()
    #expect(moves.count == 3)
    #expect(try contents(folder) == ["b.jpg": "a.jpg", "a.jpg": "b.jpg", "C.txt": "c.txt"])
    // Renaming back is the undo.
    #expect(try FileRenamer.perform(FileRenamer.reversal(of: moves)).get().count == 3)
    #expect(try contents(folder) == ["a.jpg": "a.jpg", "b.jpg": "b.jpg", "c.txt": "c.txt"])
    // Unchanged names are not moves.
    #expect(try FileRenamer.perform([FileRenameItem(url: folder.appendingPathComponent("a.jpg"), newName: "a.jpg")]).get().isEmpty)
}

@Test func renamingNeverReplacesAFileAndUndoesAPartialBatch() throws {
    let folder = try makeFolder(["a.jpg", "b.jpg", "taken.jpg"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = FileRenamer.perform([
        FileRenameItem(url: folder.appendingPathComponent("a.jpg"), newName: "first.jpg"),
        FileRenameItem(url: folder.appendingPathComponent("b.jpg"), newName: "taken.jpg")
    ])
    #expect(result == .failure(.exists("taken.jpg")))
    // The first rename was put back and nothing was overwritten.
    #expect(try contents(folder) == ["a.jpg": "a.jpg", "b.jpg": "b.jpg", "taken.jpg": "taken.jpg"])
    let missing = FileRenamer.perform([FileRenameItem(url: folder.appendingPathComponent("gone.jpg"), newName: "x.jpg")])
    #expect(missing == .failure(.failed("x.jpg")))
}

@MainActor
@Test func renamingUpdatesTheGalleryInPlaceAndUndoes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxRenameState-\(UUID())")
    let work = root.appendingPathComponent("京都")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.jpg", "taken.jpg"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxRenameState-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager()
    undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         renameUndoManager: { undo })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    state.setSortField(.fileName)
    if state.sortDirection == .descending { state.toggleSortDirection() }
    await waitWhile { state.activeAssets.count != 3 || state.libraryLoadingStatus != nil }
    #expect(state.activeAssets.map(\.originalName) == ["a.jpg", "b.jpg", "taken.jpg"])
    func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: work.path)) }

    // The sheet opens for the selection, in gallery order.
    let picked = state.activeAssets.prefix(2)
    state.replaceSelection(with: Set(picked.map(\.id)))
    #expect(state.canRename)
    state.beginRename()
    let request = try #require(state.renameRequest)
    #expect(request.assets.map(\.originalName) == ["a.jpg", "b.jpg"])
    let urls = request.assets.compactMap(\.sourceURL)
    let newNames = FileRenamer.names(for: urls.map(\.lastPathComponent), rule: .format(name: "京都", start: 1))
    let items = zip(urls, newNames).map { FileRenameItem(url: $0, newName: $1) }

    var outcome: FileRenameIssue?? = .none
    undo.beginUndoGrouping()
    state.rename(items) { outcome = .some($0) }
    undo.endUndoGrouping()
    await waitWhile { outcome == nil }
    #expect(outcome == .some(nil))
    #expect(try names() == ["京都 1.jpg", "京都 2.jpg", "taken.jpg"])
    // Shown under the new names at once, still selected and focused.
    #expect(Set(state.activeAssets.map(\.originalName)) == ["京都 1.jpg", "京都 2.jpg", "taken.jpg"])
    let renamedIDs = Set(state.activeAssets.filter { $0.originalName.hasPrefix("京都") }.map(\.id))
    #expect(state.selectedAssetIDs == renamedIDs)
    #expect(undo.canUndo && undo.undoActionName == state.renameText.undoAction)

    // ⌘Z puts the names back; ⌘⇧Z renames again.
    undo.undo()
    await waitWhile { (try? names()) != ["a.jpg", "b.jpg", "taken.jpg"] }
    #expect(try names() == ["a.jpg", "b.jpg", "taken.jpg"])
    await waitWhile { !state.activeAssets.contains(where: { $0.originalName == "a.jpg" }) }
    #expect(state.selectedAssetIDs == Set(picked.map(\.id)))
    #expect(undo.canRedo)
    undo.redo()
    await waitWhile { !state.activeAssets.contains(where: { $0.originalName == "京都 1.jpg" }) }
    #expect(try names() == ["京都 1.jpg", "京都 2.jpg", "taken.jpg"])

    // A clash with another file changes nothing and leaves no undo step.
    undo.removeAllActions()
    let first = try #require(state.activeAssets.first { $0.originalName == "京都 1.jpg" }?.sourceURL)
    outcome = .none
    undo.beginUndoGrouping()
    state.rename([FileRenameItem(url: first, newName: "taken.jpg")]) { outcome = .some($0) }
    undo.endUndoGrouping()
    await waitWhile { outcome == nil }
    #expect(outcome == .some(.exists("taken.jpg")))
    #expect(try names() == ["京都 1.jpg", "京都 2.jpg", "taken.jpg"])
    #expect(!undo.canUndo)

    // Not in the trash, nor over a preview.
    state.clearSelection()
    state.showPreview(for: state.activeAssets[0])
    await waitWhile { state.previewAssetID == nil }
    #expect(!state.canRename)
    state.closeActiveOverlay()
}

@Test func foldersAreCreatedOnceAndRemovedOnlyWhenEmpty() throws {
    let parent = try makeFolder(["a.jpg"])
    defer { try? FileManager.default.removeItem(at: parent) }
    let created = try FileRenamer.createFolder(named: "未命名資料夾", in: parent).get()
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    #expect(FileRenamer.createFolder(named: "未命名資料夾", in: parent) == .failure(.exists("未命名資料夾")))
    #expect(FileRenamer.createFolder(named: "a.jpg", in: parent) == .failure(.exists("a.jpg")))
    #expect(FileRenamer.createFolder(named: "a/b", in: parent) == .failure(.invalidCharacter))
    // Undo removes it only while it is empty.
    try Data([1]).write(to: created.appendingPathComponent("kept.jpg"))
    #expect(!FileRenamer.removeEmptyFolder(created))
    #expect(FileManager.default.fileExists(atPath: created.appendingPathComponent("kept.jpg").path))
    try FileManager.default.removeItem(at: created.appendingPathComponent("kept.jpg"))
    #expect(FileRenamer.removeEmptyFolder(created))
    #expect(!FileManager.default.fileExists(atPath: created.path))
}

@MainActor
@Test func newFolderShowsSelectedAndUndoes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxNewFolder-\(UUID())")
    let work = root.appendingPathComponent("海邊")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: work.appendingPathComponent("a.jpg"))
    let suite = "LightboxNewFolder-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager()
    undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         renameUndoManager: { undo })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    await waitWhile { state.activeAssets.count != 1 || state.libraryLoadingStatus != nil }
    #expect(state.canCreateFolder)
    state.beginNewFolder()
    #expect(state.newFolderRequest?.parent.standardizedFileURL.path == work.standardizedFileURL.path)
    let folder = work.appendingPathComponent("草稿")
    func listed() -> Bool { state.folderEntries.contains { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path } }

    var outcome: FileRenameIssue?? = .none
    undo.beginUndoGrouping()
    state.createFolder(named: "草稿", in: work) { outcome = .some($0) }
    undo.endUndoGrouping()
    await waitWhile { outcome == nil }
    #expect(outcome == .some(nil))
    #expect(FileManager.default.fileExists(atPath: folder.path) && listed())
    #expect(state.selectedGalleryFolderID?.hasSuffix("/草稿") == true)
    #expect(undo.undoActionName == state.renameText.newFolderUndo)

    undo.undo()
    await waitWhile { listed() }
    #expect(!FileManager.default.fileExists(atPath: folder.path) && !listed())
    undo.redo()
    await waitWhile { !listed() }
    #expect(FileManager.default.fileExists(atPath: folder.path) && listed())

    // Something put inside keeps the folder; the undo says so.
    try Data([1]).write(to: folder.appendingPathComponent("b.jpg"))
    undo.undo()
    await waitWhile { state.fileOperationAlert == nil }
    #expect(state.fileOperationAlert == state.renameText.folderNotEmpty("草稿"))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.jpg").path))
    #expect(!undo.canUndo && !undo.canRedo)

    // A name already in use leaves nothing to undo.
    outcome = .none
    undo.beginUndoGrouping()
    state.createFolder(named: "a.jpg", in: work) { outcome = .some($0) }
    undo.endUndoGrouping()
    await waitWhile { outcome == nil }
    #expect(outcome == .some(.exists("a.jpg")) && !undo.canUndo)
}

/// A stand-in Trash: a folder, and where each item came from.
final class FakeTrash: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var origins: [String: URL] = [:]
    init(folder: URL) { self.folder = folder }

    func move(_ url: URL) -> URL? {
        let trashed = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        guard (try? FileManager.default.moveItem(at: url, to: trashed)) != nil else { return nil }
        lock.withLock { origins[trashed.path] = url }
        return trashed
    }

    func putBack(_ trashed: URL) -> TrashRestoreResult {
        guard let origin = lock.withLock({ origins[trashed.path] }),
              (try? FileManager.default.moveItem(at: trashed, to: origin)) != nil else { return .failed }
        return .restored(origin)
    }
}

// Rename, then Move to Trash, then ⌘Z twice: the file comes back from the
// Trash first, then gets its old name; redo does both again.
@MainActor
@Test func moveToTrashUndoesBeforeAnEarlierRename() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxTrashUndo-\(UUID())")
    let work = root.appendingPathComponent("folder")
    let trash = FakeTrash(folder: root.appendingPathComponent("Trash"))
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trash.folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.jpg"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxTrashUndo-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager()
    undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         systemTrashMover: { trash.move($0) }, systemTrashRestorer: { trash.putBack($0) },
                         renameUndoManager: { undo })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    await waitWhile { state.activeAssets.count != 2 || state.libraryLoadingStatus != nil }
    func names() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []) }
    func waitFor(_ expected: Set<String>) async throws {
        await waitWhile { names() != expected }
        #expect(names() == expected)
    }

    let a = try #require(state.activeAssets.first { $0.originalName == "a.jpg" })
    undo.beginUndoGrouping()
    state.rename([FileRenameItem(url: try #require(a.sourceURL), newName: "renamed.jpg")])
    undo.endUndoGrouping()
    try await waitFor(["renamed.jpg", "b.jpg"])
    await waitWhile { !state.activeAssets.contains(where: { $0.originalName == "renamed.jpg" }) }

    let renamed = try #require(state.activeAssets.first { $0.originalName == "renamed.jpg" })
    state.replaceSelection(with: [renamed.id])
    undo.beginUndoGrouping()
    state.deleteSelectedAssets()
    undo.endUndoGrouping()
    try await waitFor(["b.jpg"])
    #expect(undo.undoActionName == state.localized(.moveToTrash))

    undo.undo()
    try await waitFor(["renamed.jpg", "b.jpg"])
    #expect(state.fileOperationAlert == nil)
    await waitWhile { !state.activeAssets.contains(where: { $0.originalName == "renamed.jpg" }) }
    #expect(undo.undoActionName == state.renameText.undoAction)
    undo.undo()
    try await waitFor(["a.jpg", "b.jpg"])
    #expect(state.fileOperationAlert == nil)

    undo.redo()
    try await waitFor(["renamed.jpg", "b.jpg"])
    await waitWhile { !state.activeAssets.contains(where: { $0.originalName == "renamed.jpg" }) }
    undo.redo()
    try await waitFor(["b.jpg"])
    #expect(state.fileOperationAlert == nil)
}

@Test func folderRenameMovesPathsInsideTheFolderOnly() {
    let move = FolderRenameMove(from: URL(fileURLWithPath: "/Volumes/NAS/2024", isDirectory: true),
                                to: URL(fileURLWithPath: "/Volumes/NAS/2024 京都", isDirectory: true))
    #expect(move.moved(URL(fileURLWithPath: "/Volumes/NAS/2024"))?.path == "/Volumes/NAS/2024 京都")
    #expect(move.moved(URL(fileURLWithPath: "/Volumes/NAS/2024/a/b.jpg"))?.path == "/Volumes/NAS/2024 京都/a/b.jpg")
    #expect(move.moved(path: "/Volumes/NAS/2024/a") == "/Volumes/NAS/2024 京都/a")
    // A sibling sharing the name's start, and the parent, stay where they are.
    #expect(move.moved(URL(fileURLWithPath: "/Volumes/NAS/2024-old/a.jpg")) == nil)
    #expect(move.moved(URL(fileURLWithPath: "/Volumes/NAS")) == nil)
}

// Renaming a folder from the gallery: tabs, their history, pinned folders,
// recent folders and saved sorts inside it follow; ⌘Z puts it all back.
@MainActor
@Test func folderRenameIsFollowedEverywhereAndUndoes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxFolderRename-\(UUID())")
    let work = root.appendingPathComponent("照片").standardizedFileURL
    let folder = work.appendingPathComponent("2024").standardizedFileURL
    let inner = folder.appendingPathComponent("京都").standardizedFileURL
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: work.appendingPathComponent("a.jpg"))
    try Data([1]).write(to: inner.appendingPathComponent("b.jpg"))
    let suite = "LightboxFolderRename-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager()
    undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         renameUndoManager: { undo })
    let library = LibrarySource.favorites(rootURL: work)
    state.sources = [library]
    state.chooseSource(library.id)
    await waitWhile { state.folderEntries.isEmpty || state.libraryLoadingStatus != nil }

    // Things kept by path inside the folder, and one outside it.
    state.pinSource(LibrarySourceStore.makeExternalSource(rootURL: folder), selectPinnedFolder: false)
    let elsewhere = root.appendingPathComponent("2024-old").standardizedFileURL
    state.recentFolderURLs = [inner, elsewhere]
    let sortKey = "Lightbox.folderSort.v1.folder:"
    defaults.set(["field": "fileName", "direction": "ascending"], forKey: sortKey + inner.path)
    state.setGroup(inner.path, collapsed: true)
    state.setGroup(elsewhere.path, collapsed: true)
    let back = LightboxTabLocation(source: library, folderURL: folder, filter: .all)
    state.tabSession.insert(LightboxTab(source: library, folderURL: inner, backHistory: [back]), after: nil)
    let tabID = try #require(state.tabs.last?.id)

    let entry = try #require(state.activeFolderEntries.first { $0.url.lastPathComponent == "2024" })
    state.selectGalleryFolder(entry.id)
    #expect(state.canRename)
    state.beginRename()
    #expect(state.folderRenameRequest?.folder == entry)
    #expect(state.renameRequest == nil)

    var outcome: FileRenameIssue?? = .none
    undo.beginUndoGrouping()
    state.renameFolder(FileRenameItem(url: entry.url, newName: "2024 京都")) { outcome = .some($0) }
    undo.endUndoGrouping()
    await waitWhile { outcome == nil }
    #expect(outcome == .some(nil))
    let renamed = work.appendingPathComponent("2024 京都").standardizedFileURL
    let renamedInner = renamed.appendingPathComponent("京都").standardizedFileURL
    #expect(FileManager.default.fileExists(atPath: renamedInner.appendingPathComponent("b.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: folder.path))

    // Listed and selected under the new name at once.
    #expect(state.activeFolderEntries.map(\.url.lastPathComponent) == ["2024 京都"])
    #expect(state.selectedGalleryFolderID?.hasSuffix("/2024 京都") == true)
    // The pinned folder keeps its place, with the folder's new name.
    let pinned = try #require(state.sources.first { !$0.isLocalLibrary })
    #expect(pinned.rootURL.path == renamed.path && pinned.displayName == "2024 京都")
    #expect(state.sources.first { $0.isLocalLibrary }?.rootURL.path == work.path)
    // The other tab and its history.
    let tab = try #require(state.tabSession.tab(tabID))
    #expect(tab.folderURL.path == renamedInner.path)
    #expect(tab.backHistory.map(\.folderURL.path) == [renamed.path])
    // Recent folders and the saved sort; the look-alike sibling stays.
    #expect(state.recentFolderURLs.map(\.path) == [renamedInner.path, elsewhere.path])
    #expect(defaults.object(forKey: sortKey + inner.path) == nil)
    #expect((defaults.object(forKey: sortKey + renamedInner.path) as? [String: String])?["field"] == "fileName")
    // A collapsed subfolder group stays collapsed under its new path.
    #expect(state.collapsedGroupFolderPaths == [renamedInner.path, elsewhere.path])
    #expect(defaults.stringArray(forKey: AppState.collapsedGroupFoldersKey) == [renamedInner.path, elsewhere.path])
    #expect(undo.undoActionName == state.renameText.undoAction)

    // ⌘Z renames it back, and everything follows again.
    undo.undo()
    await waitWhile { !FileManager.default.fileExists(atPath: folder.path) || state.tabSession.tab(tabID)?.folderURL.path != inner.path }
    #expect(!FileManager.default.fileExists(atPath: renamed.path))
    #expect(state.sources.first { !$0.isLocalLibrary }?.displayName == "2024")
    #expect(state.recentFolderURLs.first?.path == inner.path)

    // The library's own folder cannot be renamed.
    let libraryEntry = LibraryFolderEntry(sourceID: library.id, url: work, rootURL: root)
    #expect(!state.canRenameFolder(libraryEntry))
}
