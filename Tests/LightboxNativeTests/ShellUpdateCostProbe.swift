import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

// Opt-in probe: main-thread cost of frequent AppState changes in the real
// window (sidebar, header and gallery), with the sidebar open and closed.
// LIGHTBOX_RUN_SHELL_PROBE=1 swift test -c release -Xswiftc -enable-testing --filter shellUpdateCostProbe
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_RUN_SHELL_PROBE"] == "1"))
@MainActor func shellUpdateCostProbe() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxShellProbe-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxShellProbe-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    var tabs: [LightboxTab] = []
    for index in 0..<12 {
        let folder = work.appendingPathComponent("Folder \(index)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = LibrarySource(id: "probe-\(index)", name: "Folder \(index)", rootURL: folder, kind: .external)
        tabs.append(LightboxTab(source: source, folderURL: folder))
    }
    LightboxTabStore.save(tabs: tabs, activeTabID: tabs[0].id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    state.sidebarVisibleLocationIDs.remove(.volumes)
    await waitWhile { state.libraryLoadingStatus != nil }
    state.assets = (0..<2_000).map { index in
        LightboxAsset(id: "probe-\(index)", originalName: "\(index).jpg", width: 400,
                      height: CGFloat(240 + index % 5 * 80), tags: [], addedAt: .distantPast,
                      palette: MockPalette.imported[index % MockPalette.imported.count])
    }

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    let host = NSHostingView(rootView: RootShellView()
        .environmentObject(state)
        .background(WindowConfigurator(appState: state)))
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }

    func settle() async throws {
        for _ in 0..<10 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func measure(_ name: String, steps: Int = 60, _ change: (Int) -> Void) async throws -> Double {
        var samples: [Double] = []
        for step in 0..<steps {
            let start = ContinuousClock.now
            change(step)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            try await Task.sleep(for: .milliseconds(4))
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        print("SHELL_PROBE \(name) median_ms=\(String(format: "%.2f", median)) p95_ms=\(String(format: "%.2f", p95))")
        return median
    }

    // Pure fan-out: one objectWillChange with nothing changed, per surface.
    _ = try await measure("window noop-publish") { _ in state.objectWillChange.send() }
    for (name, view) in [
        ("sidebar-only", AnyView(SidebarHostedContent(appState: state))),
        ("gallery-only", AnyView(GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))),
    ] {
        let isolated = NSWindow(contentRect: CGRect(x: 0, y: 0, width: name == "sidebar-only" ? 300 : 1100, height: 900),
                                styleMask: .borderless, backing: .buffered, defer: false)
        isolated.isReleasedWhenClosed = false
        isolated.contentView = NSHostingView(rootView: view)
        for _ in 0..<10 { isolated.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        var samples: [Double] = []
        for _ in 0..<60 {
            let start = ContinuousClock.now
            state.objectWillChange.send()
            isolated.contentView?.layoutSubtreeIfNeeded()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            try await Task.sleep(for: .milliseconds(4))
        }
        samples.sort()
        print("SHELL_PROBE \(name) noop-publish median_ms=\(String(format: "%.2f", samples[30]))")
        isolated.close()
    }

    for collapsed in [false, true] {
        state.sidebarCollapsed = collapsed
        try await settle()
        let label = collapsed ? "sidebar-closed" : "sidebar-open"
        state.isScalingThumbnails = true
        _ = try await measure("\(label) slider-tick") { state.thumbnailWidth = CGFloat(200 + $0 % 40) }
        state.isScalingThumbnails = false
        try await settle()
        let ids = state.activeAssets.prefix(60).map(\.id)
        _ = try await measure("\(label) select-one") { state.replaceSelection(with: [ids[$0]]) }
        state.clearSelection()
        try await settle()
        _ = try await measure("\(label) keyboard-focus") { state.galleryKeyboardFocusID = ids[$0] }
        state.galleryKeyboardFocusID = nil
        try await settle()
        _ = try await measure("\(label) scan-progress") {
            state.libraryLoadingStatus = .init(phase: .preparingPreviews, processed: $0, total: 60)
        }
        state.libraryLoadingStatus = nil
        try await settle()
    }

    // Preview: arrow-key steps while open, and the first frame of open/close.
    state.sidebarCollapsed = false
    try await settle()
    let first = try #require(state.activeAssets.first)
    state.showPreview(for: first)
    try await Task.sleep(for: MotionTokens.previewGeometryDuration)
    try await settle()
    _ = try await measure("preview-step", steps: 40) { _ in state.stepPreview(.next) }
    state.closePreview()
    try await settle()
    _ = try await measure("preview-open-close", steps: 30) { step in
        if step.isMultiple(of: 2) { state.showPreview(for: first) } else { state.closePreview() }
    }
    state.closePreview()
}
