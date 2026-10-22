import AppKit
import Combine
import UniformTypeIdentifiers

/// The images queued for comparison, in the order the tray shows them.
///
/// Holds at most `limit` images and the brief feedback the tray shows: a
/// pulse on the image just added (or added twice), and a shake when the tray
/// refuses one. `AppState` owns it and republishes its changes, so views keep
/// reading the tray through `AppState`.
@MainActor
final class CompareTrayModel: ObservableObject {
    static let limit = 8

    @Published private(set) var items: [LightboxAsset] = []
    /// The image to pulse briefly after it is added.
    @Published private(set) var pulseID: LightboxAsset.ID?
    /// Bumped when the tray refuses an image or a comparison.
    @Published private(set) var rejectGeneration = 0
    /// The tray item being dragged to a new position.
    private(set) var dragID: LightboxAsset.ID?
    private var pulseTask: Task<Void, Never>?

    deinit {
        pulseTask?.cancel()
    }

    /// Adds `asset`. An image already in the tray pulses instead; a full tray
    /// refuses it.
    func add(_ asset: LightboxAsset) {
        guard !asset.isDeleted else { return }
        // Only images compare; another file gets the tray's reject flash.
        guard asset.isImage else {
            reject()
            return
        }
        guard !items.contains(where: { $0.id == asset.id }) else {
            pulse(asset.id)
            return
        }
        guard items.count < Self.limit else {
            reject()
            return
        }
        items.append(asset)
        pulse(asset.id)
    }

    func remove(_ assetID: LightboxAsset.ID) {
        items.removeAll { $0.id == assetID }
    }

    /// Swaps in a renamed copy, keeping its place in the tray.
    func replace(_ assetID: LightboxAsset.ID, with asset: LightboxAsset) {
        guard let index = items.firstIndex(where: { $0.id == assetID }) else { return }
        items[index] = asset
        if dragID == assetID { dragID = asset.id }
    }

    func clear() {
        items = []
    }

    func reject() {
        rejectGeneration += 1
    }

    /// The image's number in the tray, starting at 1.
    func label(for assetID: LightboxAsset.ID) -> String? {
        items.firstIndex { $0.id == assetID }.map { "\($0 + 1)" }
    }

    func beginDrag(_ assetID: LightboxAsset.ID) {
        dragID = assetID
    }

    /// Moves the dragged item into `targetID`'s place, the way the drag reads
    /// in either direction: onto the right-hand neighbour swaps them, onto the
    /// last item makes it last.
    func moveDraggedItem(onto targetID: LightboxAsset.ID) {
        guard let draggedID = dragID,
              draggedID != targetID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
              let toIndex = items.firstIndex(where: { $0.id == targetID })
        else {
            return
        }
        let item = items.remove(at: fromIndex)
        items.insert(item, at: toIndex)
    }

    func endDrag() {
        dragID = nil
    }

    /// Points images that were moved on disk at their new files.
    func relocate(_ successes: [FileTransferSuccess]) {
        let destinations = Dictionary(
            uniqueKeysWithValues: successes.map {
                ($0.sourceURL.standardizedFileURL.path, $0.destinationURL.standardizedFileURL)
            }
        )
        guard items.contains(where: { $0.sourceURL.map { destinations[$0.standardizedFileURL.path] != nil } == true }) else { return }
        items = items.map { asset in
            guard let sourceURL = asset.sourceURL,
                  let destinationURL = destinations[sourceURL.standardizedFileURL.path]
            else {
                return asset
            }
            return LightboxAsset(
                originalName: destinationURL.lastPathComponent,
                width: asset.width,
                height: asset.height,
                tags: asset.tags,
                sourceURL: destinationURL,
                addedAt: asset.addedAt,
                contentModifiedAt: asset.contentModifiedAt,
                fileSize: asset.fileSize,
                palette: asset.palette,
                metadataLoaded: asset.metadataLoaded
            )
        }
    }

    private func pulse(_ assetID: LightboxAsset.ID) {
        pulseTask?.cancel()
        pulseID = assetID
        pulseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self, self.pulseID == assetID else { return }
            self.pulseID = nil
        }
    }

    /// The file URL a drag onto the tray carries.
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: url(from: item))
            }
        }
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let string = String(data: data, encoding: .utf8) {
                return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
