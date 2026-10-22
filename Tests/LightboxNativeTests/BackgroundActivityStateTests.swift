import Combine
import Foundation
import Testing
@testable import LightboxNative

@MainActor
@Test func scanProgressTicksPublishOnlyToTheActivityState() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxActivity-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxActivity-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "activity", name: "Activity", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    await waitWhile { state.libraryLoadingStatus != nil }

    var appStateChanges = 0
    var activityChanges = 0
    let appStateObserver = state.objectWillChange.sink { appStateChanges += 1 }
    let activityObserver = state.activity.objectWillChange.sink { activityChanges += 1 }
    defer { appStateObserver.cancel(); activityObserver.cancel() }

    state.libraryLoadingStatus = .init(phase: .preparingPreviews, processed: 0, total: 50)
    #expect(appStateChanges == 1)
    for processed in 1...50 {
        state.libraryLoadingStatus = .init(phase: .preparingPreviews, processed: processed, total: 50)
    }
    // Ticks reach the header through the activity state only.
    #expect(appStateChanges == 1)
    #expect(activityChanges == 51)
    #expect(state.libraryLoadingStatus?.processed == 50)

    state.libraryLoadingStatus = nil
    #expect(appStateChanges == 2)
    #expect(state.activity.loadingStatus == nil)
}
