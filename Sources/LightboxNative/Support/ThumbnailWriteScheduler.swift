@preconcurrency import AppKit
@preconcurrency import Foundation

final class ThumbnailWriteScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Lightbox.ThumbnailWrite", qos: .utility)
    private let lock = NSLock()
    private let maxPendingWrites: Int
    private let store: @Sendable (NSImage, URL, ImageCacheQuality, FileContentSignature?) -> Void
    private let clear: @Sendable () -> Void
    private var generation = 0
    private var pendingWrites = 0
    private var jobs: [Job] = []
    private var isDraining = false

    init(
        maxPendingWrites: Int = 8,
        store: @escaping @Sendable (NSImage, URL, ImageCacheQuality, FileContentSignature?) -> Void,
        removeAll: @escaping @Sendable () -> Void
    ) {
        self.maxPendingWrites = max(0, maxPendingWrites)
        self.store = store
        clear = removeAll
    }

    var currentGeneration: Int {
        lock.withLock { generation }
    }

    @discardableResult
    func enqueue(
        _ image: NSImage,
        for url: URL,
        quality: ImageCacheQuality,
        signature: FileContentSignature?,
        expectedGeneration: Int
    ) -> Bool {
        lock.withLock {
            guard expectedGeneration == generation,
                  pendingWrites < maxPendingWrites
            else { return false }
            jobs.append(.write(image, url, quality, signature))
            pendingWrites += 1
            startDrainingIfNeeded()
            return true
        }
    }

    // Keep clear barriers even when another clear discards pending image payloads.
    // New writes enter behind this barrier; an active old write finishes before it.
    func removeAll() {
        let completed = DispatchSemaphore(value: 0)
        lock.withLock {
            generation += 1
            jobs.removeAll { job in
                if case .write = job { return true }
                return false
            }
            pendingWrites = 0
            jobs.append(.clear(completed))
            startDrainingIfNeeded()
        }
        completed.wait()
    }

    // A synchronous drain is useful when a caller explicitly needs persisted pixels.
    // Call outside the write queue; async tests can await it in Task.detached.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        while let job = nextJob() {
            autoreleasepool {
                switch job {
                case let .write(image, url, quality, signature):
                    store(image, url, quality, signature)
                case let .clear(completed):
                    clear()
                    completed.signal()
                }
            }
        }
    }

    private func nextJob() -> Job? {
        lock.withLock {
            guard !jobs.isEmpty else {
                isDraining = false
                return nil
            }
            let job = jobs.removeFirst()
            if case .write = job { pendingWrites -= 1 }
            return job
        }
    }

    private enum Job {
        case write(NSImage, URL, ImageCacheQuality, FileContentSignature?)
        case clear(DispatchSemaphore)
    }
}
