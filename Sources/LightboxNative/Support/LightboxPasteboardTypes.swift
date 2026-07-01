import AppKit

enum LightboxPasteboardTypes {
    static let internalAssetDragIdentifier = "io.github.a11oydyyy.lightbox.internal-asset-drag"
    static let internalAssetDrag = NSPasteboard.PasteboardType(internalAssetDragIdentifier)
}

enum LightboxDragState {
    @MainActor static var isDraggingAsset = false
}
