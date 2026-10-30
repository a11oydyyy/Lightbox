import AppKit
import Foundation

/// The images an export sheet is open for.
struct JPEGExportRequest: Identifiable, Equatable {
    let id = UUID()
    var assets: [LightboxAsset]
}

// Opening in Photoshop, and exporting JPEGs through it (`PhotoshopJPEGExport`).
extension AppState {
    var exportText: ExportText { ExportText(appLanguage) }

    /// The selection (or `asset`) in Photoshop, when it is installed.
    func openInPhotoshop(fallback asset: LightboxAsset) {
        guard let applicationURL = PhotoshopJPEGExport.applicationURL else { return }
        openWithApplication(asset, applicationURL: applicationURL)
    }

    /// Opens the export sheet for the selected images (or `asset`).
    func beginJPEGExport(fallback asset: LightboxAsset) {
        let images = operationTargetAssets(fallback: asset).filter { $0.isImage && !$0.isDeleted && $0.sourceURL != nil }
        guard !images.isEmpty, PhotoshopJPEGExport.applicationURL != nil else { return }
        jpegExportRequest = JPEGExportRequest(assets: images)
    }

    /// File › Open in Photoshop and Export as JPEG act on the selection.
    var canSendSelectionToPhotoshop: Bool {
        PhotoshopJPEGExport.applicationURL != nil && !hasActiveOverlay && !isViewingTrash && selectedAssetID != nil
    }

    func openSelectionInPhotoshop() {
        guard canSendSelectionToPhotoshop, let asset = selectedAsset else { return }
        openInPhotoshop(fallback: asset)
    }

    func exportSelectionAsJPEG() {
        guard canSendSelectionToPhotoshop, let asset = selectedAsset else { return }
        beginJPEGExport(fallback: asset)
    }

    /// Queues the export with the copies and moves, which show its progress.
    func exportJPEG(_ request: JPEGExportRequest, options: JPEGExportOptions) {
        jpegExportRequest = nil
        options.save(defaults: libraryDefaults)
        let urls = request.assets.compactMap(\.sourceURL)
        guard let first = urls.first else { return }
        fileTransfers.enqueue(FileTransferRequest(
            sourceURLs: urls,
            destinationFolderURL: options.destinationFolder(for: first),
            operation: .exportJPEG,
            jpegExport: options
        ))
    }

    /// Apple Events to Photoshop were refused: says where to allow them.
    func presentPhotoshopPermissionAlert() {
        let text = exportText
        let alert = NSAlert()
        alert.messageText = text.notPermittedTitle
        alert.informativeText = text.notPermittedMessage
        alert.addButton(withTitle: text.openSettings)
        alert.addButton(withTitle: text.cancelButton)
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

extension JPEGExportOptions {
    private static let defaultsKey = "Lightbox.jpegExport.v1"

    /// The options last exported with.
    static func load(defaults: UserDefaults) -> JPEGExportOptions {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(JPEGExportOptions.self, from: $0) }
            ?? JPEGExportOptions()
    }

    func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
