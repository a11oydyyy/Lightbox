import Foundation
import Testing
@testable import LightboxNative

private final class StorageClassificationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var mainCalls = 0
    func classify(_ source: LibrarySource) -> Bool {
        lock.withLock {
            calls += 1
            if Thread.isMainThread { mainCalls += 1 }
        }
        return true
    }
    var count: Int { lock.withLock { calls } }
    var mainCount: Int { lock.withLock { mainCalls } }
}

@Test @MainActor func sourceStorageClassificationDoesNotReadDiskOnMainThread() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxStorageClassification-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxStorageClassification-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "storage-classification", name: "Photos", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let observation = StorageClassificationObservation()
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"),
                         libraryDefaults: defaults, storageClassifier: observation.classify)
    for _ in 0..<500 where state.libraryLoadingStatus != nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(observation.count > 0)
    #expect(observation.mainCount == 0)
}

private final class SlowStorageClassification: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var completedFirst = false
    private var mainCalls = 0
    var count: Int { lock.withLock { calls } }
    var firstCompleted: Bool { lock.withLock { completedFirst } }
    var mainCount: Int { lock.withLock { mainCalls } }
    func classify(_ source: LibrarySource) -> Bool {
        let call = lock.withLock {
            calls += 1
            if Thread.isMainThread { mainCalls += 1 }
            return calls
        }
        if call == 1 {
            _ = gate.wait(timeout: .now() + 5)
            lock.withLock { completedFirst = true }
            return false
        }
        return true
    }
    func release() { gate.signal() }
}

private final class MonitorConstructionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var constructions = 0
    private let failsFirst: Bool
    private var failedOpens = 0
    init(failsFirst: Bool = false) { self.failsFirst = failsFirst }
    var count: Int { lock.withLock { constructions } }
    var failures: Int { lock.withLock { failedOpens } }
    func make(_ url: URL, recursive: Bool) -> DirectoryChangeMonitor {
        let count = lock.withLock { constructions += 1; return constructions }
        if failsFirst && count == 1 {
            return DirectoryChangeMonitor(url: url, recursive: recursive, openDirectory: { [self] _ in
                lock.withLock { failedOpens += 1 }
                return -1
            })
        }
        return DirectoryChangeMonitor(url: url, recursive: recursive)
    }
}

@Test @MainActor func failedLocalMonitorCanReattachAfterExplicitRefresh() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxRetryMonitor-\(UUID())")
    let photos = work.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    let suite = "LightboxRetryMonitor-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "retry-monitor", name: "Photos", rootURL: photos, kind: .external)
    let tab = LightboxTab(source: source, folderURL: photos)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let observation = MonitorConstructionObservation(failsFirst: true)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"),
                         libraryDefaults: defaults, storageClassifier: { _ in false },
                         directoryMonitorFactory: observation.make)
    for _ in 0..<500 where state.libraryLoadingStatus != nil || observation.failures == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(observation.failures == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(observation.count == 1) // Failure must not cause an automatic retry loop.
    state.refreshLibrary()
    for _ in 0..<500 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(5)) }
    try #require(state.libraryLoadingStatus == nil && observation.count == 2)
    try Data().write(to: photos.appendingPathComponent("after-retry.png"))
    for _ in 0..<500 where !state.assets.contains(where: { $0.originalName == "after-retry.png" }) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.assets.contains { $0.originalName == "after-retry.png" })
}

@Test @MainActor func localStorageClassificationInstallsAndReusesWorkingDirectoryMonitor() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxLocalStorage-\(UUID())")
    let photos = work.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    let suite = "LightboxLocalStorage-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "local-storage", name: "Photos", rootURL: photos, kind: .external)
    let tab = LightboxTab(source: source, folderURL: photos)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let observation = MonitorConstructionObservation()
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"),
                         libraryDefaults: defaults, storageClassifier: { _ in false },
                         directoryMonitorFactory: observation.make)
    for _ in 0..<500 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(5)) }
    try #require(state.libraryLoadingStatus == nil && observation.count == 1)
    #expect(!state.selectedSourceUsesConservativeExternalLoading)
    for _ in 0..<3 {
        state.refreshLibrary()
        for _ in 0..<500 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(state.libraryLoadingStatus == nil)
    }
    #expect(observation.count == 1)
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aO1sAAAAASUVORK5CYII="))
    try png.write(to: photos.appendingPathComponent("new.png"))
    for _ in 0..<500 where !state.assets.contains(where: { $0.originalName == "new.png" }) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.assets.contains { $0.originalName == "new.png" })
    #expect(observation.count == 1)
}

@Test @MainActor func slowStorageClassificationKeepsUIResponsiveAndDropsCancelledResult() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxSlowStorage-\(UUID())")
    let photos = work.appendingPathComponent("photos")
    let fast = photos.appendingPathComponent("fast")
    try FileManager.default.createDirectory(at: fast, withIntermediateDirectories: true)
    let suite = "LightboxSlowStorage-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let control = SlowStorageClassification()
    defer {
        control.release()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "slow-storage", name: "Photos", rootURL: photos, kind: .external)
    let tab = LightboxTab(source: source, folderURL: photos)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"),
                         libraryDefaults: defaults, storageClassifier: control.classify)
    for _ in 0..<500 where control.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    try #require(control.count == 1 && !control.firstCompleted)
    #expect(control.mainCount == 0)
    #expect(state.selectedSourceUsesConservativeExternalLoading)
    // This main-actor interaction must finish while the old disk call is blocked.
    state.currentFolderURL = fast
    state.refreshLibrary()
    for _ in 0..<500 where control.count < 2 || state.libraryLoadingStatus != nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(control.count >= 2 && state.libraryLoadingStatus == nil)
    #expect(state.currentFolderURL == fast && !control.firstCompleted)
    control.release()
    for _ in 0..<500 where !control.firstCompleted { try await Task.sleep(for: .milliseconds(5)) }
    try #require(control.firstCompleted)
    // Let any rejected main-actor publication run before checking the current policy.
    try await Task.sleep(for: .milliseconds(20))
    #expect(state.selectedSourceUsesConservativeExternalLoading)
    #expect(state.currentFolderURL == fast && control.mainCount == 0)
}
