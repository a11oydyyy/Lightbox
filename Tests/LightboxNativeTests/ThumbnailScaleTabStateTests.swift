import Combine
import Foundation
import Testing
@testable import LightboxNative

@Test @MainActor func sliderDragCapturesTabThumbnailWidthOnRelease() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxScaleTab-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let suite = "LightboxScaleTab-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    let source = LibrarySource(id: "scale-tab", name: "Scale", rootURL: folder, kind: .external)
    let tab = LightboxTab(source: source, folderURL: folder)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: folder.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    await waitWhile { state.libraryLoadingStatus != nil }

    // A width change outside a drag is captured immediately.
    state.thumbnailWidth = 240
    #expect(state.tabs.first?.thumbnailWidth == 240)

    // Slider ticks reach the gallery through the scale state only.
    var appStateChanges = 0
    var scaleChanges = 0
    let appStateObserver = state.objectWillChange.sink { appStateChanges += 1 }
    let scaleObserver = state.thumbnailScale.objectWillChange.sink { scaleChanges += 1 }
    defer { appStateObserver.cancel(); scaleObserver.cancel() }

    // During a drag, `tabs` stays untouched until release.
    state.isScalingThumbnails = true
    for width in stride(from: 250, through: 320, by: 10) {
        state.thumbnailWidth = CGFloat(width)
    }
    #expect(state.tabs.first?.thumbnailWidth == 240)
    #expect(appStateChanges == 0)
    #expect(scaleChanges == 9)
    state.isScalingThumbnails = false
    #expect(state.tabs.first?.thumbnailWidth == 320)
    // Releasing publishes the drag end, plus one app-state change for `tabs`.
    #expect(scaleChanges == 10)
    #expect(appStateChanges == 1)
}

// The slider's end dots: each step lands on exactly one more or one fewer column.
@Test func thumbnailColumnStepsLandOnWholeColumns() {
    for available in [640.0, 1_120.0, 1_533.0] as [CGFloat] {
        var width: CGFloat = 206
        let start = GalleryThumbnailSizing.columns(forWidth: width, availableWidth: available)
        for step in 1...3 {
            guard let next = GalleryThumbnailSizing.width(forColumns: start + step, availableWidth: available) else { break }
            width = next
            #expect(GalleryThumbnailSizing.columns(forWidth: width, availableWidth: available) == start + step)
        }
    }
    // Never below two columns, never under the minimum width.
    #expect(GalleryThumbnailSizing.width(forColumns: 1, availableWidth: 1_000) == nil)
    #expect(GalleryThumbnailSizing.width(forColumns: 40, availableWidth: 1_000) == nil)
}

@MainActor
@Test func stepThumbnailColumnsMovesTheGridOneColumn() throws {
    let suite = "LightboxColumnStep-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxColumnStep-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    state.thumbnailScale.galleryAvailableWidth = 1_200
    state.thumbnailWidth = 240
    let before = GalleryThumbnailSizing.columns(forWidth: state.thumbnailWidth, availableWidth: 1_200)
    #expect(state.stepThumbnailColumns(by: 1))
    #expect(GalleryThumbnailSizing.columns(forWidth: state.thumbnailWidth, availableWidth: 1_200) == before + 1)
    #expect(state.stepThumbnailColumns(by: -1))
    #expect(GalleryThumbnailSizing.columns(forWidth: state.thumbnailWidth, availableWidth: 1_200) == before)
    // The list has no columns to step.
    state.galleryViewMode = GalleryViewMode.list
    #expect(!state.stepThumbnailColumns(by: 1))
}
