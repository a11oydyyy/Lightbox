import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the list: the folder's subfolders first, then its files.
enum FileListRow: Equatable {
    case folder(LibraryFolderEntry)
    case asset(LightboxAsset)

    var asset: LightboxAsset? {
        if case .asset(let asset) = self { return asset }
        return nil
    }

    var url: URL? {
        switch self {
        case .folder(let folder): folder.url
        case .asset(let asset): asset.sourceURL
        }
    }
}

enum FileListMetrics {
    static let rowHeight: CGFloat = 26
    static let headerHeight: CGFloat = 28
    /// Header titles start where the row content does: the name column's
    /// icon, the other columns' text (2pt constraint + the label's 2pt padding).
    static let nameTitleInset: CGFloat = 4
    static let titleInset: CGFloat = 4
    /// Between columns: a right-aligned Size beside a left-aligned Kind needs
    /// visible air.
    static let columnSpacing: CGFloat = 14
    static let iconSize: CGFloat = 18
    /// Corners of an image thumbnail, on the image itself; the preview zooms
    /// back into the same shape.
    static let thumbnailRadius: CGFloat = 3
    static let selectionInset: CGFloat = 4
    static let selectionRadius: CGFloat = 6
    /// Room for the floating bottom bar below the last row.
    static let bottomInset: CGFloat = 70

    /// An image of `size` fitted and centered in `bounds`, as the thumbnail draws it.
    static func thumbnailRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// Finder-style rows for the folder on screen. It shares the gallery's
/// selection, sort, focus and actions; only the presentation differs.
struct GalleryListView: View {
    @EnvironmentObject private var appState: AppState

    private var showsEmptyState: Bool {
        !appState.isViewingTrash && appState.libraryLoadingStatus == nil
            && appState.searchStatus?.isSearching != true
            && appState.activeAssets.isEmpty && appState.activeFolderEntries.isEmpty
            && !(appState.attributeFilter.needsMetadataPass && appState.isReadingImageSizes)
    }

    var body: some View {
        ZStack {
            FileListTable(appState: appState, selection: appState.selection, keyboardFocus: appState.keyboardFocus)
            if showsEmptyState {
                if appState.attributeFilter.isActive {
                    VStack(spacing: 8) {
                        Text(FilterText(appState.appLanguage).noMatches)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LightboxColorTokens.mutedText)
                        Button(FilterText(appState.appLanguage).clear) {
                            appState.attributeFilter = GalleryAttributeFilter()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text(appState.localized(appState.hasSearchQuery ? .noMatches : .noImagesHere))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LightboxColorTokens.mutedText)
                }
            }
        }
        // Below the 52pt header; the same gutters as the gallery, the
        // sidebar's resize strip counting toward the leading one.
        .padding(.top, 52)
        .padding(.leading, appState.sidebarCollapsed
                 ? GalleryThumbnailSizing.horizontalPadding
                 : GalleryThumbnailSizing.horizontalPadding - SidebarMetrics.resizeHandleWidth)
        .padding(.trailing, GalleryThumbnailSizing.horizontalPadding)
    }
}

private struct FileListTable: NSViewRepresentable {
    @ObservedObject var appState: AppState
    // Selection and focus publish on their own objects, not on `appState`.
    @ObservedObject var selection: GallerySelectionState
    @ObservedObject var keyboardFocus: GalleryKeyboardFocusState

    func makeCoordinator() -> FileListCoordinator { FileListCoordinator(appState: appState) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = FileListTableView()
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = FileListMetrics.rowHeight
        table.intercellSpacing = NSSize(width: FileListMetrics.columnSpacing, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.gridStyleMask = []
        table.target = coordinator
        table.doubleAction = #selector(FileListCoordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        for column in coordinator.makeColumns() { table.addTableColumn(column) }
        table.headerView = FileListHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: FileListMetrics.headerHeight))
        table.cornerView = nil
        table.autosaveName = "Lightbox.FileList"
        table.autosaveTableColumns = true

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: FileListMetrics.bottomInset, right: 0)
        DispatchQueue.main.async { [weak table] in
            guard let table, let window = table.window else { return }
            // Widths come back from the autosave; fit them to this window
            // (the name column takes the difference) so the last column
            // never runs under the scroller.
            table.sizeToFit()
            window.makeFirstResponder(table)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? FileListTableView else { return }
        context.coordinator.update(table, appState: appState)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: FileListCoordinator) {
        coordinator.releaseFrameProvider()
    }
}

/// Keys and the context menu; everything else is the coordinator's.
final class FileListTableView: NSTableView {
    weak var coordinator: FileListCoordinator?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, let coordinator {
            switch event.keyCode {
            case 49: coordinator.space(in: self); return
            case 36, 76: coordinator.activate(row: selectedRow); return
            case 53: coordinator.appState.clearSelection(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let coordinator else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return coordinator.menu(forRow: row)
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection(in: self)
    }
}

@MainActor
final class FileListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var appState: AppState
    private(set) var rows: [FileListRow] = []
    private var rowByID: [String: Int] = [:]
    private var contentToken: ContentToken?
    private var isSyncing = false
    private var lastScrollGeneration = -1
    private var hadOverlay = false
    private weak var table: NSTableView?
    private var providesFrames = false

    private struct ContentToken: Equatable {
        var revision: Int
        var folders: [LibraryFolderEntry]
        var showsLocation: Bool
        var language: LightboxLanguage
    }

    init(appState: AppState) {
        self.appState = appState
    }

    private var text: FileListText { FileListText(appState.appLanguage) }

    // MARK: Columns

    private enum Column: String, CaseIterable {
        case name, date, size, kind, dimensions, tags, location

        /// The gallery sort this column's header sets.
        var sortField: GallerySortField? {
            switch self {
            case .name: .fileName
            case .date: .time
            case .size: .size
            case .kind: .type
            case .tags: .tag
            case .dimensions: .dimensions
            case .location: nil
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .date: 150
            case .size: 76
            case .kind: 130
            case .dimensions: 104
            case .tags: 64
            case .location: 180
            }
        }
    }

    func makeColumns() -> [NSTableColumn] {
        Column.allCases.map { column in
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 160 : 44
            if let field = column.sortField {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
            }
            if column == .size { tableColumn.headerCell.alignment = .right }
            return tableColumn
        }
    }

    private func title(for column: Column) -> String {
        switch column {
        case .name: text.name
        case .date: text.dateAdded
        case .size: text.size
        case .kind: text.kind
        case .dimensions: text.dimensions
        case .tags: text.tags
        case .location: text.location
        }
    }

    // MARK: Updates

    func update(_ table: FileListTableView, appState: AppState) {
        self.appState = appState
        self.table = table
        claimFrameProvider()
        let folders = appState.isViewingTrash ? [] : appState.activeFolderEntries
        let token = ContentToken(revision: appState.activeAssetsRevision, folders: folders,
                                 showsLocation: appState.usesRecursiveResults, language: appState.appLanguage)
        if token != contentToken {
            let languageChanged = token.language != contentToken?.language
            contentToken = token
            rows = folders.map(FileListRow.folder) + appState.activeAssets.map(FileListRow.asset)
            rowByID = Dictionary(rows.enumerated().map { (id(of: $1), $0) }, uniquingKeysWith: { first, _ in first })
            for tableColumn in table.tableColumns {
                guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
                if languageChanged || tableColumn.title.isEmpty { tableColumn.title = title(for: column) }
                if column == .location, tableColumn.isHidden == token.showsLocation {
                    tableColumn.isHidden = !token.showsLocation
                    table.sizeToFit()
                }
            }
            isSyncing = true
            table.reloadData()
            isSyncing = false
        }
        syncSort(table)
        syncSelection(table)
        revealFocus(table)
    }

    /// The grid hands its frame provider back when it goes away, which can
    /// come after the list appears; take it whenever it is free.
    private func claimFrameProvider() {
        guard appState.previewSpaceAssetFrameProvider == nil else { return }
        appState.setPreviewSpaceAssetFrameProvider(cornerRadius: FileListMetrics.thumbnailRadius) { [weak self] in
            self?.previewFrames() ?? [:]
        }
        providesFrames = true
    }

    func releaseFrameProvider() {
        guard providesFrames else { return }
        providesFrames = false
        appState.setPreviewSpaceAssetFrameProvider(nil)
    }

    /// The row thumbnails on screen, in the preview's space (the window's
    /// content, top-left origin), at the image's proportions as drawn: the
    /// preview zooms out of and back into them.
    func previewFrames() -> [LightboxAsset.ID: CGRect] {
        guard let table, let content = table.window?.contentView else { return [:] }
        let nameColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        guard nameColumn >= 0 else { return [:] }
        let visible = table.rows(in: table.visibleRect)
        var frames: [LightboxAsset.ID: CGRect] = [:]
        for row in visible.location..<NSMaxRange(visible) where rows.indices.contains(row) {
            guard let asset = rows[row].asset else { continue }
            let cell = table.frameOfCell(atColumn: nameColumn, row: row)
            let iconBounds = NSRect(x: cell.minX + FileListMetrics.nameTitleInset,
                                    y: cell.midY - FileListMetrics.iconSize / 2,
                                    width: FileListMetrics.iconSize, height: FileListMetrics.iconSize)
            let icon = FileListMetrics.thumbnailRect(for: CGSize(width: asset.width, height: asset.height), in: iconBounds)
            var frame = content.convert(icon, from: table)
            if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            frames[asset.id] = frame
        }
        return frames
    }

    private func id(of row: FileListRow) -> String {
        switch row {
        case .folder(let folder): "folder:\(folder.id)"
        case .asset(let asset): asset.id
        }
    }

    private func syncSort(_ table: NSTableView) {
        let key = appState.sortField.rawValue
        let ascending = appState.sortDirection == .ascending
        guard table.sortDescriptors.first?.key != key || table.sortDescriptors.first?.ascending != ascending else { return }
        isSyncing = true
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        isSyncing = false
    }

    private func syncSelection(_ table: NSTableView) {
        var wanted = IndexSet()
        if !appState.selectedAssetIDs.isEmpty {
            for id in appState.selectedAssetIDs { if let row = rowByID[id] { wanted.insert(row) } }
        } else if let id = appState.selectedAssetID, let row = rowByID[id] {
            wanted.insert(row)
        }
        if let folderID = appState.selectedGalleryFolderID, let row = rowByID["folder:\(folderID)"] {
            wanted.insert(row)
        }
        guard table.selectedRowIndexes != wanted else { return }
        isSyncing = true
        table.selectRowIndexes(wanted, byExtendingSelection: false)
        isSyncing = false
    }

    /// Follows the gallery focus (a preview step, Quick Look's arrows) and
    /// takes the keyboard back when a preview closes.
    private func revealFocus(_ table: NSTableView) {
        if appState.galleryKeyboardScrollGeneration != lastScrollGeneration {
            lastScrollGeneration = appState.galleryKeyboardScrollGeneration
            if let id = appState.galleryKeyboardFocusID, let row = rowByID[id] { table.scrollRowToVisible(row) }
        }
        let hasOverlay = appState.hasActiveOverlay
        if hadOverlay, !hasOverlay, let window = table.window, window.firstResponder !== table {
            window.makeFirstResponder(table)
        }
        hadOverlay = hasOverlay
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              rows.indices.contains(row) else { return nil }
        let item = rows[row]
        if column == .name {
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileListNameCell
                ?? FileListNameCell(identifier: tableColumn.identifier)
            cell.configure(item)
            return cell
        }
        if column == .tags {
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileListTagsCell
                ?? FileListTagsCell(identifier: tableColumn.identifier)
            cell.tags = item.asset?.tags ?? {
                if case .folder(let folder) = item { return folder.tags }
                return []
            }()
            return cell
        }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileListTextCell
            ?? FileListTextCell(identifier: tableColumn.identifier, alignment: column == .size ? .right : .left)
        cell.setText(value(for: column, of: item), toolTip: toolTip(for: column, of: item))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: FileListRowView.identifier, owner: nil) as? FileListRowView ?? FileListRowView()
    }

    /// Numeric, so the day survives the column's default width
    /// ("2026/10/17 10:22"); the cell's tooltip spells the date out.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMdjmm")
        return formatter
    }()
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
    private static var kindByExtension: [String: String] = [:]

    private func value(for column: Column, of row: FileListRow) -> String? {
        switch (column, row) {
        case (.date, .asset(let asset)):
            return asset.addedAt == .distantPast ? nil : Self.dateFormatter.string(from: asset.addedAt)
        case (.size, .asset(let asset)):
            return asset.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        case (.kind, .folder):
            return text.folder
        case (.kind, .asset(let asset)):
            let ext = FileRenamer.split(asset.originalName).ext.lowercased()
            if let kind = Self.kindByExtension[ext] { return kind }
            let kind = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
            Self.kindByExtension[ext] = kind
            return kind
        case (.dimensions, .asset(let asset)):
            guard asset.isImage, asset.metadataLoaded, asset.width > 1, asset.height > 1 else { return nil }
            return "\(Int(asset.width)) × \(Int(asset.height))"
        case (.location, .asset(let asset)):
            guard let parent = asset.sourceURL?.deletingLastPathComponent() else { return nil }
            let relative = parent.relativePath(from: appState.currentFolderURL)
            return relative.isEmpty || relative == "." ? nil : relative
        case (.location, .folder(let folder)):
            let relative = folder.url.deletingLastPathComponent().relativePath(from: appState.currentFolderURL)
            return relative.isEmpty || relative == "." ? nil : relative
        default:
            return nil
        }
    }

    private func toolTip(for column: Column, of row: FileListRow) -> String? {
        guard column == .date, let asset = row.asset, asset.addedAt != .distantPast else { return nil }
        return Self.fullDateFormatter.string(from: asset.addedAt)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == Column.name.rawValue, rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .folder(let folder): return folder.name
        case .asset(let asset): return asset.originalName
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let field = GallerySortField(rawValue: key) else { return }
        if field != appState.sortField { appState.setSortField(field) }
        if (appState.sortDirection == .ascending) != descriptor.ascending { appState.toggleSortDirection() }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let table = notification.object as? NSTableView else { return }
        let selected = table.selectedRowIndexes.filter { rows.indices.contains($0) }
        let assets = selected.compactMap { rows[$0].asset }
        guard !assets.isEmpty else {
            if let row = selected.first, case .folder(let folder) = rows[row] {
                appState.selectGalleryFolder(folder.id)
            } else {
                appState.clearSelection()
            }
            return
        }
        let primaryRow = selected.contains(table.selectedRow) ? table.selectedRow : (selected.first ?? 0)
        let primary = rows[primaryRow].asset?.id ?? assets[0].id
        appState.replaceSelection(with: Set(assets.map(\.id)), primary: primary, anchor: primary)
        appState.galleryKeyboardFocusID = primary
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        activate(row: sender.clickedRow)
    }

    /// Return or a double click: open a folder, preview an image, open a file.
    func activate(row: Int) {
        guard rows.indices.contains(row), !appState.hasActiveOverlay else { return }
        claimFrameProvider()
        switch rows[row] {
        case .folder(let folder):
            // The keys held now: the double click may have been handled after another event.
            if NSEvent.modifierFlags.contains(.command) {
                appState.openFolderInNewTab(folder)
            } else {
                appState.openFolder(folder)
            }
        case .asset(let asset):
            if asset.isImage {
                appState.showPreview(for: asset, sourceFrame: appState.previewSpaceFrame(for: asset.id))
            } else {
                appState.openInDefaultApplication(asset)
            }
        }
    }

    func space(in table: NSTableView) {
        guard rows.indices.contains(table.selectedRow), !appState.hasActiveOverlay else { return }
        claimFrameProvider()
        switch rows[table.selectedRow] {
        case .asset(let asset):
            appState.handleSpace(on: asset)
        case .folder(let folder):
            if appState.quickLook.isVisible { appState.quickLook.close() } else { appState.quickLook.show([folder.url]) }
        }
    }

    func copySelection(in table: NSTableView) {
        guard rows.indices.contains(table.selectedRow), let asset = rows[table.selectedRow].asset else { return }
        appState.copyToClipboard(asset)
    }

    func menu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let titles = AssetContextMenuTitles(appState: appState)
        switch rows[row] {
        case .folder(let folder):
            menu.addItem(ClosureMenuItem(text.open) { [weak self] in self?.appState.openFolder(folder) })
            menu.addItem(ClosureMenuItem(appState.localized(.openInNewTab)) { [weak self] in self?.appState.openFolderInNewTab(folder) })
            if appState.canRenameFolder(folder) {
                menu.addItem(ClosureMenuItem(titles.rename) { [weak self] in self?.appState.beginRename(folder) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(titles.showInFinder) { [weak self] in self?.appState.revealFolderInFinder(folder) })
        case .asset(let asset):
            menu.addItem(ClosureMenuItem(text.open) { [weak self] in self?.activate(row: row) })
            menu.addItem(ClosureMenuItem(titles.quickLook) { [weak self] in
                guard let self else { return }
                self.appState.showQuickLook(self.appState.operationTargetAssets(fallback: asset))
            })
            if !asset.isDeleted {
                menu.addItem(ClosureMenuItem(titles.rename) { [weak self] in self?.appState.beginRename(fallback: asset) })
            }
            menu.addItem(ClosureMenuItem(titles.copy) { [weak self] in self?.appState.copyToClipboard(asset) })
            menu.addItem(.separator())
            if asset.isDeleted {
                menu.addItem(ClosureMenuItem(titles.restore) { [weak self] in self?.appState.restore(asset) })
            } else {
                let compareTitle = appState.selectedAssetIDs.count > 1
                    ? appState.localized(.addSelectedToCompareTray) : appState.localized(.addToCompareTray)
                let compare = ClosureMenuItem(compareTitle) { [weak self] in self?.appState.addSelectedToCompareTray(fallback: asset) }
                compare.isEnabled = asset.isImage
                menu.addItem(compare)
            }
            menu.addItem(ClosureMenuItem(titles.showInFinder) { [weak self] in self?.appState.revealInFinder(asset) })
            if !asset.isDeleted {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(titles.moveToTrash) { [weak self] in self?.appState.deleteSelectedAssets() })
            }
        }
        return menu
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), let url = rows[row].asset?.sourceURL else { return nil }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.absoluteString, forType: .URL)
        item.setString("1", forType: LightboxPasteboardTypes.internalAssetDrag)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        LightboxDragState.beginAssetDrag(sourceURLs: rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].asset?.sourceURL : nil })
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        LightboxDragState.endAssetDrag()
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}

// MARK: - Header

/// A quiet header in the window's canvas: 11pt titles, no column dividers,
/// a hairline below like the top bar's; the sorted column's title darkens
/// with a small arrow right after it.
private final class FileListHeaderView: NSTableHeaderView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(LightboxColorTokens.canvas).setFill()
        bounds.fill()
        guard let tableView else { return }
        let sort = tableView.sortDescriptors.first
        for index in tableView.tableColumns.indices {
            let column = tableView.tableColumns[index]
            guard !column.isHidden else { continue }
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            let sorted = sort != nil && column.sortDescriptorPrototype?.key == sort?.key
            // The header rect spans the spacing between columns; the cells
            // sit inside it. Lay titles out on the cells' own bounds.
            let cell = rect.insetBy(dx: tableView.intercellSpacing.width / 2, dy: 0)
            drawTitle(column, in: cell, sortedAscending: sorted ? sort?.ascending : nil,
                      isName: index == 0 || column.identifier.rawValue == "name")
        }
        NSColor(LightboxColorTokens.border).withAlphaComponent(0.55).setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 0.7, width: bounds.width, height: 0.7).fill()
    }

    private func drawTitle(_ column: NSTableColumn, in rect: NSRect, sortedAscending: Bool?, isName: Bool) {
        let isSorted = sortedAscending != nil
        let color = NSColor(isSorted ? LightboxColorTokens.primaryText : LightboxColorTokens.secondaryText)
        let title = NSAttributedString(string: column.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color
        ])
        let arrow = sortedAscending.flatMap { ascending in
            NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))?
                .tinted(color)
        }
        let arrowWidth = arrow.map { $0.size.width + 4 } ?? 0
        let inset = isName ? FileListMetrics.nameTitleInset : FileListMetrics.titleInset
        let available = rect.width - inset * 2 - arrowWidth
        let titleWidth = min(title.size().width, max(0, available))
        let rightAligned = column.headerCell.alignment == .right
        // A right-aligned title ends where the numbers do; its arrow goes into
        // the spacing after the column.
        let x = rightAligned ? rect.maxX - inset - titleWidth : rect.minX + inset
        let titleRect = NSRect(x: x, y: rect.midY - title.size().height / 2, width: titleWidth, height: title.size().height)
        title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let arrow {
            arrow.draw(in: NSRect(x: titleRect.maxX + 4, y: rect.midY - arrow.size.height / 2,
                                  width: arrow.size.width, height: arrow.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

private extension NSImage {
    /// A template symbol filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

// MARK: - Cells

/// The graphite rounded selection of the sidebar rows, not the accent bar.
private final class FileListRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("FileListRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: FileListMetrics.selectionInset, dy: 1)
        NSColor(LightboxColorTokens.navigationSelection).setFill()
        NSBezierPath(roundedRect: rect, xRadius: FileListMetrics.selectionRadius, yRadius: FileListMetrics.selectionRadius).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// An image thumbnail drawn at its proportions with rounded corners on the
/// image itself (rounding the square view would leave a letterboxed photo's
/// corners square); Finder icons draw as they are.
private final class FileListThumbnailView: NSImageView {
    var roundsImage = false {
        didSet { if roundsImage != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard roundsImage, let image else { return super.draw(dirtyRect) }
        let rect = FileListMetrics.thumbnailRect(for: image.size, in: bounds)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: FileListMetrics.thumbnailRadius,
                     yRadius: FileListMetrics.thumbnailRadius).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class FileListNameCell: NSTableCellView {
    private let icon = FileListThumbnailView()
    private let label = NSTextField(labelWithString: "")
    private var request: ImageCacheRequest?
    private var representedURL: URL?
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(LightboxColorTokens.primaryText)
        label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: FileListMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: FileListMetrics.iconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: FileListRow) {
        request?.cancel()
        request = nil
        switch row {
        case .folder(let folder):
            representedURL = folder.url
            label.stringValue = folder.name
            icon.roundsImage = false
            icon.image = Self.folderIcon
        case .asset(let asset):
            representedURL = asset.sourceURL
            label.stringValue = asset.originalName
            icon.roundsImage = false
            icon.image = FileTileIcons.icon(forName: asset.originalName)
            guard asset.isImage, let url = asset.sourceURL else { return }
            // A small thumbnail: from memory at once, else decoded at low priority.
            if let cached = ImageCache.shared.bestCachedImage(for: url, quality: .thumbnailFast,
                                                               knownFileSignature: asset.fileContentSignature) {
                icon.roundsImage = true
                icon.image = cached
                return
            }
            request = ImageCache.shared.image(for: url, quality: .thumbnailFast,
                                              knownFileSignature: asset.fileContentSignature, priority: .low) { [weak self] image in
                guard let self, self.representedURL == url, let image else { return }
                self.icon.roundsImage = true
                self.icon.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
    }
}

private final class FileListTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Missing values show as a muted dash, as in Finder.
    func setText(_ value: String?, toolTip: String? = nil) {
        label.stringValue = value ?? "—"
        label.toolTip = toolTip
        label.textColor = NSColor(value == nil ? LightboxColorTokens.mutedText : LightboxColorTokens.secondaryText)
    }
}

/// Finder tag dots, overlapping slightly, as in Finder's list.
private final class FileListTagsCell: NSTableCellView {
    var tags: [String] = [] { didSet { if tags != oldValue { needsDisplay = true } } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let colors = MacColorTag.sort(tags).compactMap { name in MacColorTag.all.first { $0.name == name }?.nsColor }
        let diameter: CGFloat = 9
        for (index, color) in colors.prefix(5).enumerated() {
            let rect = NSRect(x: 4 + CGFloat(index) * 6, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor(LightboxColorTokens.canvas).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}
