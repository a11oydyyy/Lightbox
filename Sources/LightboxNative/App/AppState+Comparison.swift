import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// The compare tray and side-by-side comparison.
extension AppState {
    var isComparing: Bool {
        comparisonAssets.count >= 2
    }

    var canStartCompareTrayComparison: Bool {
        compareTrayAssets.count >= 2
    }

    /// Two or more selected images; other selected files are left out of a comparison.
    var canCompareSelection: Bool {
        var images = 0
        for id in selectedAssetIDs where LightboxAsset.isImageID(id) {
            images += 1
            if images >= 2 { return true }
        }
        return false
    }

    func showComparisonFromSelection() {
        let selected = activeAssets.filter { $0.isImage && selectedAssetIDs.contains($0.id) }
        guard selected.count >= 2 else { return }
        Self.comparisonLogger.info("comparison open selected=\(selected.count) source=\(self.selectedSourceID, privacy: .public)")
        ImageCache.shared.cancelOutstandingRequests(reason: "open-comparison")
        openComparison(selected)
    }

    func startCompareTrayComparison() {
        guard compareTrayAssets.count >= 2 else {
            compareTray.reject()
            return
        }
        Self.comparisonLogger.info("comparison open tray count=\(self.compareTrayAssets.count)")
        ImageCache.shared.cancelOutstandingRequests(reason: "open-compare-tray")
        openComparison(compareTrayAssets)
    }

    /// Ends any preview, then compares `assets`, the first one selected.
    private func openComparison(_ assets: [LightboxAsset]) {
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewAssetID = nil
        previewAssetSnapshot = nil
        previewSourceHiddenAssetID = nil
        previewInteractionLayerReady = false
        previewSourceFrame = nil
        previewPhase = .closed
        previewSessionID = UUID()
        previewStepDirection = nil
        comparisonAssets = assets
        selectedAssetIDs = []
        selectionAnchorID = nil
        selectedAssetID = assets.first?.id
    }

    func closeComparison() {
        guard !comparisonAssets.isEmpty else { return }
        Self.comparisonLogger.info("comparison close count=\(self.comparisonAssets.count)")
        comparisonAssets = []
    }

    func addToCompareTray(_ asset: LightboxAsset) {
        compareTray.add(asset)
    }

    func addSelectedToCompareTray(fallback asset: LightboxAsset) {
        let selected = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        let targets = selected.count > 1 && selected.contains(where: { $0.id == asset.id }) ? selected : [asset]
        for target in targets {
            compareTray.add(target)
        }
    }

    func addCompareTrayItem(for url: URL) async {
        let standardizedPath = url.standardizedFileURL.path
        if let existing = assets.first(where: { $0.sourceURL?.standardizedFileURL.path == standardizedPath }) {
            compareTray.add(existing)
            return
        }

        let count = compareTrayAssets.count
        let fallbackSize = MockLibrary.importFallbackSizes[count % MockLibrary.importFallbackSizes.count]
        let palette = MockPalette.imported[count % MockPalette.imported.count]
        let assetLoader = compareTrayAssetLoader
        let asset = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                assetLoader(url, fallbackSize, palette)
            }
        }.value
        compareTray.add(asset)
    }

    func handleCompareTrayDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { @MainActor [weak self] in
            for provider in providers {
                guard let url = await CompareTrayModel.fileURL(from: provider) else { continue }
                await self?.addCompareTrayItem(for: url)
            }
            self?.compareTray.endDrag()
        }
        return true
    }

    /// Removes an image from the tray, and from an open comparison; fewer
    /// than two left ends the comparison.
    func removeFromCompareTray(_ assetID: LightboxAsset.ID) {
        compareTray.remove(assetID)
        if comparisonAssets.contains(where: { $0.id == assetID }) {
            comparisonAssets.removeAll { $0.id == assetID }
            if comparisonAssets.count < 2 {
                closeComparison()
            }
        }
    }

    func clearCompareTray() {
        compareTray.clear()
        closeComparison()
    }

    func compareTrayLabel(for assetID: LightboxAsset.ID) -> String? {
        compareTray.label(for: assetID)
    }

    func beginCompareTrayDrag(_ assetID: LightboxAsset.ID) {
        compareTray.beginDrag(assetID)
    }

    func moveCompareTrayDraggedItem(onto targetID: LightboxAsset.ID) {
        compareTray.moveDraggedItem(onto: targetID)
    }

    func endCompareTrayDrag() {
        compareTray.endDrag()
    }
}
