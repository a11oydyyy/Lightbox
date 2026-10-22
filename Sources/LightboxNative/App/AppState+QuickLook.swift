import AppKit

// Quick Look for files, as in Finder: Space on a file, ⌘Y for the selection.
extension AppState {
    var canQuickLook: Bool {
        !hasActiveOverlay && (!selectedAssetIDs.isEmpty || explicitlySelectedAsset != nil)
    }

    /// Space on a card. Images keep Lightbox's own preview; other files (with
    /// the rest of a selection holding them) open Quick Look. Space again closes it.
    func handleSpace(on asset: LightboxAsset) {
        if quickLook.isVisible {
            quickLook.close()
            return
        }
        guard !asset.isImage else {
            showPreview(for: asset, sourceFrame: previewSpaceFrame(for: asset.id))
            return
        }
        showQuickLook(operationTargetAssets(fallback: asset))
    }

    /// ⌘Y: Quick Look for the selection or the focused file, or closes it.
    func toggleQuickLook() {
        if quickLook.isVisible {
            quickLook.close()
            return
        }
        guard canQuickLook else { return }
        if !selectedAssetIDs.isEmpty {
            let selected = selectedAssetIDs
            showQuickLook(activeAssets.filter { selected.contains($0.id) })
        } else if let asset = explicitlySelectedAsset {
            showQuickLook([asset])
        }
    }

    func showQuickLook(_ assets: [LightboxAsset]) {
        let shown = assets.filter { $0.sourceURL != nil }
        guard !shown.isEmpty else { return }
        quickLookAssetIDs = shown.map(\.id)
        quickLook.show(shown.compactMap(\.sourceURL))
    }

    /// An arrow key in the panel while it shows one file: the gallery moves
    /// its focus, and the panel shows the file it lands on.
    func followQuickLook(_ key: UInt16) {
        guard quickLookAssetIDs.count == 1, let current = quickLookAssetIDs.first else { return }
        handleGalleryKey(key, modifiers: [], from: current)
        guard let next = galleryKeyboardFocusID, next != current,
              let asset = activeAssets.first(where: { $0.id == next }) else { return }
        showQuickLook([asset])
    }
}
