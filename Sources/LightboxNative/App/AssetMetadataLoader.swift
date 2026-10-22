import Foundation
import OSLog

/// Reads image dimensions, Finder tags and whether Camera Raw has settings
/// for each image in the background, saving them to
/// the index and handing them back in batches. Folder loads and searches each
/// own one.
///
/// Sizes come from the index's `image_dimensions` while the file's
/// modification time and size are unchanged, so only new or edited files are
/// decoded. Tags are always read from the file (changing them leaves the
/// modification time alone).
///
/// One request runs at a time; starting another (or `cancel`) stops it, and
/// what was read so far is still saved. `AppState` decides which images need
/// what and applies each batch only while the same view is on screen.
@MainActor
final class AssetMetadataLoader {
    struct Request: Sendable {
        var targets: [AssetMetadataTarget]
        var sourceID: LibrarySource.ID
        var folderURL: URL
        /// The refresh (or search generation) this belongs to, passed back for
        /// logging and checks.
        var refreshID: Int
        var startDelayMilliseconds: Int
        /// The name search a batch belongs to; nil for folders and recursive scans.
        var searchText: String? = nil
        var pacing: Pacing = .folder
    }

    /// How often batches are handed back.
    enum Pacing: Sendable {
        /// The first `batchSize` images at once, then at most every 0.12s:
        /// each batch re-filters and re-lays out the gallery on the main
        /// thread. A short pause every `batchSize` images leaves the disk to
        /// thumbnails.
        case folder
        /// The first image at once, then at most every 0.15s (or 256 images):
        /// search results are on screen waiting for their sizes.
        case search
    }

    /// Images are handed back (and saved) this many at a time.
    nonisolated static let batchSize = 32
    nonisolated private static let storedLookupChunk = 256
    nonisolated private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "LibraryLoading")

    /// A batch of updates, with how many of the request's images are done.
    var onBatch: (_ updates: [AssetMetadataUpdate], _ processed: Int, _ request: Request) -> Void = { _, _, _ in }
    /// Called once every image of the request has been read.
    var onFinish: (_ request: Request, _ elapsed: TimeInterval) -> Void = { _, _ in }

    private let indexDatabaseURL: URL
    private let dimensionProbe: @Sendable (URL) -> CGSize?
    private var task: Task<Void, Never>?

    init(
        indexDatabaseURL: URL,
        dimensionProbe: @escaping @Sendable (URL) -> CGSize? = { ImageProbe.dimensions(for: $0) }
    ) {
        self.indexDatabaseURL = indexDatabaseURL
        self.dimensionProbe = dimensionProbe
    }

    deinit {
        task?.cancel()
    }

    var isRunning: Bool { task != nil }

    /// The images of `snapshot` that need reading: dimensions for the first
    /// `metadataLimit` without them, tags for the first `tagLimit`.
    nonisolated static func targets(
        for snapshot: [LightboxAsset],
        metadataLimit: Int,
        tagLimit: Int,
        loadsFinderTags: Bool
    ) -> [AssetMetadataTarget] {
        snapshot.enumerated().compactMap { index, asset -> AssetMetadataTarget? in
            let shouldLoadDimensions = index < metadataLimit && !asset.metadataLoaded
            let shouldLoadTags = loadsFinderTags && index < tagLimit
            guard shouldLoadDimensions || shouldLoadTags || asset.isImage, let url = asset.sourceURL else { return nil }
            return AssetMetadataTarget(
                id: asset.id,
                url: url,
                shouldLoadDimensions: shouldLoadDimensions,
                shouldLoadTags: shouldLoadTags,
                signature: asset.fileContentSignature,
                shouldCheckCameraRaw: asset.isImage
            )
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(_ request: Request) {
        task?.cancel()
        let indexDatabaseURL = indexDatabaseURL
        let dimensionProbe = dimensionProbe
        let refreshID = request.refreshID
        let total = request.targets.count
        let priority: TaskPriority = request.pacing == .search ? .utility : .background
        task = Task.detached(priority: priority) { [weak self] in
            if request.startDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(request.startDelayMilliseconds))
            }
            guard !Task.isCancelled else { return }
            let startedAt = Date()
            let store = LightboxIndexStore(databaseURL: indexDatabaseURL)
            var stored: [String: StoredImageDimensions] = [:]
            var batch: [AssetMetadataUpdate] = []
            var probed: [StoredImageDimensions] = []
            var processedCount = 0
            var cachedCount = 0
            // Each folder's sidecar names, listed once per request (one read
            // instead of a lookup per RAW, which counts on network volumes).
            var sidecarNames: [String: Set<String>] = [:]
            func sidecars(beside url: URL) -> Set<String> {
                let folder = url.deletingLastPathComponent().path
                if let known = sidecarNames[folder] { return known }
                let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                    .map { $0.lowercased() }.filter { $0.hasSuffix(".xmp") })
                sidecarNames[folder] = names
                return names
            }
            var lastPublishAt = Date()

            func persist(_ updates: [AssetMetadataUpdate]) {
                store.storeImageDimensions(probed)
                probed.removeAll(keepingCapacity: true)
                guard !updates.isEmpty else { return }
                store.updateCachedMetadata(
                    sourceID: request.sourceID,
                    updates: updates.map {
                        IndexedAssetMetadata(url: $0.url, width: $0.width, height: $0.height, tags: $0.tags)
                    }
                )
            }
            func cancelled() -> Bool {
                guard Task.isCancelled else { return false }
                AssetMetadataLoader.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(total)")
                return true
            }
            func dueToPublish() -> Bool {
                switch request.pacing {
                case .folder:
                    guard batch.count >= AssetMetadataLoader.batchSize
                            || processedCount % AssetMetadataLoader.batchSize == 0 else { return false }
                    return processedCount <= AssetMetadataLoader.batchSize
                        || Date().timeIntervalSince(lastPublishAt) >= 0.12
                case .search:
                    return processedCount == 1 || batch.count >= 256
                        || Date().timeIntervalSince(lastPublishAt) >= 0.15
                }
            }

            for (index, target) in request.targets.enumerated() {
                if cancelled() { persist(batch); return }
                // Look stored sizes up a chunk at a time, so the first results
                // of a large search are not held up by the whole lookup.
                if index % AssetMetadataLoader.storedLookupChunk == 0 {
                    stored = store.storedImageDimensions(paths: request.targets[index...].prefix(AssetMetadataLoader.storedLookupChunk)
                        .compactMap { $0.shouldLoadDimensions && $0.signature != nil ? $0.url.standardizedFileURL.path : nil })
                }
                let size = autoreleasepool { () -> CGSize? in
                    guard target.shouldLoadDimensions else { return nil }
                    let path = target.url.standardizedFileURL.path
                    if let signature = target.signature, let known = stored[path],
                       known.signature.matchesStoredMetadata(signature) {
                        cachedCount += 1
                        return CGSize(width: known.width, height: known.height)
                    }
                    guard let size = dimensionProbe(target.url) else { return nil }
                    if let signature = FileContentSignature(url: target.url) {
                        probed.append(StoredImageDimensions(path: path, signature: signature,
                                                            width: size.width, height: size.height))
                    }
                    return size
                }
                if cancelled() { persist(batch); return }
                let tags = target.shouldLoadTags ? FinderTagStore.colorTags(for: target.url) : nil
                let hasCameraRawSettings = target.shouldCheckCameraRaw ? autoreleasepool {
                    CameraRawSettings.hasSettings(
                        for: target.url, signature: target.signature,
                        sidecarNames: RawSidecar.candidates(for: target.url).isEmpty ? nil : sidecars(beside: target.url)
                    )
                } : nil
                processedCount += 1
                if size != nil || tags != nil || hasCameraRawSettings != nil {
                    batch.append(AssetMetadataUpdate(
                        id: target.id,
                        url: target.url,
                        width: size?.width,
                        height: size?.height,
                        tags: tags,
                        hasCameraRawSettings: hasCameraRawSettings
                    ))
                }
                if cancelled() { persist(batch); return }

                // Even with nothing new, so progress moves.
                if dueToPublish() {
                    lastPublishAt = Date()
                    let updates = batch
                    batch.removeAll(keepingCapacity: true)
                    persist(updates)
                    let processed = processedCount
                    await MainActor.run { self?.onBatch(updates, processed, request) }
                    if cancelled() { return }
                }
                if processedCount % AssetMetadataLoader.batchSize == 0 {
                    try? await Task.sleep(for: .milliseconds(request.pacing == .folder ? 6 : 4))
                }
            }

            if !batch.isEmpty || processedCount > 0 {
                persist(batch)
                let updates = batch
                let processed = processedCount
                await MainActor.run { self?.onBatch(updates, processed, request) }
                if cancelled() { return }
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            AssetMetadataLoader.logger.info("refresh[\(refreshID)] metadata read total=\(total) fromIndex=\(cachedCount) seconds=\(elapsed, format: .fixed(precision: 2))")
            await MainActor.run {
                self?.task = nil
                self?.onFinish(request, elapsed)
            }
        }
    }
}
