import AppKit
import Foundation
import Testing
@testable import LightboxNative

// The list shows the gallery's own content, selection and sort: folders
// first, then files; picking rows selects in the app; headers sort the app.
@MainActor
@Test func listRowsShareTheGallerysSelectionAndSort() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxFileList-\(UUID())")
    let work = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: work.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.jpg", "doc.pdf"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxFileList-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let opened = OpenedURLs()
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         previewDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         defaultApplicationOpener: { opened.urls.append(contentsOf: $0) })
    state.showsOtherFiles = true
    state.galleryViewMode = .list
    #expect(LightboxSettingsStore.loadViewMode(defaults: defaults) == .list)
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    state.setSortField(.fileName)
    if state.sortDirection == .descending { state.toggleSortDirection() }
    await waitWhile { state.activeAssets.count != 3 || state.libraryLoadingStatus != nil || state.activeFolderEntries.isEmpty }

    let coordinator = FileListCoordinator(appState: state)
    let table = FileListTableView()
    table.coordinator = coordinator
    table.dataSource = coordinator
    table.delegate = coordinator
    table.allowsMultipleSelection = true
    for column in coordinator.makeColumns() { table.addTableColumn(column) }
    coordinator.update(table, appState: state)
    func names() -> [String] {
        coordinator.rows.map { row in
            switch row {
            case .folder(let folder): "[\(folder.name)]"
            case .asset(let asset): asset.originalName
            }
        }
    }
    #expect(names() == ["[sub]", "a.jpg", "b.jpg", "doc.pdf"])
    #expect(table.tableColumns.first?.title == FileListText(state.appLanguage).name)
    // The location column only matters with subfolders included.
    #expect(table.tableColumns.first { $0.identifier.rawValue == "location" }?.isHidden == true)
    #expect(table.sortDescriptors.first?.key == GallerySortField.fileName.rawValue && table.sortDescriptors.first?.ascending == true)

    // Picking rows selects those files in the app (the header bar, tags,
    // compare and the menus all follow); the app's selection shows in the rows.
    table.selectRowIndexes([1, 2], byExtendingSelection: false)
    #expect(state.selectedAssetIDs == Set(coordinator.rows[1...2].compactMap(\.asset?.id)))
    #expect(state.canCompareSelection)
    state.replaceSelection(with: [coordinator.rows[3].asset!.id])
    coordinator.update(table, appState: state)
    #expect(table.selectedRowIndexes == [3])
    table.selectRowIndexes([0], byExtendingSelection: false)
    #expect(state.selectedGalleryFolderID == { if case .folder(let f) = coordinator.rows[0] { f.id } else { nil } }())
    #expect(state.selectedAssetIDs.isEmpty)

    // A header click sorts the app; the gallery sort shows in the header.
    table.sortDescriptors = [NSSortDescriptor(key: GallerySortField.size.rawValue, ascending: false)]
    #expect(state.sortField == .size && state.sortDirection == .descending)
    state.setSortField(.type)
    coordinator.update(table, appState: state)
    #expect(table.sortDescriptors.first?.key == GallerySortField.type.rawValue)

    // Return / double click: a file opens in its app, an image previews,
    // a folder opens.
    state.setSortField(.fileName)
    if state.sortDirection == .descending { state.toggleSortDirection() }
    coordinator.update(table, appState: state)
    coordinator.activate(row: 3)
    await waitWhile { opened.urls.isEmpty }
    #expect(opened.urls.map(\.lastPathComponent) == ["doc.pdf"])
    coordinator.activate(row: 1)
    await waitWhile { state.previewAssetID == nil }
    #expect(state.previewAssetID == coordinator.rows[1].asset?.id)
    state.closeActiveOverlay()
    await waitWhile { state.hasActiveOverlay }
    // The list shows focus as a selection: the image just viewed stays selected.
    #expect(state.selectedAssetIDs == [coordinator.rows[1].asset!.id])
    coordinator.update(table, appState: state)
    #expect(table.selectedRowIndexes == [1])
    coordinator.activate(row: 0)
    #expect(state.currentFolderURL.lastPathComponent == "sub")

    // Rows offer the file actions; images only can join the compare tray.
    state.goBack()
    await waitWhile { state.activeAssets.count != 3 || state.libraryLoadingStatus != nil }
    coordinator.update(table, appState: state)
    let pdfRow = try #require(coordinator.rows.firstIndex { $0.asset?.originalName == "doc.pdf" })
    let menu = try #require(coordinator.menu(forRow: pdfRow))
    let titles = AssetContextMenuTitles(appState: state)
    #expect(menu.items.contains { $0.title == titles.rename } && menu.items.contains { $0.title == titles.quickLook })
    #expect(menu.items.first { $0.title == state.localized(.addToCompareTray) }?.isEnabled == false)
}

@MainActor
private final class OpenedURLs {
    var urls: [URL] = []
}

// Switching to the list while a folder is still loading: the list made
// during the load fills in, and its empty state waits, once the load lands.
@MainActor
@Test func listOpenedDuringALoadFillsInWhenTheLoadFinishes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxListDuringLoad-\(UUID())")
    let work = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.jpg", "c.jpg"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxListDuringLoad-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    #expect(state.libraryLoadingStatus != nil)
    state.galleryViewMode = .list

    let coordinator = FileListCoordinator(appState: state)
    let table = FileListTableView()
    table.dataSource = coordinator
    table.delegate = coordinator
    for column in coordinator.makeColumns() { table.addTableColumn(column) }
    coordinator.update(table, appState: state)

    await waitWhile { state.libraryLoadingStatus != nil || state.activeAssets.count != 3 }
    coordinator.update(table, appState: state)
    #expect(state.galleryViewMode == .list)
    #expect(table.numberOfRows == 3)
}

// The preview zooms into the list's thumbnail as drawn: the image's own
// proportions inside the icon square, with the list's corners.
@MainActor
@Test func listThumbnailsGiveThePreviewTheirShape() {
    let square = CGRect(x: 10, y: 20, width: 18, height: 18)
    #expect(FileListMetrics.thumbnailRect(for: CGSize(width: 6000, height: 4000), in: square)
            == CGRect(x: 10, y: 23, width: 18, height: 12))
    #expect(FileListMetrics.thumbnailRect(for: CGSize(width: 3000, height: 6000), in: square)
            == CGRect(x: 14.5, y: 20, width: 9, height: 18))

    let suite = "LightboxListThumbnail-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AppState(indexDatabaseURL: FileManager.default.temporaryDirectory
                            .appendingPathComponent("LightboxListThumbnail-\(UUID()).sqlite"),
                         libraryDefaults: defaults)
    #expect(state.previewSourceCornerRadius == RadiusTokens.card)
    state.setPreviewSpaceAssetFrameProvider(cornerRadius: FileListMetrics.thumbnailRadius) { [:] }
    #expect(state.previewSourceCornerRadius == FileListMetrics.thumbnailRadius)
    // The gallery's cards, or nothing, put the card's corners back.
    state.setPreviewSpaceAssetFrameProvider(nil)
    #expect(state.previewSourceCornerRadius == RadiusTokens.card)
}
