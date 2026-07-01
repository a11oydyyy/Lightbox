@preconcurrency import Foundation
@preconcurrency import AppKit
import CryptoKit
import ImageIO
import OSLog

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private nonisolated static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "ImageDecode")

    private let cache = NSCache<NSString, NSImage>()
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
    private let decodeImage: @Sendable (URL, ImageCacheQuality) -> NSImage?

    init(
        diskCache: ThumbnailDiskCache = ThumbnailDiskCache(),
        memoryProfile: ImageCacheMemoryProfile = .current,
        decodeImage: @escaping @Sendable (URL, ImageCacheQuality) -> NSImage? = ImageCache.downsampledImage
    ) {
        self.diskCache = diskCache
        self.decodeImage = decodeImage
        self.memoryProfile = memoryProfile
        decodeQueue = Self.makeDecodeQueue(memoryProfile: memoryProfile)
        cache.countLimit = memoryProfile.thumbnailCountLimit
        cache.totalCostLimit = memoryProfile.thumbnailTotalCostLimit
        comparisonCache.countLimit = memoryProfile.comparisonCountLimit
        comparisonCache.totalCostLimit = memoryProfile.comparisonTotalCostLimit
    }

    func removeAll() {
        let (nextGeneration, pending) = resetDecodeQueue()
        cache.removeAllObjects()
        comparisonCache.removeAllObjects()
        diskCache.removeAll()
        telemetry.reset()
        Self.logger.info("cache clear generation=\(nextGeneration) cancelledPending=\(pending)")
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
        decodeQueue = Self.makeDecodeQueue(memoryProfile: memoryProfile)
        return (nextGeneration, pending)
    }

    private static func makeDecodeQueue(memoryProfile: ImageCacheMemoryProfile = .current) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "Lightbox.ImageDecode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = memoryProfile.decodeConcurrency
        return queue
    }

    @MainActor
    @discardableResult
    func image(
        for url: URL,
        quality: ImageCacheQuality,
        priority: ImageDecodePriority = .normal,
        completion: @escaping @MainActor @Sendable (NSImage?) -> Void
    ) -> ImageCacheRequest? {
        let key = cacheKey(for: url, quality: quality)
        if let image = cachedImage(forKey: key, quality: quality) {
            if let snapshot = telemetry.record(.memoryHit, quality: quality) {
                Self.logThumbnailCacheSummary(snapshot)
            }
            completion(image)
            return nil
        }

        let requestGeneration = currentGeneration()
        let requestID = nextRequestID()
        let subscriberID = UUID()
        let filePath = url.standardizedFileURL.path
        var inheritedCompletions: [UUID: @MainActor @Sendable (NSImage?) -> Void] = [:]
        var operationsToCancel: [Operation] = []
        requestLock.lock()
        if var pendingDecode = pendingDecodes[key],
           pendingDecode.generation == requestGeneration {
            pendingDecode.completions[subscriberID] = completion
            let subscriberCount = pendingDecode.completions.count
            pendingDecodes[key] = pendingDecode
            requestLock.unlock()
            if requestID <= 8 || subscriberCount >= 4 {
                Self.logger.info("decode coalesced id=\(requestID) generation=\(requestGeneration) quality=\(quality.rawValue, privacy: .public) subscribers=\(subscriberCount) file=\(url.lastPathComponent, privacy: .public)")
            }
            return ImageCacheRequest { [weak self] in
                self?.cancelPendingSubscriber(key: key, subscriberID: subscriberID)
            }
        }

        if let preferred = pendingDecodes.first(where: { _, pending in
            pending.generation == requestGeneration
                && pending.filePath == filePath
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
        operation.queuePriority = priority.queuePriority
        let queuedAt = Date()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self else { return }
            guard operation?.isCancelled == false else { return }
            let startedAt = Date()
            let diskImage = quality.usesDiskCache ? self.diskCache.image(for: url, quality: quality) : nil
            let image = diskImage ?? self.decodeImage(url, quality)
            if diskImage == nil, let image, quality.usesDiskCache {
                self.diskCache.store(image, for: url, quality: quality)
            }
            let cacheSource: ImageCacheTelemetrySource
            if diskImage != nil {
                cacheSource = .diskHit
            } else if image != nil {
                cacheSource = .decoded
            } else {
                cacheSource = .failure
            }
            guard operation?.isCancelled == false else { return }
            if let snapshot = self.telemetry.record(cacheSource, quality: quality) {
                Self.logThumbnailCacheSummary(snapshot)
            }
            let finishedAt = Date()
            let waitSeconds = startedAt.timeIntervalSince(queuedAt)
            let decodeSeconds = finishedAt.timeIntervalSince(startedAt)
            let usedDiskCache = diskImage != nil
            let shouldLog = requestID <= 8 || image == nil || waitSeconds > 0.75 || decodeSeconds > 0.55

            Task { @MainActor in
                guard self.currentGeneration() == requestGeneration else {
                    if shouldLog {
                        Self.logger.info("decode drop id=\(requestID) generation=\(requestGeneration) currentGeneration=\(self.currentGeneration()) file=\(url.lastPathComponent, privacy: .public)")
                    }
                    return
                }
                if let image {
                    self.store(image, forKey: key, quality: quality)
                }
                let completions = self.finishPendingDecode(key: key, generation: requestGeneration)
                if shouldLog {
                    Self.logger.info("decode complete id=\(requestID) quality=\(quality.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public) source=\(usedDiskCache ? "disk" : "decode", privacy: .public) success=\(image != nil) subscribers=\(completions.count) wait=\(waitSeconds, format: .fixed(precision: 2))s decode=\(decodeSeconds, format: .fixed(precision: 2))s pending=\(self.decodeQueue.operationCount) file=\(url.lastPathComponent, privacy: .public)")
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
        pendingDecodes[key] = PendingDecode(
            generation: requestGeneration,
            operation: operation,
            quality: quality,
            filePath: filePath,
            completions: inheritedCompletions
        )
        requestLock.unlock()
        decodeQueue.addOperation(operation)
        return ImageCacheRequest { [weak self] in
            self?.cancelPendingSubscriber(key: key, subscriberID: subscriberID)
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
        generation: Int
    ) -> [@MainActor @Sendable (NSImage?) -> Void] {
        requestLock.lock()
        guard let pendingDecode = pendingDecodes[key],
              pendingDecode.generation == generation
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

    private func cacheKey(for url: URL, quality: ImageCacheQuality) -> String {
        "\(quality.rawValue):\(url.path)"
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

    func bestCachedImage(for url: URL, quality: ImageCacheQuality) -> NSImage? {
        for candidate in quality.cacheLookupOrder {
            let key = cacheKey(for: url, quality: candidate)
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
        quality == .comparison ? comparisonCache : cache
    }

    private static func downsampledImage(for url: URL, quality: ImageCacheQuality) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
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

    static func thumbnailCreationOptions(
        maxPixelSize: Int,
        prefersEmbeddedPreview: Bool
    ) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: true,
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
    private let folder: URL
    private let fileManager: FileManager

    init(
        folder: URL = LightboxLibraryStore.cacheFolder.appendingPathComponent("Thumbnails", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.folder = folder
        self.fileManager = fileManager
    }

    func image(for url: URL, quality: ImageCacheQuality) -> NSImage? {
        guard let cacheURL = cacheURL(for: url, quality: quality),
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
        guard let cacheURL = cacheURL(for: url, quality: quality),
              let data = encodedData(for: image)
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    func removeAll() {
        try? fileManager.removeItem(at: folder)
    }

    func cacheURL(for url: URL, quality: ImageCacheQuality) -> URL? {
        guard quality.usesDiskCache,
              let signature = ThumbnailFileSignature(url: url)
        else {
            return nil
        }

        let key = Self.cacheKey(for: url, quality: quality, signature: signature)
        return folder.appendingPathComponent(key, isDirectory: false).appendingPathExtension("jpg")
    }

    static func cacheKey(
        for url: URL,
        quality: ImageCacheQuality,
        signature: ThumbnailFileSignature
    ) -> String {
        let rawKey = [
            quality.rawValue,
            String(quality.maxPixelSize),
            url.standardizedFileURL.path,
            String(format: "%.6f", signature.modificationTime),
            String(signature.fileSize)
        ].joined(separator: "|")

        return SHA256.hash(data: Data(rawKey.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
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

struct ThumbnailFileSignature: Equatable {
    var modificationTime: TimeInterval
    var fileSize: UInt64

    init(modificationTime: TimeInterval, fileSize: UInt64) {
        self.modificationTime = modificationTime
        self.fileSize = fileSize
    }

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate
        else {
            return nil
        }

        modificationTime = modificationDate.timeIntervalSince1970
        fileSize = UInt64(max(0, values.fileSize ?? 0))
    }
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
    var operation: Operation
    var quality: ImageCacheQuality
    var filePath: String
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
