import Foundation
import Testing
@testable import LightboxNative

private final class FileCheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var mainThread = false
    private let firstCheckGate = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { value } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }
    func check(_ url: URL) -> Bool {
        let first = lock.withLock { value += 1; mainThread = mainThread || Thread.isMainThread; return value == 1 }
        if first { _ = firstCheckGate.wait(timeout: .now() + 5) }
        Thread.sleep(forTimeInterval: 0.02)
        return url.lastPathComponent != "missing.jpg"
    }
    func releaseFirstCheck() { firstCheckGate.signal() }
}

@Test @MainActor func slowBatchFileValidationLeavesMainActorAvailableAndKeepsURLOrder() async throws {
    let counter = FileCheckCounter()
    defer { counter.releaseFirstCheck() }
    let urls = (0..<100).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        + [URL(fileURLWithPath: "/tmp/missing.jpg")]
    var finished = false
    let work = Task { @MainActor in
        let existing = try await FileActionResolver.existingURLs(urls, exists: counter.check)
        finished = true
        return existing
    }
    for _ in 0..<500 where counter.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    try #require(counter.count > 0)
    // Main actor can observe the worker while its first disk call is blocked;
    // unlike a 50ms sleep, this does not depend on concurrent test scheduling.
    #expect(!finished)
    #expect(!counter.ranOnMainThread)
    counter.releaseFirstCheck()
    #expect(try await work.value == Array(urls.dropLast()))
}

@Test @MainActor func cancelledBatchFileValidationStopsBeforeCheckingEveryURL() async throws {
    let counter = FileCheckCounter()
    defer { counter.releaseFirstCheck() }
    let urls = (0..<100).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
    let work = Task { try await FileActionResolver.existingURLs(urls, exists: counter.check) }
    for _ in 0..<500 where counter.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    try #require(counter.count > 0)
    work.cancel()
    counter.releaseFirstCheck()
    do {
        _ = try await work.value
        Issue.record("Cancelled file validation returned actionable URLs")
    } catch is CancellationError { }
    #expect(counter.count < urls.count)
    #expect(!counter.ranOnMainThread)
}
