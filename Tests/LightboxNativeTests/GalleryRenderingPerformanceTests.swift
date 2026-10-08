import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

// Opt-in native rendering probe. These are main-thread update timings, not
// display FPS; keeping it separate avoids load-dependent unit-test failures.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_RUN_RENDER_PROBE"] == "1"))
@MainActor func galleryNativeRenderingProbe() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxRender-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let suite = "LightboxRender-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    let source = LibrarySource(id: "render", name: "Render", rootURL: folder, kind: .external)
    let tab = LightboxTab(source: source, folderURL: folder)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: folder.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    for _ in 0..<100 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(state.libraryLoadingStatus == nil)
    state.assets = (0..<2_000).map { index in
        LightboxAsset(id: "render-\(index)", originalName: "\(index).jpg", width: 400,
            height: CGFloat(240 + index % 5 * 80), tags: [], addedAt: .distantPast,
            palette: MockPalette.imported[index % MockPalette.imported.count])
    }
    let host = NSHostingView(rootView: GalleryView(isResizingSidebar: false)
        .environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }
    let scroll = try #require(findScroll(host))
    func cards(in view: NSView) -> [AssetInteractionView] {
        (view as? AssetInteractionView).map { [$0] } ?? view.subviews.flatMap { cards(in: $0) }
    }
    func assertVisibleCardGeometry() {
        for card in cards(in: host) where card.debugSurface == "gallery-card" && !card.isHiddenOrHasHiddenAncestor {
            let frame = card.convert(card.bounds, to: host)
            guard frame.width > 1, frame.height > 1, frame.intersects(host.bounds),
                  let asset = state.activeAssets.first(where: { $0.originalName == card.debugTargetName }) else { continue }
            #expect(state.previewSpaceFrame(for: asset.id) != nil, "Visible card lost geometry: \(asset.id)")
        }
    }
    let clock = ContinuousClock()
    var scrollTimes: [Double] = []
    var scaleTimes: [Double] = []
    for step in 0..<100 {
        let start = clock.now
        scroll.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(step * 24)))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        scrollTimes.append(milliseconds(start.duration(to: clock.now)))
        try await Task.sleep(for: .milliseconds(8))
        assertVisibleCardGeometry()
    }
    state.isScalingThumbnails = true
    for step in 0..<80 {
        let start = clock.now
        state.thumbnailWidth = CGFloat(160 + step * 2)
        host.layoutSubtreeIfNeeded()
        scaleTimes.append(milliseconds(start.duration(to: clock.now)))
        try await Task.sleep(for: .milliseconds(8))
        assertVisibleCardGeometry()
    }
    state.isScalingThumbnails = false
    func stats(_ samples: [Double]) -> String {
        let values = samples.sorted()
        return "median_ms=\(values[values.count / 2]) p95_ms=\(values[Int(Double(values.count - 1) * 0.95)]) max_ms=\(values.last!)"
    }
    print("RENDER_PROBE scroll assets=2000 \(stats(scrollTimes))")
    print("RENDER_PROBE scale assets=2000 \(stats(scaleTimes))")
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

// Read-only, opt-in probe of the user's actual library. Reports update cost and
// main-actor scheduling gaps, not compositor FPS. The index lives in a temp folder.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_GALLERY_PROBE_FOLDER"] != nil))
@MainActor func galleryRealLibraryRenderingProbe() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIGHTBOX_GALLERY_PROBE_FOLDER"]))
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxRealRender-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxRealRender-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    let source = LibrarySource(id: "real-render", name: "Render", rootURL: root, kind: .external)
    let tab = LightboxTab(source: source, folderURL: root)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let clock = ContinuousClock()
    let loadingStart = clock.now
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    state.thumbnailWidth = 206
    for _ in 0..<500 where state.libraryLoadingStatus != nil || state.assets.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!state.assets.isEmpty && state.libraryLoadingStatus == nil)
    let scanMilliseconds = milliseconds(loadingStart.duration(to: clock.now))
    for _ in 0..<500 where state.assets.contains(where: { !$0.metadataLoaded }) { try await Task.sleep(for: .milliseconds(10)) }
    let metadataMilliseconds = milliseconds(loadingStart.duration(to: clock.now))
    let host = NSHostingView(rootView: GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2320, height: 1360),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .seconds(1))
    func findScroll(_ view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScroll).first
    }
    let scroll = try #require(findScroll(host))
    let maxOffset = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
    func stats(_ samples: [Double]) -> String {
        let values = samples.sorted()
        return "median_ms=\(values[values.count / 2]) p95_ms=\(values[Int(Double(values.count - 1) * 0.95)]) max_ms=\(values.last!) over_16.7ms=\(values.filter { $0 > 16.7 }.count)/\(values.count)"
    }
    for pass in 0..<2 {
        var updateTimes: [Double] = []
        var cadenceTimes: [Double] = []
        var previous = clock.now
        for step in 0..<240 {
            let start = clock.now
            cadenceTimes.append(milliseconds(previous.duration(to: start)))
            previous = start
            let fraction = Double(step < 120 ? step : 239 - step) / 119
            scroll.contentView.scroll(to: CGPoint(x: 0, y: maxOffset * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            updateTimes.append(milliseconds(start.duration(to: clock.now)))
            try await Task.sleep(for: .milliseconds(8))
        }
        print("REAL_RENDER pass=\(pass) assets=\(state.assets.count) mounted_cards=\(cardCount(host)) update \(stats(updateTimes)) cadence \(stats(Array(cadenceTimes.dropFirst())))")
    }
    print("REAL_LOAD scan_ms=\(scanMilliseconds) metadata_ms=\(metadataMilliseconds) refresh_limit=\(NSScreen.main?.maximumFramesPerSecond ?? 0)")
}

@MainActor private func cardCount(_ view: NSView) -> Int {
    if let card = view as? AssetInteractionView, card.debugSurface == "gallery-card" { return 1 }
    return view.subviews.reduce(0) { $0 + cardCount($1) }
}
