import Darwin
import Foundation
import Testing
@testable import LightboxNative

private final class MonitorDescriptorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var started = false
    func begin() { lock.withLock { started = true } }
    var didBegin: Bool { lock.withLock { started } }
    func record(_ value: Int32) { lock.withLock { descriptor = value } }
    var wasClosed: Bool {
        lock.withLock { descriptor.map { fcntl($0, F_GETFD) == -1 } ?? false }
    }
}

@Test @MainActor func directoryMonitorStartsWithoutBlockingAndDisposesCancelledOpen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxSlowMonitor-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let release = DispatchSemaphore(value: 0)
    let probe = MonitorDescriptorProbe()
    let monitor = DirectoryChangeMonitor(url: folder, openDirectory: { url in
        probe.begin()
        release.wait()
        let descriptor = open(url.path, O_EVTONLY)
        probe.record(descriptor)
        return descriptor
    })
    // Bound the old synchronous implementation so the regression fails instead of hanging.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { release.signal() }
    let start = ContinuousClock.now
    monitor.start {}
    #expect(start.duration(to: .now) < .milliseconds(150))
    let openedBy = ContinuousClock.now.advanced(by: .seconds(2))
    while !probe.didBegin && ContinuousClock.now < openedBy {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.didBegin)
    monitor.stop()
    release.signal()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !probe.wasClosed && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.wasClosed)
}

@Test @MainActor func directoryMonitorObservesChangesAfterBackgroundAttachment() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxMonitorEvents-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let monitor = DirectoryChangeMonitor(url: folder)
    var changes = 0
    monitor.start { changes += 1 }
    defer { monitor.stop() }
    // A creation immediately after start must survive the background attachment gap.
    try Data().write(to: folder.appendingPathComponent("during-attachment.png"))
    let attachedBy = ContinuousClock.now.advanced(by: .seconds(3))
    while changes == 0 && ContinuousClock.now < attachedBy {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(changes > 0)
    let initial = changes
    try Data().write(to: folder.appendingPathComponent("new.png"))
    let changedBy = ContinuousClock.now.advanced(by: .seconds(3))
    while changes == initial && ContinuousClock.now < changedBy {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(changes > initial)
    monitor.stop()
    let stopped = changes
    try Data().write(to: folder.appendingPathComponent("later.png"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(changes == stopped)
}

@Test @MainActor func cancelledMonitorDoesNotPublishLateOpenFailure() async throws {
    let gate = DispatchSemaphore(value: 0)
    let probe = MonitorDescriptorProbe()
    let monitor = DirectoryChangeMonitor(url: URL(fileURLWithPath: "/tmp"), openDirectory: { _ in
        probe.begin()
        _ = gate.wait(timeout: .now() + 5)
        return -1
    })
    var invalidations = 0
    monitor.start(onInvalidated: { invalidations += 1 }) {}
    defer { gate.signal(); monitor.stop() }
    for _ in 0..<300 where !probe.didBegin { try await Task.sleep(for: .milliseconds(5)) }
    try #require(probe.didBegin)
    monitor.stop()
    gate.signal()
    try await Task.sleep(for: .milliseconds(50))
    #expect(invalidations == 0)
}

@Test @MainActor func replacedDirectoryInvalidatesOldMonitor() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxReplaceMonitor-\(UUID())")
    let folder = work.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let monitor = DirectoryChangeMonitor(url: folder)
    var changes = 0
    var invalidations = 0
    monitor.start(onInvalidated: { invalidations += 1 }) { changes += 1 }
    defer { monitor.stop() }
    try Data().write(to: folder.appendingPathComponent("attached.png"))
    for _ in 0..<500 where changes == 0 { try await Task.sleep(for: .milliseconds(5)) }
    try #require(changes > 0)
    try FileManager.default.moveItem(at: folder, to: work.appendingPathComponent("old-photos"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for _ in 0..<500 where invalidations == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(invalidations == 1)
}
