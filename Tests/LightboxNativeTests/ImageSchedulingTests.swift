import Testing
@preconcurrency import AppKit
import Foundation
@testable import LightboxNative

enum ImageSchedulingPriorityRoute: CaseIterable, Equatable, Sendable {
    case handle
    case sameKeyAttachment
    case sharperAttachment
    case migratedHandle
    case inheritedPriority
}

@Test(arguments: ImageSchedulingPriorityRoute.allCases)
@MainActor func imageSchedulingRaisesQueuedPriorityWithoutRestarting(_ route: ImageSchedulingPriorityRoute) async throws {
    let (cache, recorder) = try await schedulingBlockedCache()
    defer { recorder.releaseAllBlockers() }
    var targetCompletions = 0
    var competitorCompleted = false
    let quality: ImageCacheQuality
    switch route {
    case .handle, .sameKeyAttachment: quality = .preview
    case .sharperAttachment: quality = .thumbnail
    case .migratedHandle, .inheritedPriority: quality = .thumbnailFast
    }
    let targetURL = schedulingURL("target")
    let handle = try #require(cache.image(
        for: targetURL, quality: quality,
        priority: route == .inheritedPriority ? .high : .low
    ) { _ in targetCompletions += 1 })
    _ = cache.image(for: schedulingURL("competitor"), quality: .preview, priority: .normal) { _ in
        competitorCompleted = true
    }
    switch route {
    case .handle:
        handle.updatePriority(.high)
    case .sameKeyAttachment:
        _ = cache.image(for: targetURL, quality: quality, priority: .high) { _ in
            targetCompletions += 1
        }
    case .sharperAttachment:
        _ = cache.image(for: targetURL, quality: .thumbnailFast, priority: .high) { _ in
            targetCompletions += 1
        }
    case .migratedHandle, .inheritedPriority:
        _ = cache.image(for: targetURL, quality: .thumbnail, priority: .low) { _ in
            targetCompletions += 1
        }
        if route == .migratedHandle { handle.updatePriority(.high) }
    }
    // A later low update cannot undo either explicit or inherited priority.
    handle.updatePriority(.low)
    recorder.releaseOneBlocker()
    let expectedCompletions = route == .handle ? 1 : 2
    try await schedulingWaitUntil { competitorCompleted && targetCompletions == expectedCompletions }
    #expect(recorder.nonBlockerNames == ["target", "competitor"])
    #expect(recorder.decodeCount(for: "target") == 1)
    if route == .migratedHandle || route == .inheritedPriority {
        #expect(recorder.qualities(for: "target") == [.thumbnail])
    }
}

@Test @MainActor func imageSchedulingCancelsAllMigratedSubscribersBeforeDecode() async throws {
    let (cache, recorder) = try await schedulingBlockedCache()
    defer { recorder.releaseAllBlockers() }
    let url = schedulingURL("cancelled")
    var cancelledCompletions = 0
    let first = try #require(cache.image(for: url, quality: .thumbnailFast, priority: .low) { _ in
        cancelledCompletions += 1
    })
    let attached = try #require(cache.image(for: url, quality: .thumbnailFast, priority: .low) { _ in
        cancelledCompletions += 1
    })
    let promoted = try #require(cache.image(for: url, quality: .thumbnail, priority: .high) { _ in
        cancelledCompletions += 1
    })
    promoted.cancel()
    first.cancel()
    attached.cancel()
    first.cancel()
    attached.updatePriority(.high)
    var sentinelCompleted = false
    _ = cache.image(for: schedulingURL("sentinel"), quality: .preview, priority: .normal) { _ in
        sentinelCompleted = true
    }
    recorder.releaseOneBlocker()
    try await schedulingWaitUntil { sentinelCompleted }
    #expect(recorder.decodeCount(for: "cancelled") == 0)
    #expect(cancelledCompletions == 0)
    #expect(recorder.nonBlockerNames == ["sentinel"])
}

@Test @MainActor func imageSchedulingCancelsMigratedSubscriberWithoutCancellingSurvivor() async throws {
    let (cache, recorder) = try await schedulingBlockedCache()
    defer { recorder.releaseAllBlockers() }
    let url = schedulingURL("survivor")
    var cancelledCompletions = 0
    var survivorCompletions = 0
    let first = try #require(cache.image(for: url, quality: .thumbnailFast, priority: .low) { _ in
        cancelledCompletions += 1
    })
    _ = cache.image(for: url, quality: .thumbnail, priority: .high) { _ in
        survivorCompletions += 1
    }
    first.cancel()
    recorder.releaseOneBlocker()
    try await schedulingWaitUntil { survivorCompletions == 1 }
    #expect(cancelledCompletions == 0)
    #expect(recorder.decodeCount(for: "survivor") == 1)
    #expect(recorder.qualities(for: "survivor") == [.thumbnail])
}

@MainActor
private func schedulingBlockedCache() async throws -> (ImageCache, ImageSchedulingRecorder) {
    let recorder = ImageSchedulingRecorder()
    let cache = ImageCache(
        memoryProfile: ImageCacheMemoryProfile(isCompatibilityMode: true),
        decodeImage: { url, quality in
            recorder.decode(url, quality: quality)
            return nil
        },
        fileSignature: { _ in nil }
    )
    for index in 0..<3 {
        _ = cache.image(for: schedulingURL("blocker-\(index)"), quality: .preview, priority: .normal) { _ in }
    }
    do {
        try await schedulingWaitUntil { recorder.startedBlockerCount == 3 }
    } catch {
        recorder.releaseAllBlockers()
        throw error
    }
    return (cache, recorder)
}

private func schedulingURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/lightbox-scheduling/\(name).jpg")
}

@MainActor
private func schedulingWaitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}

private final class ImageSchedulingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let blockerGate = DispatchSemaphore(value: 0)
    private var events: [(String, ImageCacheQuality)] = []

    var startedBlockerCount: Int {
        lock.withLock { events.filter { $0.0.hasPrefix("blocker-") }.count }
    }

    var nonBlockerNames: [String] {
        lock.withLock { events.map(\.0).filter { !$0.hasPrefix("blocker-") } }
    }

    func decode(_ url: URL, quality: ImageCacheQuality) {
        let name = url.deletingPathExtension().lastPathComponent
        lock.withLock { events.append((name, quality)) }
        if name.hasPrefix("blocker-") {
            _ = blockerGate.wait(timeout: .now() + 5)
        }
    }

    func decodeCount(for name: String) -> Int {
        lock.withLock { events.filter { $0.0 == name }.count }
    }

    func qualities(for name: String) -> [ImageCacheQuality] {
        lock.withLock { events.filter { $0.0 == name }.map(\.1) }
    }

    func releaseOneBlocker() { blockerGate.signal() }

    func releaseAllBlockers() {
        for _ in 0..<3 { blockerGate.signal() }
    }
}
