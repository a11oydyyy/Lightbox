import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Dragging images out, dropping files in, and copy/move transfers.
extension AppState {
    func dragSourceURLs(for asset: LightboxAsset) -> [URL] {
        let targets: [LightboxAsset]
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            targets = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        } else {
            targets = [asset]
        }

        return targets.compactMap { target in
            guard !target.isDeleted, let sourceURL = target.sourceURL else {
                return nil
            }
            return sourceURL.standardizedFileURL
        }
    }

    func canReceiveFileDrop(on tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return !tab.isStartPage && tab.filter != .trash
    }

    @discardableResult
    func enqueueFileTransfer(
        sourceURLs: [URL],
        to tabID: UUID,
        operation: FileTransferOperation
    ) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              !tab.isStartPage, tab.filter != .trash
        else {
            return false
        }

        var seenPaths = Set<String>()
        let urls = sourceURLs.compactMap { url -> URL? in
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL,
                  seenPaths.insert(standardized.path).inserted
            else {
                return nil
            }
            return standardized
        }
        guard !urls.isEmpty else { return false }

        fileTransfers.enqueue(
            FileTransferRequest(
                sourceURLs: urls,
                destinationFolderURL: tab.folderURL,
                operation: operation
            )
        )
        return true
    }

    func scheduleTabActivationForAssetDrag(_ tabID: UUID) {
        guard tabID != activeTabID, canReceiveFileDrop(on: tabID) else { return }
        tabDragHoverTask?.cancel()
        tabDragHoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            self?.selectTab(tabID)
        }
    }

    func cancelTabActivationForAssetDrag() {
        tabDragHoverTask?.cancel()
        tabDragHoverTask = nil
    }

    func cancelFileTransfer() {
        fileTransfers.cancel()
    }

    func fileTransferStatusText(_ progress: FileTransferProgress) -> String {
        switch progress.phase {
        case .active:
            let action = progress.operation == .exportJPEG
                ? exportText.exporting
                : localized(progress.operation == .copy ? .copyingFiles : .movingFiles)
            return "\(action) \(min(progress.completedCount, progress.totalCount))/\(progress.totalCount)"
        case .completed:
            return localized(.fileTransferComplete)
        case .failed:
            return "\(localized(.fileTransferFailed)) (\(progress.failedCount))"
        case .cancelled:
            return localized(.fileTransferCancelled)
        }
    }

    func dismissFileTransferStatus() {
        fileTransfers.dismissStatus()
    }

    func applyFileTransferResult(_ result: FileTransferResult) {
        if result.operation == .exportJPEG,
           result.failures.contains(where: { $0.message.contains(PhotoshopJPEGExport.notPermittedMessage) }) {
            presentPhotoshopPermissionAlert()
        }
        let committedFailureDestinations = result.failures.compactMap(\.committedDestinationURL)
        guard !result.successes.isEmpty || !committedFailureDestinations.isEmpty else { return }
        let effectiveMoves = result.operation == .move
            ? result.successes.filter {
                $0.sourceURL.standardizedFileURL.path != $0.destinationURL.standardizedFileURL.path
            }
            : []
        let movedSourcePaths = result.operation == .move
            ? Set(effectiveMoves.map { $0.sourceURL.standardizedFileURL.path })
            : []
        let affectedFolderPaths = Set(
            result.successes.flatMap { success in
                var paths = [success.destinationURL.deletingLastPathComponent().standardizedFileURL.path]
                if result.operation == .move {
                    paths.append(success.sourceURL.deletingLastPathComponent().standardizedFileURL.path)
                }
                // An export may have made its folder inside the one shown.
                if result.operation == .exportJPEG {
                    paths.append(success.destinationURL.deletingLastPathComponent()
                        .deletingLastPathComponent().standardizedFileURL.path)
                }
                return paths
            } + committedFailureDestinations.map {
                $0.deletingLastPathComponent().standardizedFileURL.path
            }
        )

        if !movedSourcePaths.isEmpty {
            // Moves are not undoable yet; earlier steps (a rename, a move to
            // the Trash) would act on paths that are gone, so they go too.
            renameUndoManager()?.removeAllActions()
            tabSession.updateAll { tab in
                tab.selectedAssetIDs = tab.selectedAssetIDs.filter { assetID in
                    !movedSourcePaths.contains(Self.sourcePath(fromAssetID: assetID) ?? "")
                }
                if let selectedID = tab.selectedAssetID,
                   movedSourcePaths.contains(Self.sourcePath(fromAssetID: selectedID) ?? "") {
                    tab.selectedAssetID = nil
                }
            }

            assets.removeAll { asset in
                asset.sourceURL.map { movedSourcePaths.contains($0.standardizedFileURL.path) } == true
            }
            searchResultAssets?.removeAll { asset in
                asset.sourceURL.map { movedSourcePaths.contains($0.standardizedFileURL.path) } == true
            }
            selectedAssetIDs = selectedAssetIDs.filter { assetID in
                !movedSourcePaths.contains(Self.sourcePath(fromAssetID: assetID) ?? "")
            }
            if let selectedAssetID,
               movedSourcePaths.contains(Self.sourcePath(fromAssetID: selectedAssetID) ?? "") {
                self.selectedAssetID = firstVisibleID(in: selectedAssetIDs)
            }
            compareTray.relocate(effectiveMoves)
            rebuildActiveAssets()
        }

        ImageCache.shared.removeThumbnailMemoryObjects(reason: "file-transfer")
        captureActiveTabState()
        if affectedFolderPaths.contains(currentFolderURL.standardizedFileURL.path) {
            scheduleLibraryRefresh()
        }
    }

    private static func sourcePath(fromAssetID assetID: LightboxAsset.ID) -> String? {
        guard assetID.hasPrefix("file:") else { return nil }
        return String(assetID.dropFirst("file:".count))
    }
}
