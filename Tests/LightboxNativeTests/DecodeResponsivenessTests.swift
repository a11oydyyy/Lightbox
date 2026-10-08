import AppKit
import Testing
@testable import LightboxNative

private final class DecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let semaphore = DispatchSemaphore(value: 0)
    var started: Int { lock.withLock { count } }
    func block() {
        lock.withLock { count += 1 }
        _ = semaphore.wait(timeout: .now() + 3)
    }
    func release() { for _ in 0..<6 { semaphore.signal() } }
}

@Test @MainActor func previewDecodeStartsWhileCancelledSlowThumbnailsAreStillBlocked() async throws {
    let gate = DecodeGate()
    defer { gate.release() }
    let image = NSImage(size: NSSize(width: 8, height: 8))
    let cache = ImageCache(memoryProfile: .init(isCompatibilityMode: false), decodeImage: { _, quality in
        if quality == .preview { return image }
        gate.block()
        return nil
    }, fileSignature: { _ in nil })
    var staleCompletions = 0
    for index in 0..<6 {
        _ = cache.image(for: URL(fileURLWithPath: "/tmp/slow-\(UUID())-\(index).jpg"),
            quality: .thumbnailBalanced, priority: .low) { _ in staleCompletions += 1 }
    }
    for _ in 0..<100 where gate.started < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(gate.started >= 2)
    try await Task.sleep(for: .milliseconds(50))
    cache.cancelOutstandingRequests(reason: "test-switch-away-from-slow-volume")
    var previewFinished = false
    _ = cache.image(for: URL(fileURLWithPath: "/tmp/fast-preview-\(UUID()).jpg"),
        quality: .preview, priority: .high) { decoded in previewFinished = decoded != nil }
    for _ in 0..<40 where !previewFinished { try await Task.sleep(for: .milliseconds(5)) }
    #expect(previewFinished, "Cancelled, uninterruptible thumbnail I/O occupied every preview execution slot")
    #expect(staleCompletions == 0)
    gate.release()
    try await Task.sleep(for: .milliseconds(50))
    #expect(staleCompletions == 0)
}
