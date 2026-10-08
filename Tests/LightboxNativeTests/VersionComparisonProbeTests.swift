import AppKit
import Darwin
import QuartzCore
import SwiftUI
import Testing
@testable import LightboxNative

// This measures application work and main-actor availability, not presented FPS.
// One outstanding pulse avoids adding a backlog while the main actor is blocked.
@MainActor private final class ComparisonPulse {
    private var task: Task<Void, Never>?
    private var queueDelays: [Double] = []
    private var wakeDelays: [Double] = []
    private var gaps: [Double] = []
    private var lastExecution = CACurrentMediaTime()
    private var measurementStart = CACurrentMediaTime()

    init() {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let deadline = CACurrentMediaTime() + 0.008
                do { try await Task.sleep(for: .milliseconds(8)) } catch { break }
                let enqueued = CACurrentMediaTime()
                await self?.record(enqueued: enqueued, deadline: deadline)
            }
        }
    }
    private func record(enqueued: Double, deadline: Double) {
        // An outstanding pulse may have queued during the preceding startup work.
        // Its old enqueue time must not enter the next phase after reset.
        guard enqueued >= measurementStart else { return }
        let now = CACurrentMediaTime()
        queueDelays.append((now - enqueued) * 1000)
        wakeDelays.append(max(0, enqueued - deadline) * 1000)
        gaps.append((now - lastExecution) * 1000)
        lastExecution = now
    }
    func reset() {
        queueDelays.removeAll(keepingCapacity: true)
        wakeDelays.removeAll(keepingCapacity: true)
        gaps.removeAll(keepingCapacity: true)
        lastExecution = CACurrentMediaTime()
        measurementStart = lastExecution
    }
    func finish() async -> [String: Double] {
        task?.cancel()
        await task?.value
        task = nil
        return [
            "pulse_samples": Double(queueDelays.count),
            "queue_p95_ms": comparisonPercentile(queueDelays, 0.95),
            "queue_p99_ms": comparisonPercentile(queueDelays, 0.99),
            "queue_max_ms": queueDelays.max() ?? 0,
            "queue_over_16.67ms": Double(queueDelays.filter { $0 > 16.67 }.count),
            "queue_over_33.33ms": Double(queueDelays.filter { $0 > 33.33 }.count),
            "queue_over_50ms": Double(queueDelays.filter { $0 > 50 }.count),
            "queue_over_100ms": Double(queueDelays.filter { $0 > 100 }.count),
            "producer_p95_ms": comparisonPercentile(wakeDelays, 0.95),
            "gap_max_ms": gaps.max() ?? 0,
            "unserved_8ms_intervals": Double(gaps.reduce(0) { $0 + max(0, Int($1 / 8) - 1) })
        ]
    }
}

private func comparisonPercentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * fraction)]
}

private func comparisonMemoryMetrics() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { return [:] }
    return ["footprint_mb": Double(info.phys_footprint) / 1_048_576,
        "footprint_peak_mb": Double(info.ledger_phys_footprint_peak) / 1_048_576]
}


@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_VERSION_PROBE_FOLDER"] != nil))
@MainActor func versionComparisonResponsivenessProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(env["LIGHTBOX_VERSION_PROBE_FOLDER"]))
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxVersion-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxVersion-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = original
    arguments["Lightbox.sidebar.collapsed"] = false
    arguments["Lightbox.sidebar.visibleLocationIDs"] = SidebarLocationID.allCases.map(\.rawValue)
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "version-probe", name: "Version probe", rootURL: root, kind: .external)
    let tab = LightboxTab(source: source, folderURL: root, layoutMode: .recursive)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    var state: AppState!
    var host: NSHostingView<AnyView>!
    var window: NSWindow!
    var report: [String: [String: Double]] = [:]
    var updates: [Double] = []
    var actions: [[String: Any]] = []

    func update(_ name: String? = nil, _ action: () -> Void = {}) {
        let start = CACurrentMediaTime()
        action()
        let changed = CACurrentMediaTime()
        host.layoutSubtreeIfNeeded()
        let end = CACurrentMediaTime()
        updates.append((end - start) * 1000)
        if let name {
            actions.append(["operation": name, "assets": state.activeAssets.count,
                "mutation_ms": (changed - start) * 1000,
                "layout_ms": (end - changed) * 1000, "update_ms": (end - start) * 1000])
        }
    }
    func phase(_ name: String, _ body: () async throws -> Void) async throws {
        updates = []
        let pulse = ComparisonPulse()
        try await Task.sleep(for: .milliseconds(20))
        pulse.reset()
        let start = CACurrentMediaTime()
        do { try await body() } catch { _ = await pulse.finish(); throw error }
        try await Task.sleep(for: .milliseconds(20))
        var metrics = await pulse.finish()
        metrics["wall_ms"] = (CACurrentMediaTime() - start) * 1000
        metrics["update_p95_ms"] = comparisonPercentile(updates, 0.95)
        metrics["update_max_ms"] = updates.max() ?? 0
        metrics["updates"] = Double(updates.count)
        metrics.merge(comparisonMemoryMetrics(), uniquingKeysWith: { _, new in new })
        report[name] = metrics
        print("VERSION_PERF \(name) \(metrics)")
    }
    func busy() -> Bool {
        let metadataPending = state.activeAssets.contains { !$0.metadataLoaded }
        #if LIGHTBOX_LEGACY_PROBE
        return state.searchStatus == nil || state.searchStatus?.isSearching == true
            || state.libraryLoadingStatus != nil || metadataPending
        #else
        return state.searchStatus == nil || state.searchStatus?.isSearching == true
            || state.searchStatus?.isLoadingMetadata == true || state.libraryLoadingStatus != nil || metadataPending
        #endif
    }
    func settle() async throws {
        let deadline = CACurrentMediaTime() + 180
        var idle: Double?
        repeat {
            update()
            try await Task.sleep(for: .milliseconds(8))
            if busy() { idle = nil } else if idle == nil { idle = CACurrentMediaTime() }
        } while CACurrentMediaTime() < deadline && (idle == nil || CACurrentMediaTime() - (idle ?? 0) < 0.5)
        #expect(!busy(), "Library did not finish within 180 seconds")
        #expect(!state.activeAssets.isEmpty)
    }
    try await phase("initial_load") {
        state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
        host = NSHostingView(rootView: AnyView(RootShellView().environmentObject(state)
            .background(WindowConfigurator(appState: state))))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2560, height: 1360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settle()
    }
    defer { window.close() }
    let expectedCount = state.activeAssets.count
    report["context"] = ["assets": Double(expectedCount), "metadata_ready": Double(state.activeAssets.filter(\.metadataLoaded).count), "groups": Double(state.searchAssetGroups.count),
        "folders": Double(state.activeFolderEntries.count),
        "screen_refresh_limit": Double(NSScreen.main?.maximumFramesPerSecond ?? 0)]
    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    for width: CGFloat in [206, 657] {
        update("width:\(width)") { state.thumbnailWidth = width }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try #require(scrolls(host).max { $0.bounds.width < $1.bounds.width })
        let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        try await phase("continuous_scroll_\(Int(width))") {
            for step in Array(0..<120) + Array((0..<120).reversed()) {
                update {
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maximum, CGFloat(step) * 180)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                try await Task.sleep(for: .milliseconds(8))
            }
        }
    }
    try await phase("preview") {
        let first = try #require(state.activeAssets.first)
        update("open") { state.showPreview(for: first, sourceFrame: state.previewSpaceFrame(for: first.id)) }
        for _ in 0..<40 { update(); try await Task.sleep(for: .milliseconds(8)) }
        for _ in 0..<12 { update("step") { state.stepPreview(.next) }; try await Task.sleep(for: .milliseconds(60)) }
        update("close") { _ = state.beginPreviewClose() }
        for _ in 0..<80 where state.previewAssetID != nil { update(); try await Task.sleep(for: .milliseconds(8)) }
        #expect(state.previewAssetID == nil)
    }
    try await phase("search_sort_filter") {
        for text in ["S", "S0", "S00", "S001", "", "B", "B-", ""] {
            update("search:\(text)") { state.searchText = text }
            try await Task.sleep(for: .milliseconds(100))
        }
        // 2.0.5 rescans when typing. Finish that work before comparing sort/filter.
        try await settle()
        for field in GallerySortField.allCases {
            update("sort:\(field.rawValue)") { state.setSortField(field) }
            try await Task.sleep(for: .milliseconds(100))
        }
        update("filter:Red") { state.selectedFilter = .tag("Red") }
        try await Task.sleep(for: .milliseconds(100))
        update("filter:all") { state.selectedFilter = .all }
        try await settle()
    }
    try await phase("cached_tabs") {
        let gallery = state.activeTabID
        update { state.newTab() }
        let empty = state.activeTabID
        for _ in 0..<6 {
            update("tab:gallery") { state.selectTab(gallery) }
            try await Task.sleep(for: .milliseconds(100))
            #expect(state.activeAssets.count == expectedCount)
            update("tab:empty") { state.selectTab(empty) }
            try await Task.sleep(for: .milliseconds(100))
        }
        update { state.selectTab(gallery); state.closeTab(empty) }
        try await settle()
    }
    let output = URL(fileURLWithPath: try #require(env["LIGHTBOX_VERSION_PROBE_REPORT"]))
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    try JSONSerialization.data(withJSONObject: actions, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.deletingPathExtension().appendingPathExtension("actions.json"))
}
