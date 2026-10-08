import AppKit
import Foundation
import Testing
@testable import LightboxNative

private final class DirectoryCheckObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var main = false
    func check(_ url: URL) -> Bool {
        lock.withLock { main = Thread.isMainThread }
        return true
    }
    var wasMain: Bool { lock.withLock { main } }
}

private final class SlowDirectoryCheck: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var main = false
    var started: Bool { lock.withLock { calls > 0 } }
    var count: Int { lock.withLock { calls } }
    var wasMain: Bool { lock.withLock { main } }
    func check(_ url: URL) -> Bool {
        lock.withLock { main = main || Thread.isMainThread }
        if url.lastPathComponent == "slow" {
            lock.withLock { calls += 1 }
            _ = gate.wait(timeout: .now() + 5)
        }
        return DirectoryAccessResolver.isDirectory(url)
    }
    func release() { gate.signal() }
}

@MainActor private struct DirectoryResponseFixture {
    let work: URL
    let slow: URL
    let fast: URL
    let defaults: UserDefaults
    let suite: String
    let state: AppState
    init(probe: @escaping @Sendable (URL) -> Bool = DirectoryAccessResolver.isDirectory,
         sidebarLoader: @escaping @Sendable (Set<SidebarLocationID>) -> SidebarDestinationSnapshot = {
             SidebarDestinationSnapshot.load(visibleLocationIDs: $0)
         }) throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxDirectoryResponse-\(UUID())")
        slow = work.appendingPathComponent("slow")
        fast = work.appendingPathComponent("fast")
        try FileManager.default.createDirectory(at: slow, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fast, withIntermediateDirectories: true)
        suite = "LightboxDirectoryResponse-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        let source = LibrarySource(id: "directory-response", name: "Directory", rootURL: work, kind: .external)
        let tab = LightboxTab(source: source, folderURL: work)
        LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
        state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"),
                         libraryDefaults: defaults, directoryProbe: probe,
                         sidebarDestinationLoader: sidebarLoader)
    }
    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
}

@MainActor private func waitForDirectoryCondition(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}

@Test @MainActor func directoryValidationDoesNotReadStorageOnMainThread() async throws {
    let observation = DirectoryCheckObservation()
    #expect(try await DirectoryAccessResolver.existingDirectory(
        URL(fileURLWithPath: "/tmp"), probe: observation.check))
    #expect(!observation.wasMain)
}

@Test @MainActor func goToFolderValidationDoesNotReadStorageOnMainThread() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxDirectoryResponse-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxDirectoryResponse-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let observation = DirectoryCheckObservation()
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"),
                         libraryDefaults: defaults, directoryProbe: observation.check)
    #expect(await state.openFolderPath(work.path) == .opened)
    #expect(!observation.wasMain)
}

@Test @MainActor func slowFolderPathCannotOverwriteNewerNavigation() async throws {
    let control = SlowDirectoryCheck()
    let fixture = try DirectoryResponseFixture(probe: control.check)
    defer { control.release(); fixture.clean() }
    let old = Task { await fixture.state.openFolderPath("slow") }
    try await waitForDirectoryCondition { control.started }
    #expect(!control.wasMain)
    #expect(fixture.state.currentFolderURL.path == fixture.work.path)
    #expect(await fixture.state.openFolderPath("fast") == .opened)
    #expect(fixture.state.currentFolderURL.path == fixture.fast.path)
    control.release()
    #expect(await old.value == .cancelled)
    #expect(fixture.state.currentFolderURL.path == fixture.fast.path)
}

@Test @MainActor func cancelledFolderPathDoesNotNavigateWhenStorageReturns() async throws {
    let control = SlowDirectoryCheck()
    let fixture = try DirectoryResponseFixture(probe: control.check)
    defer { control.release(); fixture.clean() }
    let old = Task { await fixture.state.openFolderPath("slow") }
    try await waitForDirectoryCondition { control.started }
    fixture.state.cancelPendingFolderPath()
    control.release()
    #expect(await old.value == .cancelled)
    #expect(fixture.state.currentFolderURL.path == fixture.work.path)
    #expect(!control.wasMain)
}

@Test @MainActor func folderPathValidationCannotOpenInAnotherTab() async throws {
    let control = SlowDirectoryCheck()
    let fixture = try DirectoryResponseFixture(probe: control.check)
    defer { control.release(); fixture.clean() }
    let old = Task { await fixture.state.openFolderPath("slow") }
    try await waitForDirectoryCondition { control.started }
    fixture.state.newTab()
    let tabID = fixture.state.activeTabID
    control.release()
    #expect(await old.value == .cancelled)
    #expect(fixture.state.activeTabID == tabID && fixture.state.isShowingStartPage)
}

@Test @MainActor func slowPinKeepsSubmittedFolderAndCoalescesDuplicates() async throws {
    let control = SlowDirectoryCheck()
    let fixture = try DirectoryResponseFixture(probe: control.check)
    defer { control.release(); fixture.clean() }
    fixture.state.currentFolderURL = fixture.slow
    fixture.state.pinCurrentPath()
    fixture.state.pinCurrentPath()
    try await waitForDirectoryCondition { control.started }
    #expect(!control.wasMain && control.count == 1)
    fixture.state.currentFolderURL = fixture.fast
    control.release()
    try await waitForDirectoryCondition { fixture.state.isFolderPinned(fixture.slow) }
    #expect(!fixture.state.isFolderPinned(fixture.fast))
    #expect(fixture.state.sources.filter { $0.rootURL.path == fixture.slow.path }.count == 1)
    #expect(fixture.state.currentFolderURL == fixture.fast)
}

@Test @MainActor func unpinCancelsAnEarlierPendingPinForTheSameFolder() async throws {
    let control = SlowDirectoryCheck()
    let fixture = try DirectoryResponseFixture(probe: control.check)
    defer { control.release(); fixture.clean() }
    fixture.state.currentFolderURL = fixture.slow
    fixture.state.pinCurrentPath()
    try await waitForDirectoryCondition { control.started }
    let source = LibrarySourceStore.makeExternalSource(rootURL: fixture.slow)
    fixture.state.pinSource(source, selectPinnedFolder: false)
    fixture.state.unpinSource(source.id)
    control.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!fixture.state.isFolderPinned(fixture.slow))
}

@Test @MainActor func cancelledNativePathSubmissionDoesNotShowAnUnavailableError() async throws {
    let control = SlowDirectoryCheck()
    let fixture = try DirectoryResponseFixture(probe: control.check)
    defer { control.release(); fixture.clean() }
    let header = NativeNavigationBar(appState: fixture.state)
    header.frame = CGRect(x: 0, y: 0, width: 1100, height: 52)
    fixture.state.focusGoToFolder()
    header.refresh()
    let editor = try #require(header.subviews.compactMap { $0 as? NSTextField }
        .first { $0.isEditable && !$0.isHidden })
    editor.stringValue = fixture.slow.path
    #expect(header.control(editor, textView: NSTextView(),
                           doCommandBy: #selector(NSResponder.insertNewline(_:))))
    try await waitForDirectoryCondition { control.started }
    // Another navigation command cancels the submission even if the folder
    // and editing text happen to remain the same.
    fixture.state.cancelPendingFolderPath()
    control.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(editor.textColor != .systemRed)
    #expect(editor.toolTip == nil)
    #expect(fixture.state.currentFolderURL.path == fixture.work.path)
}

private final class SlowSidebarSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var main = false
    var count: Int { lock.withLock { calls } }
    var wasMain: Bool { lock.withLock { main } }
    func load(_ visible: Set<SidebarLocationID>) -> SidebarDestinationSnapshot {
        let first = lock.withLock { calls += 1; main = main || Thread.isMainThread; return calls == 1 }
        if first {
            _ = gate.wait(timeout: .now() + 5)
            return SidebarDestinationSnapshot(locations: [.desktop],
                volumes: [SidebarVolume(url: URL(fileURLWithPath: "/Volumes/stale"), displayName: "Stale")],
                locationDirectories: [.desktop: SidebarDirectoryIdentity(url: URL(fileURLWithPath: "/stale/Desktop", isDirectory: true))])
        }
        return SidebarDestinationSnapshot(locations: [], volumes: [])
    }
    func release() { gate.signal() }
}

@Test @MainActor func obsoleteSidebarSnapshotCannotPublishAfterVisibilityChange() async throws {
    let previousVisibleLocations = LightboxSettingsStore.loadSidebarVisibleLocationIDs()
    defer { LightboxSettingsStore.saveSidebarVisibleLocationIDs(previousVisibleLocations) }
    let control = SlowSidebarSnapshot()
    let fixture = try DirectoryResponseFixture(sidebarLoader: control.load)
    defer { control.release(); fixture.clean() }
    try await waitForDirectoryCondition { control.count == 1 }
    #expect(!control.wasMain)
    fixture.state.sidebarVisibleLocationIDs = []
    try await waitForDirectoryCondition { control.count == 2 }
    control.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.state.sidebarLocations.isEmpty)
    #expect(fixture.state.sidebarVolumes.isEmpty)
    #expect(fixture.state.sidebarLocationDirectories.isEmpty)
}
