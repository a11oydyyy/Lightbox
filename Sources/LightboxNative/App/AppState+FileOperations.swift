import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Trash, restore, Finder tags, opening, revealing and sharing files.
extension AppState {
    func markDeleted(_ asset: LightboxAsset) {
        let targetAssets: [LightboxAsset]
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            let selectedIDs = selectedAssetIDs
            targetAssets = activeAssets.filter { selectedIDs.contains($0.id) }
        } else {
            targetAssets = [asset]
        }

        moveAssetsToSystemTrash(targetAssets)
    }

    func deleteSelectedAssets() {
        let targetAssets: [LightboxAsset]
        if !selectedAssetIDs.isEmpty {
            let selectedIDs = selectedAssetIDs
            targetAssets = activeAssets.filter { selectedIDs.contains($0.id) }
        } else if let asset = explicitlySelectedAsset {
            targetAssets = [asset]
        } else {
            return
        }

        moveAssetsToSystemTrash(targetAssets)
    }

    func moveAssetsToSystemTrash(_ targetAssets: [LightboxAsset]) {
        let validAssets = targetAssets.filter { !$0.isDeleted && $0.sourceURL != nil && !trashMovingAssetIDs.contains($0.id) }
        guard !validAssets.isEmpty else { return }
        trashMovingAssetIDs.formUnion(validAssets.map(\.id))
        let urls = validAssets.compactMap(\.sourceURL)
        let identifiers = Dictionary(validAssets.compactMap { asset in
            asset.sourceURL.map { ($0.standardizedFileURL.path, asset.id) }
        }, uniquingKeysWith: { first, _ in first })
        startTrashMove(urls: { urls }, undo: registerTrashUndo(restoring: true), includingSidecars: true, identifiers: identifiers)
    }

    private func startTrashMove(urls: @escaping @MainActor () -> [URL], undo: FileUndoStep, includingSidecars: Bool,
                                identifiers: [String: LightboxAsset.ID] = [:]) {
        let previewOrder = activeAssets.map(\.id)
        let previewSession = previewSessionID
        let trashMover = systemTrashMover
        pendingTrashOperations += 1
        trashMoveTask = enqueueFileOperation { [weak self] in
            let targets = urls()
            var knownIDs = Dictionary((self?.assets ?? []).compactMap { asset in
                asset.sourceURL.map { ($0.standardizedFileURL.path, asset.id) }
            }, uniquingKeysWith: { first, _ in first })
            knownIDs.merge(identifiers, uniquingKeysWith: { _, requested in requested })
            func assetID(for url: URL) -> LightboxAsset.ID {
                knownIDs[url.standardizedFileURL.path] ?? LightboxAsset.stableID(originalName: url.lastPathComponent, sourceURL: url)
            }
            let targetIDs = Set(targets.map { assetID(for: $0) })
            self?.trashMovingAssetIDs.formUnion(targetIDs)
            let moves = await Task.detached(priority: .userInitiated) {
                var moves: [FileRenameMove] = []
                var trashedPaths = Set<String>()
                for target in targets {
                    guard !Task.isCancelled else { break }
                    guard !trashedPaths.contains(target.standardizedFileURL.path) else { continue }
                    let sidecars = includingSidecars ? RawSidecar.existing(for: target) : []
                    if let trashed = trashMover(target) {
                        moves.append(FileRenameMove(from: target, to: trashed))
                        trashedPaths.insert(target.standardizedFileURL.path)
                        for sidecar in sidecars where !trashedPaths.contains(sidecar.standardizedFileURL.path) {
                            if let trashedSidecar = trashMover(sidecar) {
                                moves.append(FileRenameMove(from: sidecar, to: trashedSidecar))
                                trashedPaths.insert(sidecar.standardizedFileURL.path)
                            }
                        }
                    } else {
                        Self.logger.error("system trash failed path=\(target.path, privacy: .public)")
                    }
                }
                return moves
            }.value
            undo.finish(with: moves)
            guard let self else { return }
            let removedIDs = Set(moves.map { assetID(for: $0.from) })
            self.applySystemTrashSuccesses(removedIDs, previewOrder: previewOrder, previewSession: previewSession)
            self.trashMovingAssetIDs.subtract(targetIDs)
            self.finishTrashOperation()
        }
    }

    private func finishTrashOperation() {
        pendingTrashOperations -= 1
        if pendingTrashOperations == 0 { trashMoveTask = nil }
    }

    private func applySystemTrashSuccesses(_ removedIDs: Set<LightboxAsset.ID>, previewOrder: [LightboxAsset.ID], previewSession: UUID) {
        guard !removedIDs.isEmpty else { return }

        var continuation: (asset: LightboxAsset, direction: PreviewDirection)?
        if let currentID = previewAssetID, removedIDs.contains(currentID),
           previewPhase == .opening || previewPhase == .open {
            let order = previewSessionID == previewSession ? previewOrder : activeAssets.map(\.id)
            let remainingIDs = Set(activeAssets.map(\.id)).subtracting(removedIDs)
            if let index = order.firstIndex(of: currentID) {
                let following = order.dropFirst(index + 1).first { remainingIDs.contains($0) }
                let preceding = order.prefix(index).last { remainingIDs.contains($0) }
                let pending = pendingPreviewStepAssetID.flatMap { remainingIDs.contains($0) ? $0 : nil }
                if let nextID = pending ?? following ?? preceding,
                   let next = activeAssets.first(where: { $0.id == nextID }) {
                    let direction: PreviewDirection = (order.firstIndex(of: nextID) ?? index) < index ? .previous : .next
                    continuation = (next, direction)
                    cancelPreviewDimensionResolution(clearPendingStep: true)
                    pendingPreviewStepAssetID = next.id
                    // Keep the overlay in its current session before gallery observers run.
                    presentPreviewStep(next, direction: direction)
                }
            }
        }

        // Update both sources before the assets observer rebuilds the gallery and its ID caches.
        searchResultAssets?.removeAll { removedIDs.contains($0.id) }
        assets.removeAll { removedIDs.contains($0.id) }
        selectedAssetIDs.subtract(removedIDs)
        if let selectedAssetID, removedIDs.contains(selectedAssetID) {
            self.selectedAssetID = firstVisibleID(in: selectedAssetIDs)
        }
        if let selectionAnchorID, removedIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }
        if selectedAssetIDs.isEmpty {
            selectionAnchorID = nil
        }
        if let previewAssetID, removedIDs.contains(previewAssetID) {
            closePreview()
        }
        for assetID in removedIDs {
            removeFromCompareTray(assetID)
        }
        rebuildActiveAssets()
        if let continuation, previewAssetID == continuation.asset.id {
            pendingPreviewStepAssetID = continuation.asset.id
            resolvePreviewTarget(continuation.asset, sourceFrame: nil, requiresActiveAsset: true) { [weak self] resolved in
                self?.presentPreviewStep(resolved, direction: continuation.direction)
            }
        }
    }

    func restore(_ asset: LightboxAsset) {
        guard let sourceURL = asset.sourceURL,
              LightboxLibraryStore.isSystemTrashURL(sourceURL)
        else {
            return
        }

        let assetID = asset.id
        let restorer = systemTrashRestorer
        Task { [weak self] in
            let restored = await restorer(sourceURL)
            guard let self else { return }

            guard restored.succeeded else {
                Self.logger.error("system trash restore failed id=\(assetID, privacy: .public) path=\(sourceURL.path, privacy: .public)")
                return
            }

            finishRestore(assetID)
        }
    }

    private func finishRestore(_ assetID: LightboxAsset.ID) {
        assets.removeAll { $0.id == assetID }
        selectedAssetIDs.remove(assetID)
        if selectedAssetID == assetID {
            selectedAssetID = firstVisibleID(in: selectedAssetIDs)
        }
        if selectionAnchorID == assetID {
            selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }
        removeFromCompareTray(assetID)
        scheduleLibraryRefresh()
    }

    func applyTag(_ tag: String, to asset: LightboxAsset) {
        guard MacColorTag.isColorTag(tag) else { return }
        enqueueTagMutation(TagMutationRequest(tag: tag, assets: [asset], action: .add))
    }

    func toggleTag(_ tag: String, to asset: LightboxAsset) {
        guard MacColorTag.isColorTag(tag) else { return }
        let targetIDs: Set<LightboxAsset.ID>
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            targetIDs = selectedAssetIDs
        } else {
            targetIDs = [asset.id]
        }
        let targetAssets = activeAssets.filter { targetIDs.contains($0.id) }
        guard !targetAssets.isEmpty else { return }
        enqueueTagMutation(TagMutationRequest(tag: tag, assets: targetAssets, action: .toggle))
    }

    func selectedAssetTagCoverage(for tag: String) -> Double {
        guard MacColorTag.isColorTag(tag), !selectedAssetIDs.isEmpty else { return 0 }
        let selectedAssets = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        guard !selectedAssets.isEmpty else { return 0 }
        let taggedCount = selectedAssets.filter { $0.tags.contains(tag) }.count
        return Double(taggedCount) / Double(selectedAssets.count)
    }

    func toggleTagForSelection(_ tag: String) {
        guard MacColorTag.isColorTag(tag), !selectedAssetIDs.isEmpty else { return }
        let targetIDs = selectedAssetIDs
        let selectedAssets = activeAssets.filter { targetIDs.contains($0.id) }
        guard !selectedAssets.isEmpty else { return }

        enqueueTagMutation(TagMutationRequest(tag: tag, assets: selectedAssets, action: .toggle))
    }

    func enqueueTagMutation(_ request: TagMutationRequest) {
        var request = request
        request.originTabID = activeTabID
        request.originFilter = selectedFilter
        request.originVisibleAssetIDs = Set(activeAssets.map(\.id))
        request.originFolderPath = currentFolderURL.standardizedFileURL.path
        request.originSearchText = searchText
        queuedTagMutations.append(request)
        guard tagMutationTask == nil else { return }

        tagMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.queuedTagMutations.isEmpty {
                let request = self.queuedTagMutations.removeFirst()
                let targetAssets = request.assets.map { asset in
                    self.assetForCurrentPresentation(asset.id) ?? asset
                }
                let targetIDs = Set(targetAssets.map(\.id))
                let writer = self.finderTagWriter
                let action = request.action
                let tag = request.tag
                let mutation = await Task.detached(priority: .userInitiated) {
                    () -> (removesTag: Bool, tagsByID: [LightboxAsset.ID: [String]], previousByID: [LightboxAsset.ID: [String]]) in
                    // Gallery tags may be deferred or stale. Read all targets before
                    // deciding a group toggle; abort if any target cannot be read.
                    let writes: [TagMutationWrite]
                    do {
                        writes = try targetAssets.map { asset in
                            TagMutationWrite(
                                id: asset.id,
                                url: asset.sourceURL,
                                tags: try asset.sourceURL.map { try FinderTagStore.readColorTags(for: $0) }
                                    ?? asset.tags
                            )
                        }
                    } catch {
                        return (false, [:], [:])
                    }
                    let removesTag = action == .toggle
                        && writes.allSatisfy { $0.tags.contains(tag) }
                    var result: [LightboxAsset.ID: [String]] = [:]
                    var previous: [LightboxAsset.ID: [String]] = [:]
                    for write in writes {
                        guard !Task.isCancelled else { break }
                        var nextTags = write.tags
                        switch action {
                        case .add, .toggle:
                            if removesTag {
                                nextTags.removeAll { $0 == tag }
                            } else if !nextTags.contains(tag) {
                                nextTags.append(tag)
                            }
                        case .cull(let mark):
                            nextTags = mark.applied(to: nextTags)
                        case .restore(let tagsByID):
                            nextTags = tagsByID[write.id] ?? nextTags
                        }
                        nextTags = MacColorTag.sort(nextTags.filter(MacColorTag.isColorTag))
                        if let url = write.url, !writer(nextTags, url) { continue }
                        result[write.id] = nextTags
                        previous[write.id] = write.tags
                    }
                    return (removesTag, result, previous)
                }.value
                request.undoStep?.finish(assets: targetAssets, previousTags: mutation.previousByID)
                let updatedTagsByID = mutation.tagsByID
                let shouldClearCurrentFilter = mutation.removesTag
                    && request.originFilter == .tag(request.tag)
                    && !request.originVisibleAssetIDs.isEmpty
                    && request.originVisibleAssetIDs.allSatisfy { targetIDs.contains($0) }
                guard !Task.isCancelled else { break }

                self.applyTagCopies(updatedTagsByID)
                self.clearCurrentTagFilterIfNeeded(
                    shouldClearCurrentFilter,
                    removedTag: request.tag,
                    targetAssets: targetAssets,
                    updatedTagsByID: updatedTagsByID,
                    originTabID: request.originTabID,
                    originFolderPath: request.originFolderPath,
                    originSearchText: request.originSearchText
                )
            }
            self.tagMutationTask = nil
        }
    }

    func revealInFinder(_ asset: LightboxAsset) {
        guard let url = asset.sourceURL else { return }
        revealURLInFinder(url)
    }

    /// Opens a file in its default application, as Finder does on a double click.
    func openInDefaultApplication(_ asset: LightboxAsset) {
        guard let url = asset.sourceURL else { return }
        withExistingFileURLs([url]) { state, existing in state.defaultApplicationOpener(existing) }
    }

    func openWithApplication(_ asset: LightboxAsset, applicationURL: URL?) {
        let targets = operationTargetAssets(fallback: asset)
        let urls = targets.compactMap(\.sourceURL)
        guard !urls.isEmpty else { return }

        if let applicationURL {
            withExistingFileURLs(urls) { state, existing in state.open(existing, with: applicationURL) }
            return
        }

        let panel = NSOpenPanel()
        panel.title = localized(.openWith)
        panel.prompt = localized(.openWith).replacingOccurrences(of: "...", with: "")
        panel.message = urls.count == 1 ? asset.originalName : selectedCountText(urls.count)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK,
              let applicationURL = panel.url
        else { return }

        withExistingFileURLs(urls) { state, existing in state.open(existing, with: applicationURL) }
    }

    func operationTargetAssets(fallback asset: LightboxAsset) -> [LightboxAsset] {
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            let selectedIDs = selectedAssetIDs
            return activeAssets.filter { selectedIDs.contains($0.id) }
        }

        return [asset]
    }

    private func withExistingFileURLs(_ urls: [URL], action: @escaping @MainActor (AppState, [URL]) -> Void) {
        fileActionTask?.cancel()
        fileActionTask = Task { [weak self] in
            guard let existing = try? await FileActionResolver.existingURLs(urls),
                  !Task.isCancelled, let self else { return }
            self.fileActionTask = nil
            guard !existing.isEmpty else { return }
            action(self, existing)
        }
    }

    private func open(_ urls: [URL], with applicationURL: URL) {
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if let error {
                Self.logger.error("open-with failed app=\(applicationURL.path, privacy: .public) count=\(urls.count) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func revealURLInFinder(_ url: URL) {
        // Finder resolves missing or disconnected targets itself. A preflight
        // stat on a removable/network volume could stall the main actor.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToClipboard(_ asset: LightboxAsset) {
        let urls = operationTargetAssets(fallback: asset).compactMap(\.sourceURL)
        withExistingFileURLs(urls) { _, existing in ImageClipboardWriter.copyImages(at: existing) }
    }

    func share(_ asset: LightboxAsset, from view: NSView) {
        let urls = operationTargetAssets(fallback: asset).compactMap(\.sourceURL)
        withExistingFileURLs(urls) { [weak view] state, existing in
            guard let view, view.window != nil else { return }
            let picker = NSSharingServicePicker(items: existing)
            state.sharingPicker = picker
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private func clearCurrentTagFilterIfNeeded(
        _ shouldClear: Bool,
        removedTag tag: String,
        targetAssets: [LightboxAsset],
        updatedTagsByID: [LightboxAsset.ID: [String]],
        originTabID: UUID?,
        originFolderPath: String?,
        originSearchText: String?
    ) {
        guard shouldClear,
              !targetAssets.isEmpty,
              targetAssets.allSatisfy({ updatedTagsByID[$0.id]?.contains(tag) == false })
        else {
            return
        }

        guard let originTabID else { return }
        if originTabID == activeTabID {
            guard selectedFilter == .tag(tag),
                  currentFolderURL.standardizedFileURL.path == originFolderPath,
                  searchText == originSearchText
            else {
                return
            }
            selectedFilter = .all
            return
        }

        guard let tab = tabSession.tab(originTabID),
              tab.filter == .tag(tag),
              tab.folderURL.standardizedFileURL.path == originFolderPath,
              tab.searchText == originSearchText
        else {
            return
        }
        tabSession.update(originTabID) {
            $0.filter = .all
            $0.selectedAssetIDs = []
            $0.selectedAssetID = nil
        }
        scheduleTabPersistence()
    }

    private func update(_ asset: LightboxAsset, body: (inout LightboxAsset) -> Void) {
        var didUpdate = false
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            body(&assets[index])
            didUpdate = true
        }
        if var searchResultAssets,
           let index = searchResultAssets.firstIndex(where: { $0.id == asset.id }) {
            body(&searchResultAssets[index])
            self.searchResultAssets = searchResultAssets
            didUpdate = true
        }
        if let index = cachedActiveAssets.firstIndex(where: { $0.id == asset.id }) {
            body(&cachedActiveAssets[index])
            didUpdate = true
        }
        if var snapshot = previewAssetSnapshot, snapshot.id == asset.id {
            body(&snapshot)
            previewAssetSnapshot = snapshot
            didUpdate = true
        }
        if didUpdate {
            rebuildActiveAssets()
        }
    }

    private func applyTagCopies(_ tagsByID: [LightboxAsset.ID: [String]]) {
        guard !tagsByID.isEmpty else { return }

        var nextAssets = assets
        var changedAssets = false
        for index in nextAssets.indices {
            guard let tags = tagsByID[nextAssets[index].id] else { continue }
            nextAssets[index].tags = tags
            changedAssets = true
        }
        if changedAssets {
            assets = nextAssets
        }

        if var searchResultAssets {
            var changedSearchResults = false
            for index in searchResultAssets.indices {
                guard let tags = tagsByID[searchResultAssets[index].id] else { continue }
                searchResultAssets[index].tags = tags
                changedSearchResults = true
            }
            if changedSearchResults {
                self.searchResultAssets = searchResultAssets
            }
        }

        if let previewAssetSnapshot,
           let tags = tagsByID[previewAssetSnapshot.id] {
            self.previewAssetSnapshot?.tags = tags
        }

        rebuildActiveAssets()
    }
}

/// One undoable file operation. It is the undo target, so a failed operation
/// can drop its own step without clearing the rest of the history.
@MainActor
final class FileUndoStep {
    fileprivate weak var undoManager: UndoManager?
    private(set) var moves: [FileRenameMove] = []

    /// The operation's outcome: what the undo puts back. Nothing done means
    /// nothing to undo.
    func finish(with moves: [FileRenameMove]) {
        self.moves = moves
        if moves.isEmpty { cancel() }
    }

    func cancel() {
        undoManager?.removeAllActions(withTarget: self)
    }

    func retargetDestination(from original: URL, to destination: URL) {
        for index in moves.indices where moves[index].to.standardizedFileURL == original.standardizedFileURL {
            moves[index].to = destination
        }
    }
}

@MainActor
struct WeakFileUndoStep {
    weak var value: FileUndoStep?
}

// Undo for file operations: registered when an operation starts (during an
// undo that puts it on the redo stack), finished when it completes.
extension AppState {
    func registerFileUndo(actionName: String,
                          perform: @escaping @MainActor (AppState, FileUndoStep) -> Void) -> FileUndoStep {
        let step = FileUndoStep()
        guard let undoManager = renameUndoManager() else { return step }
        step.undoManager = undoManager
        // The undo manager does not retain its targets; the handler holds the step.
        undoManager.registerUndo(withTarget: step) { [weak self, step] _ in
            guard let self else { return }
            perform(self, step)
        }
        undoManager.setActionName(actionName)
        return step
    }

    /// 檔案變更與反向操作共用順序，避免連按復原時讀到未完成的結果。
    func enqueueFileOperation(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = fileOperationTask
        let task = Task {
            await previous?.value
            await operation()
        }
        fileOperationTask = task
        return task
    }

    private func registerTrashUndo(restoring: Bool) -> FileUndoStep {
        registerFileUndo(actionName: localized(.moveToTrash)) { state, step in
            let inverse = state.registerTrashUndo(restoring: !restoring)
            if restoring {
                state.putBackFromTrash(step, redo: inverse)
            } else {
                // 只重做成功復原的實際路徑，不重新猜測旁檔或原始名稱。
                state.startTrashMove(urls: { step.moves.map(\.from) }, undo: inverse, includingSidecars: false)
            }
        }
    }

    private func putBackFromTrash(_ step: FileUndoStep, redo: FileUndoStep) {
        let restorer = systemTrashRestorer
        pendingTrashOperations += 1
        trashMoveTask = enqueueFileOperation { [weak self] in
            var restored: [FileRenameMove] = []
            var failed: [String] = []
            for move in step.moves {
                switch await restorer(move.to) {
                case .restored(let destination):
                    // 若碰撞改名，先前的重新命名步驟也必須跟著真正復原的檔案。
                    if destination.standardizedFileURL != move.from.standardizedFileURL {
                        self?.renameUndoSteps.forEach { $0.value?.retargetDestination(from: move.from, to: destination) }
                    }
                    restored.append(FileRenameMove(from: destination, to: move.to))
                case .restoredByFinder:
                    // Finder 沒有回傳目的路徑；不可用舊路徑重做，避免動到別的檔案。
                    break
                case .failed:
                    failed.append(move.from.lastPathComponent)
                }
            }
            redo.finish(with: restored)
            guard let self else { return }
            if let name = failed.first {
                self.fileOperationAlert = self.renameText.putBackFailed(name)
            }
            self.refreshLibrary(preservingVisibleSnapshot: true)
            self.finishTrashOperation()
        }
    }
}
