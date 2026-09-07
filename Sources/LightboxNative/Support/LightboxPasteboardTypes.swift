import AppKit

enum LightboxPasteboardTypes {
    static let internalAssetDragIdentifier = "io.github.a11oydyyy.lightbox.internal-asset-drag"
    static let internalAssetDrag = NSPasteboard.PasteboardType(internalAssetDragIdentifier)
}

enum LightboxDragState {
    @MainActor static var isDraggingAsset = false
    @MainActor static var sourceURLs: [URL] = []

    @MainActor
    static func beginAssetDrag(sourceURLs: [URL]) {
        isDraggingAsset = true
        self.sourceURLs = sourceURLs
    }

    @MainActor
    static func endAssetDrag() {
        isDraggingAsset = false
        sourceURLs = []
    }
}
