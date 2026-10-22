import AppKit
import OSLog

/// The files a rename sheet is open for, in gallery order.
struct RenameRequest: Identifiable, Equatable {
    let id = UUID()
    var assets: [LightboxAsset]
}

/// The folder a rename sheet is open for.
struct FolderRenameRequest: Identifiable, Equatable {
    let id = UUID()
    var folder: LibraryFolderEntry
}

struct NewFolderRequest: Identifiable, Equatable {
    let id = UUID()
    var parent: URL
}

// Renaming files in place, one or many, and creating folders, with undo.
extension AppState {
    var renameText: RenameText { RenameText(appLanguage) }

    /// The selection, the focused file when nothing is selected, or the
    /// selected folder.
    var canRename: Bool {
        guard !hasActiveOverlay, !isViewingTrash, !isShowingStartPage else { return false }
        if !selectedAssetIDs.isEmpty { return true }
        if let asset = explicitlySelectedAsset { return !asset.isDeleted && asset.sourceURL != nil }
        return selectedGalleryFolder.map(canRenameFolder) ?? false
    }

    private var selectedGalleryFolder: LibraryFolderEntry? {
        guard let id = selectedGalleryFolderID else { return nil }
        return activeFolderEntries.first { $0.id == id }
    }

    /// Opens the rename sheet for `asset` (with the rest of the selection when
    /// it is part of one), or for the selection or focused file.
    func beginRename(fallback asset: LightboxAsset? = nil) {
        guard !hasActiveOverlay, !isViewingTrash else { return }
        let targets: [LightboxAsset]
        if let asset {
            targets = operationTargetAssets(fallback: asset)
        } else if !selectedAssetIDs.isEmpty {
            let selected = selectedAssetIDs
            targets = activeAssets.filter { selected.contains($0.id) }
        } else if let selected = explicitlySelectedAsset {
            targets = [selected]
        } else {
            if let folder = selectedGalleryFolder { beginRename(folder) }
            return
        }
        let renamable = targets.filter { !$0.isDeleted && $0.sourceURL != nil }
        guard !renamable.isEmpty else { return }
        renameRequest = RenameRequest(assets: renamable)
    }

    /// Renames `items`; `completion` gets nil once the gallery shows the new
    /// names, or why nothing was renamed.
    func rename(_ items: [FileRenameItem], completion: @escaping @MainActor (FileRenameIssue?) -> Void = { _ in }) {
        if let issue = FileRenamer.issue(in: items) {
            completion(issue)
            return
        }
        let changed = items.filter { $0.newName != $0.url.lastPathComponent }
        guard !changed.isEmpty else {
            completion(nil)
            return
        }
        enqueueRename(items: { changed }, includingSidecars: true, completion: completion)
    }

    private func enqueueRename(items: @escaping @MainActor () -> [FileRenameItem], includingSidecars: Bool,
                               completion: @escaping @MainActor (FileRenameIssue?) -> Void) {
        // 在 undo 回呼內立即登記反向步驟，實際路徑則等前一筆操作完成才讀取。
        let undo = registerFileUndo(actionName: renameText.undoAction) { state, step in
            state.enqueueRename(items: { FileRenamer.reversal(of: step.moves) }, includingSidecars: false) { issue in
                guard let issue else { return }
                state.fileOperationAlert = state.renameText.message(for: issue)
            }
        }
        renameUndoSteps.removeAll { $0.value == nil }
        renameUndoSteps.append(WeakFileUndoStep(value: undo))
        renameTask = enqueueFileOperation { [weak self] in
            let changed = items()
            let result = await Task.detached(priority: .userInitiated) {
                FileRenamer.perform(changed, includingSidecars: includingSidecars)
            }.value
            guard let self else { return }
            switch result {
            case .success(let moves):
                Self.logger.info("rename complete count=\(moves.count)")
                undo.finish(with: moves)
                self.applyRenameMoves(moves)
                completion(nil)
            case .failure(let issue):
                Self.logger.error("rename failed count=\(changed.count) issue=\(String(describing: issue), privacy: .public)")
                undo.cancel()
                completion(issue)
            }
        }
    }

    /// Shows renamed files under their new names in place, keeping the
    /// selection, focus and compare tray on them. The folder watcher's
    /// refresh then matches them by their new paths.
    func applyRenameMoves(_ moves: [FileRenameMove]) {
        guard !moves.isEmpty else { return }
        let targets = Dictionary(moves.map { (LightboxAsset.stableID(originalName: $0.from.lastPathComponent, sourceURL: $0.from), $0.to) },
                                 uniquingKeysWith: { first, _ in first })
        var newIDs: [LightboxAsset.ID: LightboxAsset.ID] = [:]
        func renamed(_ asset: LightboxAsset) -> LightboxAsset {
            guard let url = targets[asset.id] else { return asset }
            let next = asset.renamed(to: url)
            newIDs[asset.id] = next.id
            return next
        }
        searchResultAssets = searchResultAssets?.map(renamed)
        assets = assets.map(renamed)
        for item in compareTrayAssets where targets[item.id] != nil {
            compareTray.replace(item.id, with: renamed(item))
        }
        func mapped(_ id: LightboxAsset.ID?) -> LightboxAsset.ID? { id.map { newIDs[$0] ?? $0 } }
        selectedAssetIDs = Set(selectedAssetIDs.map { newIDs[$0] ?? $0 })
        selectedAssetID = mapped(selectedAssetID)
        selectionAnchorID = mapped(selectionAnchorID)
        if let focused = galleryKeyboardFocusID, let next = newIDs[focused] {
            galleryKeyboardFocusID = next
        }
        rebuildActiveAssets()
    }

    // MARK: Folders

    /// Not the library's own folder or one holding it: the library keeps its
    /// location in its settings.
    func canRenameFolder(_ folder: LibraryFolderEntry) -> Bool {
        let move = FolderRenameMove(from: folder.url, to: folder.url)
        return !(sources + [temporarySource].compactMap { $0 })
            .contains { $0.isLocalLibrary && move.moved($0.rootURL) != nil }
    }

    /// Opens the rename sheet for `folder`.
    func beginRename(_ folder: LibraryFolderEntry) {
        guard !hasActiveOverlay, !isViewingTrash, canRenameFolder(folder) else { return }
        folderRenameRequest = FolderRenameRequest(folder: folder)
    }

    /// Renames a folder in place; tabs, history, pinned folders and recent
    /// folders inside it follow. `completion` gets nil once the gallery shows
    /// the new name, or why nothing was renamed.
    func renameFolder(_ item: FileRenameItem, completion: @escaping @MainActor (FileRenameIssue?) -> Void = { _ in }) {
        if let issue = FileRenamer.issue(in: [item]) {
            completion(issue)
            return
        }
        guard item.newName != item.url.lastPathComponent else {
            completion(nil)
            return
        }
        let reversal = FileRenameItem(url: item.target, newName: item.url.lastPathComponent)
        let undo = registerFileUndo(actionName: renameText.undoAction) { state, _ in
            state.renameFolder(reversal) { issue in
                guard let issue else { return }
                state.fileOperationAlert = state.renameText.message(for: issue)
            }
        }

        renameTask = enqueueFileOperation { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { FileRenamer.perform([item]) }.value
            guard let self else { return }
            switch result {
            case .success(let moves):
                Self.logger.info("folder rename complete")
                undo.finish(with: moves)
                if let move = moves.first { self.applyFolderRename(FolderRenameMove(from: move.from, to: move.to)) }
                completion(nil)
            case .failure(let issue):
                Self.logger.error("folder rename failed issue=\(String(describing: issue), privacy: .public)")
                undo.cancel()
                completion(issue)
            }
        }
    }

    /// Points everything kept by path inside the folder at its new path. The
    /// folder on screen is never inside it: the renamed folder is listed in it.
    func applyFolderRename(_ move: FolderRenameMove) {
        // The folder's tile, selected under its new path.
        func movedEntry(_ entry: LibraryFolderEntry) -> LibraryFolderEntry {
            guard let url = move.moved(entry.url) else { return entry }
            var next = entry
            next.url = url
            return next
        }
        let selectedID = selectedGalleryFolderID
        let selectedEntry = (folderEntries + (searchResultFolderEntries ?? [])).first { $0.id == selectedID }
        folderEntries = folderEntries.map(movedEntry)
        searchResultFolderEntries = searchResultFolderEntries?.map(movedEntry)
        rebuildActiveFolderEntries()
        if let selectedEntry, move.moved(selectedEntry.url) != nil {
            selectedGalleryFolderID = movedEntry(selectedEntry).id
        }

        // Files shown from inside it (subfolders included, search results, the tray).
        let files = (assets + (searchResultAssets ?? []) + compareTrayAssets).compactMap { asset -> FileRenameMove? in
            guard let url = asset.sourceURL, let moved = move.moved(url) else { return nil }
            return FileRenameMove(from: url, to: moved)
        }
        applyRenameMoves(files)

        // Pinned folders.
        func movedSource(_ source: LibrarySource) -> LibrarySource {
            guard let root = move.moved(source.rootURL) else { return source }
            var next = source
            if source.name == LibrarySource.defaultExternalName(for: source.rootURL) {
                next.name = LibrarySource.defaultExternalName(for: root)
            }
            next.rootURL = root
            return next
        }
        let previousSources = sources
        let nextSources = previousSources.map(movedSource)
        if nextSources != previousSources {
            sources = nextSources
            LibrarySourceStore.saveExternalSources(sources, defaults: libraryDefaults)
            for (old, new) in zip(previousSources, nextSources) where old != new { sourceIndexWriter.upsertSource(new) }
        }
        if let temporarySource { self.temporarySource = movedSource(temporarySource) }

        // Tabs and their history.
        func movedLocation(_ location: LightboxTabLocation) -> LightboxTabLocation {
            var next = location
            next.source = movedSource(location.source)
            next.folderURL = move.moved(location.folderURL) ?? location.folderURL
            return next
        }
        let before = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabSession.updateAll { tab in
            tab.source = movedSource(tab.source)
            tab.folderURL = move.moved(tab.folderURL) ?? tab.folderURL
            tab.backHistory = tab.backHistory.map(movedLocation)
            tab.forwardHistory = tab.forwardHistory.map(movedLocation)
        }
        let movedTabs = Set(tabs.filter { before[$0.id] != $0 }.map(\.id))
        if !movedTabs.isEmpty {
            tabSession.forgetContent(of: movedTabs)
            tabSession.scheduleSave()
        }

        // Recent folders, and each folder's saved sort.
        let recents = recentFolderURLs.map { move.moved($0) ?? $0 }
        if recents != recentFolderURLs {
            recentFolderURLs = recents
            libraryDefaults.set(recentFolderURLs.map(\.path), forKey: "Lightbox.recentFolders")
        }
        let collapsed = collapsedGroupFolderPaths.map { move.moved(path: $0) ?? $0 }
        if collapsed != collapsedGroupFolderPaths { saveCollapsedGroupFolders(collapsed) }
        let sortPrefix = "Lightbox.folderSort.v1.folder:"
        for (key, value) in libraryDefaults.dictionaryRepresentation() where key.hasPrefix(sortPrefix) {
            guard let path = move.moved(path: String(key.dropFirst(sortPrefix.count))) else { continue }
            libraryDefaults.set(value, forKey: sortPrefix + path)
            libraryDefaults.removeObject(forKey: key)
        }
    }

    // MARK: New Folder

    var canCreateFolder: Bool {
        !hasActiveOverlay && !isViewingTrash && !isShowingStartPage && selectedSource != nil
    }

    /// Opens the New Folder sheet for the folder on screen.
    func beginNewFolder() {
        guard canCreateFolder else { return }
        newFolderRequest = NewFolderRequest(parent: currentFolderURL)
    }

    /// Creates `name` in `parent`; `completion` gets nil once the folder
    /// shows (selected) in the gallery, or why it was not created.
    func createFolder(named name: String, in parent: URL,
                      completion: @escaping @MainActor (FileRenameIssue?) -> Void = { _ in }) {
        if let issue = FileRenamer.issue(inName: name) {
            completion(issue)
            return
        }
        let url = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let undo = registerFileUndo(actionName: renameText.newFolderUndo) { state, _ in state.removeCreatedFolder(url) }

        renameTask = enqueueFileOperation { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { FileRenamer.createFolder(named: name, in: parent) }.value
            guard let self else { return }
            switch result {
            case .success(let created):
                Self.logger.info("folder created path=\(created.path, privacy: .public)")
                undo.finish(with: [FileRenameMove(from: parent, to: created)])
                self.showCreatedFolder(created)
                completion(nil)
            case .failure(let issue):
                Self.logger.error("folder create failed issue=\(String(describing: issue), privacy: .public)")
                undo.cancel()
                completion(issue)
            }
        }
    }

    /// The undo of New Folder: removes the folder while it is still empty.
    private func removeCreatedFolder(_ url: URL) {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        let redo = registerFileUndo(actionName: renameText.newFolderUndo) { state, _ in
            state.createFolder(named: name, in: parent) { issue in
                guard let issue else { return }
                state.fileOperationAlert = state.renameText.message(for: issue)
            }
        }

        renameTask = enqueueFileOperation { [weak self] in
            let removed = await Task.detached(priority: .userInitiated) { FileRenamer.removeEmptyFolder(url) }.value
            guard let self else { return }
            guard removed else {
                redo.cancel()
                self.fileOperationAlert = self.renameText.folderNotEmpty(name)
                return
            }
            redo.finish(with: [FileRenameMove(from: parent, to: url)])
            let path = url.standardizedFileURL.path
            self.folderEntries.removeAll { $0.url.standardizedFileURL.path == path }
            if self.selectedGalleryFolderID?.hasSuffix(":\(path)") == true { self.selectedGalleryFolderID = nil }
            self.rebuildActiveFolderEntries()
        }
    }

    /// Lists a new folder at once, selected, when it is in the folder on
    /// screen; the folder watcher's refresh then finds it already there.
    private func showCreatedFolder(_ url: URL) {
        guard let source = selectedSource,
              url.deletingLastPathComponent().standardizedFileURL.path == currentFolderURL.standardizedFileURL.path
        else { return }
        let entry = LibraryFolderEntry(sourceID: source.id, url: url, rootURL: source.rootURL.standardizedFileURL)
        if !folderEntries.contains(where: { $0.id == entry.id }) {
            folderEntries.append(entry)
        }
        rebuildActiveFolderEntries()
        selectGalleryFolder(entry.id)
    }
}
