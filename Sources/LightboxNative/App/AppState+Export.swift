import AppKit
import Foundation

/// Adobe Photoshop, where finished Camera Raw edits are made.
enum PhotoshopApp {
    static let bundleIdentifier = "com.adobe.Photoshop"

    /// The installed Photoshop, if any; looked up once a launch, as menus
    /// ask on every update.
    static let url: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
}

extension AppState {
    var photoshopText: PhotoshopText { PhotoshopText(appLanguage) }

    /// The selection (or `asset`) in Photoshop, when it is installed.
    func openInPhotoshop(fallback asset: LightboxAsset) {
        guard let applicationURL = PhotoshopApp.url else { return }
        openWithApplication(asset, applicationURL: applicationURL)
    }

    /// File › Open in Photoshop acts on the selection.
    var canSendSelectionToPhotoshop: Bool {
        PhotoshopApp.url != nil && !hasActiveOverlay && !isViewingTrash && selectedAssetID != nil
    }

    func openSelectionInPhotoshop() {
        guard canSendSelectionToPhotoshop, let asset = selectedAsset else { return }
        openInPhotoshop(fallback: asset)
    }
}
