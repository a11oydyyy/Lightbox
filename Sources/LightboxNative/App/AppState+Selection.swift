import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Gallery selection, clicks and keyboard navigation.
extension AppState {
    var selectedAsset: LightboxAsset? {
        guard let selectedAssetID else { return activeAssets.first }
        return assetForCurrentPresentation(selectedAssetID)
    }

    var explicitlySelectedAsset: LightboxAsset? {
        guard let selectedAssetID else { return nil }
        return assetForCurrentPresentation(selectedAssetID)
    }

    var canMoveSelectionToTrash: Bool {
        if !selectedAssetIDs.isEmpty {
            return activeAssets.contains { asset in
                selectedAssetIDs.contains(asset.id) && !asset.isDeleted && asset.sourceURL != nil
            }
        }

        guard let asset = explicitlySelectedAsset else { return false }
        return !asset.isDeleted && asset.sourceURL != nil
    }

    var selectedAssetCount: Int {
        selectedAssetIDs.count
    }

    var hasExplicitSelection: Bool {
        !selectedAssetIDs.isEmpty
    }

    func select(_ asset: LightboxAsset) {
        selectedAssetIDs = [asset.id]
        selectedAssetID = asset.id
        selectionAnchorID = asset.id
    }

    func isAssetHighlighted(_ asset: LightboxAsset) -> Bool {
        if selectedAssetIDs.isEmpty {
            return selectedAssetID == asset.id
        }

        return selectedAssetIDs.contains(asset.id)
    }

    func handleAssetClick(
        _ asset: LightboxAsset,
        modifiers: NSEvent.ModifierFlags,
        click: LightboxClickContext? = nil,
        sourceFrame: CGRect?
    ) {
        let extendsSelection = modifiers.contains(.command)
        let selectsRange = modifiers.contains(.shift)
        Self.previewLogger.info("asset click received phase=\(self.previewPhase.rawValue, privacy: .public) overlay=\(self.hasActiveOverlay, privacy: .public) asset=\(asset.originalName, privacy: .public) frame=\(Self.frameDescription(sourceFrame), privacy: .public) \(Self.clickDescription(click, sourceFrame: sourceFrame), privacy: .public)")
        guard !hasActiveOverlay else {
            Self.previewLogger.info("asset click ignored activeOverlay=true phase=\(self.previewPhase.rawValue, privacy: .public) asset=\(asset.originalName, privacy: .public) frame=\(Self.frameDescription(sourceFrame), privacy: .public)")
            return
        }

        if selectsRange {
            selectRange(to: asset, extending: extendsSelection)
            return
        }

        if extendsSelection {
            toggleSelection(asset)
            return
        }

        if !selectedAssetIDs.isEmpty {
            toggleSelection(asset)
            return
        }

        guard asset.isImage else {
            // Other files behave as in Finder: a click focuses, a double click
            // opens. Focus is not a selection, so image clicks still preview.
            if (click?.clickCount ?? 1) >= 2 {
                openInDefaultApplication(asset)
            } else {
                selectedAssetID = asset.id
                galleryKeyboardFocusID = asset.id
            }
            return
        }

        showPreview(for: asset, sourceFrame: sourceFrame)
    }

    func handleGalleryKey(_ key: UInt16, modifiers: NSEvent.ModifierFlags, from id: LightboxAsset.ID) {
        guard !hasActiveOverlay, let current = activeAssets.firstIndex(where: { $0.id == id }) else { return }
        if key == 53 { clearSelection(); return }
        if key == 0, modifiers.contains(.command) {
            replaceSelection(with: activeAssetIDs, primary: id, anchor: id)
            return
        }
        guard let targetIndex = GalleryKeyboardNavigation.targetIndex(
            key: key, current: current, ids: activeAssetIDList, frames: previewSpaceAssetFrames
        ) else { return }
        let target = activeAssets[targetIndex]
        if modifiers.contains(.shift) {
            if selectionAnchorID == nil { selectionAnchorID = id }
            selectRange(to: target, extending: modifiers.contains(.command))
        } else {
            replaceSelection(with: [target.id], primary: target.id, anchor: target.id)
        }
        galleryKeyboardFocusID = target.id
        galleryKeyboardScrollGeneration &+= 1
    }

    /// Edit › Select All when neither a card nor a text field takes it, as
    /// after a drag selection or a click on empty space: every file shown.
    var canSelectAllInGallery: Bool {
        !hasActiveOverlay && !isShowingStartPage && !activeAssetIDs.isEmpty
    }

    func selectAllInGallery() {
        guard canSelectAllInGallery else { return }
        replaceSelection(with: activeAssetIDs)
    }

    func replaceSelection(with ids: Set<LightboxAsset.ID>) {
        let primary = firstVisibleID(in: ids)
        replaceSelection(with: ids, primary: primary, anchor: primary)
    }

    func selectGalleryFolder(_ id: LibraryFolderEntry.ID) {
        clearSelection()
        galleryKeyboardFocusID = nil
        selectedGalleryFolderID = id
    }

    func clearSelection() {
        selectedGalleryFolderID = nil
        selectedAssetIDs = []
        selectedAssetID = nil
        selectionAnchorID = nil
    }

    func removeDetachedSelection() {
        if usesRecursiveResults, searchResultAssets == nil {
            return
        }
        let assetIDs = Set((assets + (searchResultAssets ?? []) + cachedActiveAssets).map(\.id))

        if let selectedAssetID, !assetIDs.contains(selectedAssetID) {
            self.selectedAssetID = nil
        }

        selectedAssetIDs = selectedAssetIDs.filter { assetIDs.contains($0) }
        if let selectionAnchorID, !assetIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }

        if let previewAssetID, !assetIDs.contains(previewAssetID), !trashMovingAssetIDs.contains(previewAssetID) {
            previewOpenTask?.cancel()
            previewCloseTask?.cancel()
            previewSourceRevealTask?.cancel()
            self.previewAssetID = nil
            previewSourceHiddenAssetID = nil
            previewInteractionLayerReady = false
            previewSourceFrame = nil
            previewAssetSnapshot = nil
            previewPhase = .closed
            previewSessionID = UUID()
            previewStepDirection = nil
        }
    }

    private func toggleSelection(_ asset: LightboxAsset) {
        selectedGalleryFolderID = nil
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
            selectedAssetID = firstVisibleID(in: selectedAssetIDs)
            if selectedAssetIDs.isEmpty {
                selectionAnchorID = nil
            }
        } else {
            selectedAssetIDs.insert(asset.id)
            selectedAssetID = asset.id
            selectionAnchorID = asset.id
        }
    }

    private func selectRange(to asset: LightboxAsset, extending: Bool) {
        let visibleIDs = activeAssetIDList
        let anchorID = selectionAnchorID ?? selectedAssetID ?? firstVisibleID(in: selectedAssetIDs) ?? asset.id

        guard let anchorIndex = visibleIDs.firstIndex(of: anchorID),
              let targetIndex = visibleIDs.firstIndex(of: asset.id)
        else {
            replaceSelection(with: [asset.id], primary: asset.id, anchor: asset.id)
            return
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let rangeIDs = Set(visibleIDs[bounds])
        let newSelection = extending ? selectedAssetIDs.union(rangeIDs) : rangeIDs
        replaceSelection(with: newSelection, primary: asset.id, anchor: anchorID)
    }

    func replaceSelection(
        with ids: Set<LightboxAsset.ID>,
        primary: LightboxAsset.ID?,
        anchor: LightboxAsset.ID?
    ) {
        if !ids.isEmpty, selectedGalleryFolderID != nil { selectedGalleryFolderID = nil }
        if selectedAssetIDs != ids { selectedAssetIDs = ids }
        if selectedAssetID != primary { selectedAssetID = primary }
        selectionAnchorID = ids.isEmpty ? nil : anchor
    }

    func firstVisibleID(in ids: Set<LightboxAsset.ID>) -> LightboxAsset.ID? {
        guard !ids.isEmpty else { return nil }
        return activeAssetIDList.first { ids.contains($0) }
    }
}
