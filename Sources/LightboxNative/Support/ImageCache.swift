@preconcurrency import Foundation
@preconcurrency import AppKit
import CryptoKit
import ImageIO
import OSLog

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private nonisolated static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "ImageDecode")

    private let cache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()
    private let comparisonCache = NSCache<NSString, NSImage>()
    private var decodeQueue: OperationQueue
    private let memoryProfile: ImageCacheMemoryProfile
    private let generationLock = NSLock()
    private let requestLock = NSLock()
    private var generation = 0
    private var requestSerial = 0
    private var pendingDecodes: [String: PendingDecode] = [:]
    private let diskCache: ThumbnailDiskCache
    private let telemetry = ImageCacheTelemetry()
    private let fileSignature: @Sendable (URL) -> FileContentSignature?
    private let decodeImage: @Sendable (URL, ImageCacheQuality) -> NSImage?

    init(
        diskCache: ThumbnailDiskCache = ThumbnailDiskCache(),
        memoryProfile: ImageCacheMemoryProfile = .current,
        decodeImage: @escaping @Sendable (URL, ImageCacheQuality) -> NSImage? = ImageCache.downsampledImage,
        fileSignature: @escaping @Sendable (URL) -> FileContentSignature? = { FileContentSignature(url: $0) }
    ) {
        self.diskCache = diskCache
        self.decodeImage = decodeImage
        self.fileSignature = fileSignature
        self.memoryProfile = memoryProfile
        decodeQueue = Self.makeDecodeQueue(memoryProfile: memoryProfile)
        cache.countLimit = memoryProfile.thumbnailCountLimit
        cache.totalCostLimit = memoryProfile.thumbnailTotalCostLimit
        previewCache.countLimit = memoryProfile.previewCountLimit
        previewCache.totalCostLimit = memoryProfile.previewTotalCostLimit
        comparisonCache.countLimit = memoryProfile.comparisonCountLimit
        comparisonCache.totalCostLimit = memoryProfile.comparisonTotalCostLimit
    }

    func removeAll() {
        let (nextGeneration, pending) = resetDecodeQueue()
        cache.removeAllObjects()
        previewCache.removeAllObjects()
        comparisonCache.removeAllObjects()
        diskCache.removeAll()
        telemetry.reset()
        Self.logger.info("cache clear generation=\(nextGeneration) cancelledPending=\(pending)")
    }

    func removeMemoryObjects(reason: String) {
        let (nextGeneration, pending) = resetDecodeQueue()
        cache.removeAllObjects()
        previewCache.removeAllObjects()
        comparisonCache.removeAllObjects()
        telemetry.reset()
        Self.logger.info("memory cache clear reason=\(reason, privacy: .public) generation=\(nextGeneration) cancelledPending=\(pending)")
    }

    func removeThumbnailMemoryObjects(reason: String) {
        let (nextGeneration, pending) = resetDecodeQueue()
        cache.removeAllObjects()
        telemetry.reset()
        Self.logger.info("thumbnail memory cache clear reason=\(reason, privacy: .public) generation=\(nextGeneration) cancelledPending=\(pending)")
    }

    func removeSourceMemoryObjects(reason: String) {
        let (nextGeneration, pending) = resetDecodeQueue()
        cache.removeAllObjects()
        comparisonCache.removeAllObjects()
        telemetry.reset()
        Self.logger.info("source memory cache clear reason=\(reason, privacy: .public) generation=\(nextGeneration) cancelledPending=\(pending)")
    }

    func cancelOutstandingRequests(reason: String) {
        let (nextGeneration, pending) = resetDecodeQueue()
        Self.logger.info("decode queue reset reason=\(reason, privacy: .public) generation=\(nextGeneration) cancelledPending=\(pending)")
    }

    private func resetDecodeQueue() -> (generation: Int, pending: Int) {
        generationLock.lock()
        generation += 1
        let nextGeneration = generation
        generationLock.unlock()
        requestLock.lock()
        let pendingSubscriberCount = pendingDecodes.values.reduce(0) { $0 + $1.completions.count }
        pendingDecodes.removeAll()
        requestLock.unlock()
        let pending = max(decodeQueue.operationCount, pendingSubscriberCount)
        decodeQueue.cancelAllOperations()
        return (nextGeneration, pending)
    }

    private static func makeDecodeQueue(memoryProfile: ImageCacheMemoryProfile = .current) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "Lightbox.ImageDecode"
        queue.qualityOfService = .default
        queue.maxConcurrentOperationCount = memoryProfile.decodeConcurrency
        return queue
    }

    @MainActor
    @discardableResult
    func image(
        for url: URL,
        quality: ImageCacheQuality,
        knownFileSignature: FileContentSignature? = nil,
        priority: ImageDecodePriority = .normal,
        completion: @escaping @MainActor @Sendable (NSImage?) -> Void
    ) -> ImageCacheRequest? {
        // Asset metadata is a hint. The current signature is resolved on the decode queue so
        // external volumes can detect same-path replacements without blocking the main actor.
        let pendingKey = cacheKey(for: url, quality: quality, signature: knownFileSignature)

        let requestGeneration = currentGeneration()
        let requestID = nextRequestID()
        let subscriberID = UUID()
        let filePath = url.standardizedFileURL.path
        var inheritedCompletions: [UUID: @MainActor @Sendable (NSImage?) -> Void] = [:]
        var operationsToCancel: [Operation] = []
        requestLock.lock()
        if var pendingDecode = pendingDecodes[pendingKey],
           pendingDecode.generation == requestGeneration {
            pendingDecode.completions[subscriberID] = completion
            let subscriberCount = pendingDecode.completions.count
            pendingDecodes[pendingKey] = pendingDecode
            requestLock.unlock()
            if requestID <= 8 || subscriberCount >= 4 {
                Self.logger.info("decode coalesced id=\(requestID) generation=\(requestGeneration) quality=\(quality.rawValue, privacy: .public) subscribers=\(subscriberCount) file=\(url.lastPathComponent, privacy: .public)")
            }
            return ImageCacheRequest { [weak self] in
                self?.cancelPendingSubscriber(key: pendingKey, subscriberID: subscriberID)
            }
        }

        if let preferred = pendingDecodes.first(where: { _, pending in
            pending.generation == requestGeneration
                && pending.filePath == filePath
                && pending.fileSignature == knownFileSignature
                && Self.shouldAttach(requested: quality, toPending: pending.quality)
        }) {
            var pendingDecode = preferred.value
            pendingDecode.completions[subscriberID] = completion
            let subscriberCount = pendingDecode.completions.count
            pendingDecodes[preferred.key] = pendingDecode
            requestLock.unlock()
            if requestID <= 8 || subscriberCount >= 4 {
                Self.logger.info("decode coalesced-up id=\(requestID) generation=\(requestGeneration) requested=\(quality.rawValue, privacy: .public) pending=\(pendingDecode.quality.rawValue, privacy: .public) subscribers=\(subscriberCount) file=\(url.lastPathComponent, privacy: .public)")
            }
            return ImageCacheRequest { [weak self] in
                self?.cancelPendingSubscriber(key: preferred.key, subscriberID: subscriberID)
            }
        }

        let promotionKeys = pendingDecodes.compactMap { pendingKey, pending -> String? in
            guard pending.generation == requestGeneration,
                  pending.filePath == filePath,
                  pending.fileSignature == knownFileSignature,
                  Self.shouldPromote(pending: pending.quality, to: quality)
            else {
                return nil
            }

            return pendingKey
        }

        for promotionKey in promotionKeys {
            guard let promoted = pendingDecodes.removeValue(forKey: promotionKey) else { continue }
            inheritedCompletions.merge(promoted.completions) { current, _ in current }
            operationsToCancel.append(promoted.operation)
        }
        requestLock.unlock()

        for operationToCancel in operationsToCancel {
            operationToCancel.cancel()
        }
        if !inheritedCompletions.isEmpty {
            Self.logger.info("decode promote id=\(requestID) generation=\(requestGeneration) quality=\(quality.rawValue, privacy: .public) inherited=\(inheritedCompletions.count) cancelled=\(operationsToCancel.count) file=\(url.lastPathComponent, privacy: .public)")
        }

        let operation = BlockOperation()
        let pendingToken = UUID()
        operation.queuePriority = priority.queuePriority
        operation.qualityOfService = priority.qualityOfService
        let queuedAt = Date()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self else { return }
            let startedAt = Date()

            let decodeResult: (
                image: NSImage?,
                cacheSource: ImageCacheTelemetrySource,
                resolvedKey: String
            )? = autoreleasepool {
                guard operation?.isCancelled == false,
                      self.currentGeneration() == requestGeneration
                else {
                    return nil
                }

                let currentSignature = self.fileSignature(url)
                let resolvedKey = self.cacheKey(
                    for: url,
                    quality: quality,
                    signature: currentSignature
                )
                let memoryImage = self.cachedImage(forKey: resolvedKey, quality: quality)
                let diskImage = memoryImage == nil && quality.usesDiskCache
                    ? self.diskCache.image(for: url, quality: quality, signature: currentSignature)
                    : nil
                guard operation?.isCancelled == false,
                      self.currentGeneration() == requestGeneration
                else {
                    return nil
                }

                let image = memoryImage ?? diskImage ?? self.decodeImage(url, quality)
                guard operation?.isCancelled == false,
                      self.currentGeneration() == requestGeneration
                else {
                    return nil
                }

                if memoryImage == nil, diskImage == nil, let image, quality.usesDiskCache {
                    self.diskCache.store(image, for: url, quality: quality, signature: currentSignature)
                }

                let cacheSource: ImageCacheTelemetrySource
                if memoryImage != nil {
                    cacheSource = .memoryHit
                } else if diskImage != nil {
                    cacheSource = .diskHit
                } else if image != nil {
                    cacheSource = .decoded
                } else {
                    cacheSource = .failure
                }

                return (image, cacheSource, resolvedKey)
            }
            guard let decodeResult else { return }
            if let snapshot = self.telemetry.record(decodeResult.cacheSource, quality: quality) {
                Self.logThumbnailCacheSummary(snapshot)
            }
            let finishedAt = Date()
            let waitSeconds = startedAt.timeIntervalSince(queuedAt)
            let decodeSeconds = finishedAt.timeIntervalSince(startedAt)
            let shouldLog = requestID <= 8 || decodeResult.image == nil || waitSeconds > 0.75 || decodeSeconds > 0.55
            let cacheSourceName: String
            switch decodeResult.cacheSource {
            case .memoryHit:
                cacheSourceName = "memory"
            case .diskHit:
                cacheSourceName = "disk"
            case .decoded:
                cacheSourceName = "decode"
            case .failure:
                cacheSourceName = "failure"
            }

            Task { @MainActor in
                guard self.currentGeneration() == requestGeneration else {
                    if shouldLog {
                        Self.logger.info("decode drop id=\(requestID) generation=\(requestGeneration) currentGeneration=\(self.currentGeneration()) file=\(url.lastPathComponent, privacy: .public)")
                    }
                    return
                }
                let image = decodeResult.image
                if let image {
                    self.store(image, forKey: decodeResult.resolvedKey, quality: quality)
                    if decodeResult.resolvedKey != pendingKey {
                        self.store(image, forKey: pendingKey, quality: quality)
                    }
                }
                let completions = self.finishPendingDecode(
                    key: pendingKey,
                    generation: requestGeneration,
                    token: pendingToken
                )
                if shouldLog {
                    Self.logger.info("decode complete id=\(requestID) quality=\(quality.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public) source=\(cacheSourceName, privacy: .public) success=\(image != nil) subscribers=\(completions.count) wait=\(waitSeconds, format: .fixed(precision: 2))s decode=\(decodeSeconds, format: .fixed(precision: 2))s pending=\(self.decodeQueue.operationCount) file=\(url.lastPathComponent, privacy: .public)")
                }
                for completion in completions {
                    completion(image)
                }
            }
        }
        let pending = decodeQueue.operationCount
        if requestID <= 8 || pending >= 96 {
            Self.logger.info("decode enqueue id=\(requestID) generation=\(requestGeneration) quality=\(quality.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public) pendingBefore=\(pending) file=\(url.lastPathComponent, privacy: .public)")
        }
        if pending >= 48 && (pending % 48 == 0 || pending >= 144) {
            Self.logger.info("decode backlog pending=\(pending) quality=\(quality.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public)")
        }
        requestLock.lock()
        inheritedCompletions[subscriberID] = completion
        pendingDecodes[pendingKey] = PendingDecode(
            generation: requestGeneration,
            token: pendingToken,
            operation: operation,
            quality: quality,
            filePath: filePath,
            fileSignature: knownFileSignature,
            completions: inheritedCompletions
        )
        requestLock.unlock()
        decodeQueue.addOperation(operation)
        return ImageCacheRequest { [weak self] in
            self?.cancelPendingSubscriber(key: pendingKey, subscriberID: subscriberID)
        }
    }

    private func cancelPendingSubscriber(key: String, subscriberID: UUID) {
        requestLock.lock()
        guard var pendingDecode = pendingDecodes[key] else {
            requestLock.unlock()
            return
        }

        pendingDecode.completions.removeValue(forKey: subscriberID)
        if pendingDecode.completions.isEmpty {
            pendingDecodes.removeValue(forKey: key)
            let operation = pendingDecode.operation
            requestLock.unlock()
            operation.cancel()
            return
        }

        pendingDecodes[key] = pendingDecode
        requestLock.unlock()
    }

    private func finishPendingDecode(
        key: String,
        generation: Int,
        token: UUID
    ) -> [@MainActor @Sendable (NSImage?) -> Void] {
        requestLock.lock()
        guard let pendingDecode = pendingDecodes[key],
              pendingDecode.generation == generation,
              pendingDecode.token == token
        else {
            requestLock.unlock()
            return []
        }

        pendingDecodes.removeValue(forKey: key)
        let completions = Array(pendingDecode.completions.values)
        requestLock.unlock()
        return completions
    }

    private func nextRequestID() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        requestSerial += 1
        return requestSerial
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func cacheKey(
        for url: URL,
        quality: ImageCacheQuality,
        signature: FileContentSignature?
    ) -> String {
        let signatureKey = signature?.cacheKeyComponent ?? "missing"
        return "\(quality.rawValue):\(url.standardizedFileURL.path):\(signatureKey)"
    }

    static func shouldAttach(requested: ImageCacheQuality, toPending pending: ImageCacheQuality) -> Bool {
        guard let requestedRank = requested.thumbnailRank,
              let pendingRank = pending.thumbnailRank
        else {
            return false
        }

        return pendingRank > requestedRank
    }

    static func shouldPromote(pending: ImageCacheQuality, to requested: ImageCacheQuality) -> Bool {
        guard let pendingRank = pending.thumbnailRank,
              let requestedRank = requested.thumbnailRank
        else {
            return false
        }

        return requestedRank > pendingRank
    }

    func bestCachedImage(
        for url: URL,
        quality: ImageCacheQuality,
        knownFileSignature: FileContentSignature? = nil
    ) -> NSImage? {
        guard let fileSignature = knownFileSignature else { return nil }
        for candidate in quality.cacheLookupOrder {
            let key = cacheKey(for: url, quality: candidate, signature: fileSignature)
            if let image = cachedImage(forKey: key, quality: candidate) {
                return image
            }
        }

        return nil
    }

    private func cachedImage(forKey key: String, quality: ImageCacheQuality) -> NSImage? {
        cache(for: quality).object(forKey: key as NSString)
    }

    private func store(_ image: NSImage, forKey key: String, quality: ImageCacheQuality) {
        cache(for: quality).setObject(image, forKey: key as NSString, cost: Self.cost(for: image))
    }

    private func cache(for quality: ImageCacheQuality) -> NSCache<NSString, NSImage> {
        switch quality {
        case .preview:
            previewCache
        case .comparison:
            comparisonCache
        default:
            cache
        }
    }

    private static func downsampledImage(for url: URL, quality: ImageCacheQuality) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions() as CFDictionary) else {
            return nil
        }

        let options = thumbnailCreationOptions(
            maxPixelSize: quality.maxPixelSize,
            prefersEmbeddedPreview: quality.prefersEmbeddedPreview
        ) as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    static func imageSourceOptions() -> [CFString: Any] {
        [
            kCGImageSourceShouldCache: false
        ]
    }

    static func thumbnailCreationOptions(
        maxPixelSize: Int,
        prefersEmbeddedPreview: Bool
    ) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if prefersEmbeddedPreview {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return options
    }

    private static func cost(for image: NSImage) -> Int {
        Int(max(1, image.size.width) * max(1, image.size.height) * 4)
    }

    private static func logThumbnailCacheSummary(_ snapshot: ImageCacheTelemetrySnapshot) {
        logger.info("thumbnail cache summary total=\(snapshot.total) memory=\(snapshot.memoryHits) disk=\(snapshot.diskHits) decoded=\(snapshot.decoded) failed=\(snapshot.failures) hitRate=\(snapshot.hitRate * 100, format: .fixed(precision: 1))%")
    }
}

struct ImageCacheMemoryProfile: Equatable {
    var isCompatibilityMode: Bool

    static var current: ImageCacheMemoryProfile {
        ImageCacheMemoryProfile(isCompatibilityMode: LightboxRuntime.usesCompatibilityPerformanceMode)
    }

    var thumbnailCountLimit: Int {
        isCompatibilityMode ? 96 : 160
    }

    var thumbnailTotalCostLimit: Int {
        (isCompatibilityMode ? 96 : 180) * 1024 * 1024
    }

    var previewCountLimit: Int {
        isCompatibilityMode ? 3 : 5
    }

    var previewTotalCostLimit: Int {
        (isCompatibilityMode ? 96 : 160) * 1024 * 1024
    }

    var comparisonCountLimit: Int {
        isCompatibilityMode ? 12 : 24
    }

    var comparisonTotalCostLimit: Int {
        (isCompatibilityMode ? 256 : 512) * 1024 * 1024
    }

    var decodeConcurrency: Int {
        isCompatibilityMode ? 3 : 4
    }
}

enum ImageCacheTelemetrySource {
    case memoryHit
    case diskHit
    case decoded
    case failure
}

struct ImageCacheTelemetrySnapshot: Equatable {
    var total: Int
    var memoryHits: Int
    var diskHits: Int
    var decoded: Int
    var failures: Int

    var hitRate: Double {
        guard total > 0 else { return 0 }
        return Double(memoryHits + diskHits) / Double(total)
    }
}

final class ImageCacheTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private let summaryInterval: Int
    private var total = 0
    private var memoryHits = 0
    private var diskHits = 0
    private var decoded = 0
    private var failures = 0

    init(summaryInterval: Int = 80) {
        self.summaryInterval = max(1, summaryInterval)
    }

    func record(_ source: ImageCacheTelemetrySource, quality: ImageCacheQuality) -> ImageCacheTelemetrySnapshot? {
        guard quality.usesDiskCache else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        total += 1
        switch source {
        case .memoryHit:
            memoryHits += 1
        case .diskHit:
            diskHits += 1
        case .decoded:
            decoded += 1
        case .failure:
            failures += 1
        }

        guard total == 1 || total.isMultiple(of: summaryInterval) else {
            return nil
        }

        return snapshot()
    }

    func reset() {
        lock.lock()
        total = 0
        memoryHits = 0
        diskHits = 0
        decoded = 0
        failures = 0
        lock.unlock()
    }

    private func snapshot() -> ImageCacheTelemetrySnapshot {
        ImageCacheTelemetrySnapshot(
            total: total,
            memoryHits: memoryHits,
            diskHits: diskHits,
            decoded: decoded,
            failures: failures
        )
    }
}

final class ThumbnailDiskCache: @unchecked Sendable {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.a11oydyyy.Lightbox",
        category: "ThumbnailDiskCache"
    )
    private let folder: URL
    private let fileManager: FileManager
    private let maxDiskBytes: Int64
    private let pruneInterval: TimeInterval
    private let maintenanceLock = NSLock()
    private var lastPruneAt: Date?
    private var bytesWrittenSinceLastPrune: Int64 = 0

    init(
        folder: URL = LightboxLibraryStore.cacheFolder.appendingPathComponent("Thumbnails", isDirectory: true),
        fileManager: FileManager = .default,
        maxDiskBytes: Int64 = 1024 * 1024 * 1024,
        pruneInterval: TimeInterval = 30
    ) {
        self.folder = folder
        self.fileManager = fileManager
        self.maxDiskBytes = max(0, maxDiskBytes)
        self.pruneInterval = max(0, pruneInterval)
    }

    func image(for url: URL, quality: ImageCacheQuality) -> NSImage? {
        image(for: url, quality: quality, signature: FileContentSignature(url: url))
    }

    func image(
        for url: URL,
        quality: ImageCacheQuality,
        signature: FileContentSignature?
    ) -> NSImage? {
        guard let cacheURL = cacheURL(for: url, quality: quality, signature: signature),
              fileManager.fileExists(atPath: cacheURL.path)
        else {
            return nil
        }

        guard let image = NSImage(contentsOf: cacheURL) else {
            try? fileManager.removeItem(at: cacheURL)
            return nil
        }

        return image
    }

    func store(_ image: NSImage, for url: URL, quality: ImageCacheQuality) {
        store(image, for: url, quality: quality, signature: FileContentSignature(url: url))
    }

    func store(
        _ image: NSImage,
        for url: URL,
        quality: ImageCacheQuality,
        signature: FileContentSignature?
    ) {
        guard let cacheURL = cacheURL(for: url, quality: quality, signature: signature),
              let data = encodedData(for: image)
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: [.atomic])
            pruneIfNeeded(addedBytes: Int64(data.count))
        } catch {
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    func removeAll() {
        try? fileManager.removeItem(at: folder)
        maintenanceLock.lock()
        lastPruneAt = nil
        bytesWrittenSinceLastPrune = 0
        maintenanceLock.unlock()
    }

    func pruneIfNeeded(force: Bool = false) {
        pruneIfNeeded(addedBytes: 0, force: force)
    }

    func cacheURL(for url: URL, quality: ImageCacheQuality) -> URL? {
        cacheURL(for: url, quality: quality, signature: FileContentSignature(url: url))
    }

    private func cacheURL(
        for url: URL,
        quality: ImageCacheQuality,
        signature: FileContentSignature?
    ) -> URL? {
        guard quality.usesDiskCache,
              let signature
        else {
            return nil
        }

        let key = Self.cacheKey(for: url, quality: quality, signature: signature)
        return folder.appendingPathComponent(key, isDirectory: false).appendingPathExtension("jpg")
    }

    static func cacheKey(
        for url: URL,
        quality: ImageCacheQuality,
        signature: FileContentSignature
    ) -> String {
        let rawKey = [
            quality.rawValue,
            String(quality.maxPixelSize),
            url.standardizedFileURL.path,
            signature.cacheKeyComponent
        ].joined(separator: "|")

        return SHA256.hash(data: Data(rawKey.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func pruneIfNeeded(addedBytes: Int64, force: Bool = false) {
        maintenanceLock.lock()
        defer { maintenanceLock.unlock() }

        bytesWrittenSinceLastPrune += max(0, addedBytes)
        let now = Date()
        let elapsed = lastPruneAt.map { now.timeIntervalSince($0) } ?? .infinity
        let growthThreshold = max(1, min(maxDiskBytes / 20, 64 * 1024 * 1024))
        let shouldPrune = force
            || lastPruneAt == nil
            || elapsed >= pruneInterval
            || bytesWrittenSinceLastPrune >= growthThreshold
        guard shouldPrune else { return }

        lastPruneAt = now
        bytesWrittenSinceLastPrune = 0
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let entries = urls.compactMap { url -> ThumbnailDiskCacheEntry? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize
            else {
                return nil
            }
            let recentDate = [values.contentAccessDate, values.contentModificationDate]
                .compactMap { $0 }
                .max() ?? .distantPast
            return ThumbnailDiskCacheEntry(
                url: url,
                fileSize: Int64(max(0, fileSize)),
                recentDate: recentDate
            )
        }
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.fileSize }
        guard totalBytes > maxDiskBytes else { return }

        var removedCount = 0
        for entry in entries.sorted(by: {
            if $0.recentDate != $1.recentDate {
                return $0.recentDate < $1.recentDate
            }
            return $0.url.path < $1.url.path
        }) where totalBytes > maxDiskBytes {
            do {
                try fileManager.removeItem(at: entry.url)
                totalBytes -= entry.fileSize
                removedCount += 1
            } catch {
                continue
            }
        }

        if removedCount > 0 {
            Self.logger.info("thumbnail disk cache pruned removed=\(removedCount) remainingBytes=\(totalBytes) limitBytes=\(self.maxDiskBytes)")
        }
    }

    private func encodedData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
            ?? bitmap.representation(using: .png, properties: [:])
    }
}

private struct ThumbnailDiskCacheEntry {
    var url: URL
    var fileSize: Int64
    var recentDate: Date
}

final class ImageCacheRequest {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}

private struct PendingDecode {
    var generation: Int
    var token: UUID
    var operation: Operation
    var quality: ImageCacheQuality
    var filePath: String
    var fileSignature: FileContentSignature?
    var completions: [UUID: @MainActor @Sendable (NSImage?) -> Void]
}

enum ImageDecodePriority: Equatable {
    case high
    case normal
    case low

    var queuePriority: Operation.QueuePriority {
        switch self {
        case .high:
            .veryHigh
        case .normal:
            .normal
        case .low:
            .low
        }
    }

    var qualityOfService: QualityOfService {
        switch self {
        case .high, .normal:
            .userInitiated
        case .low:
            .utility
        }
    }

    var logName: String {
        switch self {
        case .high:
            "high"
        case .normal:
            "normal"
        case .low:
            "low"
        }
    }
}

enum ImageCacheQuality: String {
    case thumbnailFast
    case thumbnailBalanced
    case thumbnail
    case preview
    case comparison

    var maxPixelSize: Int {
        switch self {
        case .thumbnailFast:
            360
        case .thumbnailBalanced:
            480
        case .thumbnail:
            1024
        case .preview:
            2400
        case .comparison:
            4096
        }
    }

    var prefersEmbeddedPreview: Bool {
        switch self {
        case .thumbnailFast, .thumbnailBalanced:
            true
        case .thumbnail, .preview, .comparison:
            false
        }
    }

    var cacheLookupOrder: [ImageCacheQuality] {
        switch self {
        case .thumbnailFast:
            [.thumbnailFast, .thumbnailBalanced, .thumbnail]
        case .thumbnailBalanced:
            [.thumbnailBalanced, .thumbnail, .thumbnailFast]
        case .thumbnail:
            [.thumbnail, .thumbnailBalanced, .thumbnailFast]
        case .preview:
            [.preview, .thumbnail, .thumbnailBalanced, .thumbnailFast, .comparison]
        case .comparison:
            [.comparison, .preview, .thumbnail, .thumbnailBalanced, .thumbnailFast]
        }
    }

    var usesDiskCache: Bool {
        switch self {
        case .thumbnailFast, .thumbnailBalanced, .thumbnail:
            true
        case .preview, .comparison:
            false
        }
    }

    var thumbnailRank: Int? {
        switch self {
        case .thumbnailFast:
            1
        case .thumbnailBalanced:
            2
        case .thumbnail:
            3
        case .preview, .comparison:
            nil
        }
    }
}
