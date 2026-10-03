import Testing
@preconcurrency import AppKit
import Foundation
@testable import LightboxNative

@Test func thumbnailWritesDoNotBlockEnqueueAndHaveBoundedWaitingCapacity() async throws {
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let events = ThumbnailWriteTestEvents()
    let scheduler = ThumbnailWriteScheduler(
        maxPendingWrites: 8,
        store: { _, url, _, _ in
            events.append(url.lastPathComponent)
            if url.lastPathComponent == "active" {
                #expect(gate.wait(timeout: .now() + 5) == .success)
            }
        },
        removeAll: {}
    )
    let generation = scheduler.currentGeneration
    let image = NSImage(size: NSSize(width: 8, height: 8))
    #expect(scheduler.enqueue(image, for: schedulerTestURL("active"), quality: .thumbnail,
                              signature: nil, expectedGeneration: generation))
    try await schedulerTestWaitUntil { events.values == ["active"] }

    let started = Date()
    for index in 0..<8 {
        #expect(scheduler.enqueue(image, for: schedulerTestURL("waiting-\(index)"), quality: .thumbnail,
                                  signature: nil, expectedGeneration: generation))
    }
    #expect(!scheduler.enqueue(image, for: schedulerTestURL("overflow"), quality: .thumbnail,
                               signature: nil, expectedGeneration: generation))
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(events.values == ["active"])
    gate.signal()
    await Task.detached { scheduler.waitUntilIdle() }.value
    #expect(events.values == ["active"] + (0..<8).map { "waiting-\($0)" })
}

@Test func thumbnailClearRejectsOldGenerationAndOrdersNewWritesAfterClear() async throws {
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let events = ThumbnailWriteTestEvents()
    let scheduler = ThumbnailWriteScheduler(
        store: { _, url, _, _ in
            events.append(url.lastPathComponent)
            if url.lastPathComponent == "active" {
                #expect(gate.wait(timeout: .now() + 5) == .success)
            }
        },
        removeAll: { events.append("clear") }
    )
    let original = scheduler.currentGeneration
    let image = NSImage(size: NSSize(width: 8, height: 8))
    #expect(scheduler.enqueue(image, for: schedulerTestURL("active"), quality: .thumbnail,
                              signature: nil, expectedGeneration: original))
    try await schedulerTestWaitUntil { events.values == ["active"] }
    #expect(scheduler.enqueue(image, for: schedulerTestURL("old-pending"), quality: .thumbnail,
                              signature: nil, expectedGeneration: original))
    let clearing = Task.detached { scheduler.removeAll() }
    try await schedulerTestWaitUntil { scheduler.currentGeneration != original }
    #expect(!scheduler.enqueue(image, for: schedulerTestURL("old-late"), quality: .thumbnail,
                               signature: nil, expectedGeneration: original))
    #expect(scheduler.enqueue(image, for: schedulerTestURL("new"), quality: .thumbnail,
                              signature: nil, expectedGeneration: scheduler.currentGeneration))
    #expect(events.values == ["active"])
    gate.signal()
    await clearing.value
    await Task.detached { scheduler.waitUntilIdle() }.value
    #expect(events.values == ["active", "clear", "new"])
}

@Test func thumbnailClearReleasesWaitingImagePayloadsBeforeActiveWriteFinishes() async throws {
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let events = ThumbnailWriteTestEvents()
    let scheduler = ThumbnailWriteScheduler(
        store: { _, _, _, _ in
            events.append("active")
            #expect(gate.wait(timeout: .now() + 5) == .success)
        },
        removeAll: {}
    )
    let original = scheduler.currentGeneration
    let active = NSImage(size: NSSize(width: 8, height: 8))
    #expect(scheduler.enqueue(active, for: schedulerTestURL("active"), quality: .thumbnail,
                              signature: nil, expectedGeneration: original))
    try await schedulerTestWaitUntil { events.values == ["active"] }
    var pending: NSImage? = NSImage(size: NSSize(width: 8, height: 8))
    weak let releasedImage = pending
    #expect(scheduler.enqueue(try #require(pending), for: schedulerTestURL("pending"), quality: .thumbnail,
                              signature: nil, expectedGeneration: original))
    pending = nil
    #expect(releasedImage != nil)
    let clearing = Task.detached { scheduler.removeAll() }
    try await schedulerTestWaitUntil { scheduler.currentGeneration != original }
    #expect(releasedImage == nil)
    gate.signal()
    await clearing.value
    await Task.detached { scheduler.waitUntilIdle() }.value
    #expect(events.values == ["active"])
}

@Test func thumbnailRepeatedClearsKeepEveryWaitingClearBarrier() async throws {
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let events = ThumbnailWriteTestEvents()
    let scheduler = ThumbnailWriteScheduler(
        store: { _, _, _, _ in
            events.append("active")
            #expect(gate.wait(timeout: .now() + 5) == .success)
        },
        removeAll: { events.append("clear") }
    )
    let original = scheduler.currentGeneration
    #expect(scheduler.enqueue(NSImage(size: NSSize(width: 8, height: 8)),
                              for: schedulerTestURL("active"), quality: .thumbnail,
                              signature: nil, expectedGeneration: original))
    try await schedulerTestWaitUntil { events.values == ["active"] }
    let firstClear = Task.detached { scheduler.removeAll() }
    try await schedulerTestWaitUntil { scheduler.currentGeneration == original + 1 }
    let secondClear = Task.detached { scheduler.removeAll() }
    try await schedulerTestWaitUntil { scheduler.currentGeneration == original + 2 }
    gate.signal()
    await firstClear.value
    await secondClear.value
    await Task.detached { scheduler.waitUntilIdle() }.value
    #expect(events.values == ["active", "clear", "clear"])
}

private func schedulerTestURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/lightbox-thumbnail-scheduler/\(name)")
}

private func schedulerTestWaitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}

private final class ThumbnailWriteTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] { lock.withLock { events } }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}
