import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

private func placementAsset(_ index: Int) -> LightboxAsset {
    LightboxAsset(id: "placement-\(index)", originalName: "\(index).jpg", width: 400,
        height: CGFloat(200 + index % 7 * 90), tags: [], addedAt: .distantPast,
        palette: MockPalette.imported[0])
}

@Test func masonryViewportLookupMatchesFullGeometryAtTenThousandAssets() {
    let assets = (0..<10_000).map(placementAsset)
    var columns = Array(repeating: [LightboxAsset](), count: 7)
    for (index, asset) in assets.enumerated() { columns[index % 7].append(asset) }
    let placement = GalleryMasonryPlacement(columns: columns, itemWidth: 180, spacing: 12, orderedAssets: assets)
    #expect(placement.frames.count == assets.count)
    #expect(placement.height > 100_000)
    for y: CGFloat in [-300, 0, 5_000, 30_000, placement.height - 700, placement.height + 100] {
        let rect = CGRect(x: 0, y: y, width: 1600, height: 900)
        let expected = assets.filter { placement.frames[$0.id]?.intersects(rect) == true }.map(\.id)
        let visible = placement.assets(intersecting: rect)
        #expect(visible.map(\.id) == expected)
        #expect(visible.count < 80)
    }
    #expect(placement.assets(intersecting: .zero).isEmpty)
    #expect(placement.assets(intersecting: CGRect(x: 2000, y: 0, width: 100, height: 900)).isEmpty)
}

@Test @MainActor func masonryPlacementInvalidatesForMetadataResizeAndReorder() {
    let cache = GalleryMasonryPlacementCache()
    var assets = [placementAsset(0), placementAsset(1)]
    func placement(_ revision: Int, width: CGFloat = 180) -> GalleryMasonryPlacement {
        cache.placement(identity: "active", revision: revision, columns: [assets], itemWidth: width, assets: assets)
    }
    let first = placement(1)
    assets[0].height *= 2
    let second = placement(2)
    #expect(second.frames[assets[1].id]!.minY > first.frames[assets[1].id]!.minY)
    let resized = placement(2, width: 360)
    #expect(resized.frames[assets[0].id]!.height == second.frames[assets[0].id]!.height * 2)
    assets.reverse()
    let reordered = placement(3)
    #expect(reordered.assets(intersecting: CGRect(x: 0, y: 0, width: 500, height: 1000)).map(\.id) == assets.map(\.id))
    cache.retain(identities: [])
    #expect(placement(3).frames == reordered.frames)
}

// Hidden native window: verify the real ScrollViewReader/keyboard path reaches
// an offscreen target while mounting only a viewport-sized portion of 2000 cards.
@Test
@MainActor func virtualMasonryKeyboardReachesOffscreenCardAndPreservesPreviewGeometry() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxMasonry-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxMasonry-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    let source = LibrarySource(id: "masonry", name: "Masonry", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    for _ in 0..<100 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(10)) }
    state.assets = (0..<2_000).map(placementAsset)
    state.thumbnailWidth = 206
    let host = NSHostingView(rootView: GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func cards(_ view: NSView) -> [AssetInteractionView] {
        (view as? AssetInteractionView).map { [$0] } ?? view.subviews.flatMap(cards)
    }
    for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    #expect(cards(host).count > 0 && cards(host).count < 100)
    let last = try #require(state.activeAssets.last)
    let penultimate = try #require(state.activeAssets.dropLast().last)
    state.galleryKeyboardFocusID = penultimate.id
    state.handleGalleryKey(124, modifiers: [], from: penultimate.id)
    for _ in 0..<50 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    let frame = try #require(state.previewSpaceFrame(for: last.id))
    #expect(frame.intersects(host.bounds))
    #expect(cards(host).contains { $0.debugTargetName == last.originalName })
    #expect(cards(host).count < 100)
}

@Test @MainActor func virtualMasonryKeyboardReachesOffscreenSearchGroup() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxMasonryGroups-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxMasonryGroups-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    for group in ["A", "B"] {
        let folder = work.appendingPathComponent(group)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<80 { try Data().write(to: folder.appendingPathComponent("\(group)-\(index).jpg")) }
    }
    let source = LibrarySource(id: "masonry-groups", name: "Groups", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    state.galleryLayoutMode = .recursive
    for _ in 0..<500 where state.activeAssets.count != 160 || state.searchStatus?.isSearching == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.activeAssets.count == 160 && state.searchAssetGroups.count == 2)
    let host = NSHostingView(rootView: GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    let last = try #require(state.activeAssets.last)
    let penultimate = try #require(state.activeAssets.dropLast().last)
    state.galleryKeyboardFocusID = penultimate.id
    state.handleGalleryKey(124, modifiers: [], from: penultimate.id)
    for _ in 0..<80 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    let frame = try #require(state.previewSpaceFrame(for: last.id))
    #expect(frame.intersects(host.bounds))
}

@MainActor private final class MasonryGeometryModel: ObservableObject {
    @Published var assets = (0..<3).map(placementAsset)
    var reportedFrames: [LightboxAsset.ID: CGRect] = [:]

    var placement: GalleryMasonryPlacement {
        GalleryMasonryPlacement(columns: [assets], itemWidth: 100, spacing: 12, orderedAssets: assets)
    }
}

private struct MasonryGeometryHost: View {
    @ObservedObject var model: MasonryGeometryModel

    var body: some View {
        let placement = model.placement
        ScrollView {
            VStack(spacing: 0) {
                GalleryVirtualMasonryGrid(placement: placement, width: 100, viewportHeight: 800,
                    isScaling: false, revealAssetIDs: [], framesChanged: { frames, _, _, _ in
                        model.reportedFrames = frames
                    }) { _ in Color.clear }
                    .frame(width: 100, height: placement.height)
            }
            .coordinateSpace(name: "GalleryContent")
        }
    }
}

// Reordering, metadata and identity changes can move cards without changing
// the grid's outer geometry. Preview and selection coordinates must follow.
@Test @MainActor func virtualMasonryUpdatesCoordinatesWhenOuterGeometryIsUnchanged() async throws {
    let model = MasonryGeometryModel()
    let host = NSHostingView(rootView: MasonryGeometryHost(model: model))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }

    func settle() async throws {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    try await settle()
    let originalHeight = model.placement.height
    #expect(model.reportedFrames == model.placement.frames)

    model.assets.reverse()
    try await settle()
    #expect(model.placement.height == originalHeight)
    #expect(model.reportedFrames == model.placement.frames)

    var updated = model.assets
    let firstHeight = updated[0].height
    updated[0].height = updated[1].height
    updated[1].height = firstHeight
    model.assets = updated
    try await settle()
    #expect(model.placement.height == originalHeight)
    #expect(model.reportedFrames == model.placement.frames)

    let removedID = updated[0].id
    let old = updated[0]
    updated[0] = LightboxAsset(id: "replacement", originalName: old.originalName,
        width: old.width, height: old.height, tags: old.tags,
        addedAt: old.addedAt, palette: old.palette)
    model.assets = updated
    try await settle()
    #expect(model.placement.height == originalHeight)
    #expect(model.reportedFrames == model.placement.frames)
    #expect(model.reportedFrames[removedID] == nil)
}
