import AppKit
import Darwin
import QuartzCore
import SwiftUI
import Testing
@testable import LightboxNative

// This measures application work and main-actor availability, not presented FPS.
// One outstanding pulse avoids adding a backlog while the main actor is blocked.
@MainActor private final class ResponsivenessPulse {
    private var task: Task<Void, Never>?
    private var queueDelays: [Double] = []
    private var wakeDelays: [Double] = []
    private var gaps: [Double] = []
    private var lastExecution = CACurrentMediaTime()
    private var measurementStart = CACurrentMediaTime()
    private let recordsEvents: Bool
    private(set) var events: [[String: Double]] = []

    init(recordsEvents: Bool = false) {
        self.recordsEvents = recordsEvents
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
        if recordsEvents, now - enqueued > 0.033 {
            events.append(["enqueued_at": enqueued, "served_at": now, "delay_ms": (now - enqueued) * 1000])
        }
        wakeDelays.append(max(0, enqueued - deadline) * 1000)
        gaps.append((now - lastExecution) * 1000)
        lastExecution = now
    }
    func reset() {
        queueDelays.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
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
            "queue_p95_ms": percentile(queueDelays, 0.95),
            "queue_p99_ms": percentile(queueDelays, 0.99),
            "queue_max_ms": queueDelays.max() ?? 0,
            "queue_over_16.67ms": Double(queueDelays.filter { $0 > 16.67 }.count),
            "queue_over_33.33ms": Double(queueDelays.filter { $0 > 33.33 }.count),
            "queue_over_50ms": Double(queueDelays.filter { $0 > 50 }.count),
            "queue_over_100ms": Double(queueDelays.filter { $0 > 100 }.count),
            "producer_p95_ms": percentile(wakeDelays, 0.95),
            "gap_max_ms": gaps.max() ?? 0,
            "unserved_8ms_intervals": Double(gaps.reduce(0) { $0 + max(0, Int($1 / 8) - 1) })
        ]
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * fraction)]
}

private func processMemoryMetrics() -> [String: Double] {
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_INTERACTION_PROBE_FOLDER"] != nil))
@MainActor func applicationInteractionResponsivenessProbe() async throws {
    let environment = ProcessInfo.processInfo.environment
    let recursiveProbe = environment["LIGHTBOX_INTERACTION_PROBE_RECURSIVE"] == "1"
    let root = URL(fileURLWithPath: try #require(environment["LIGHTBOX_INTERACTION_PROBE_FOLDER"]))
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxInteraction-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxInteraction-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let originalSidebarCollapsed = LightboxSettingsStore.loadSidebarCollapsed()
    let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var controlledArguments = originalArguments
    controlledArguments["Lightbox.sidebar.visibleLocationIDs"] = SidebarLocationID.allCases.map(\.rawValue)
    if environment["LIGHTBOX_INTERACTION_PROBE_HIDE_FOLDERS"] == "1" {
        controlledArguments["Lightbox.gallery.showFolderCards"] = false
    }
    UserDefaults.standard.setVolatileDomain(controlledArguments, forName: UserDefaults.argumentDomain)
    defer {
        UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        LightboxSettingsStore.saveSidebarCollapsed(originalSidebarCollapsed)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "interaction", name: "Interaction", rootURL: root, kind: .external)
    let tab = LightboxTab(source: source, folderURL: root, layoutMode: recursiveProbe ? .recursive : .masonry)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    var state: AppState!
    var host: NSHostingView<AnyView>!
    var window: NSWindow!
    var report: [String: [String: Double]] = [:]
    var updates: [Double] = []
    var initialSteps: [String: Double] = [:]
    var queueEvents: [String: [[String: Double]]] = [:]
    // Optional attribution run only; never compare sampled runs with baseline timings.
    let sampler = Process()
    let samplePhase = environment["LIGHTBOX_INTERACTION_SAMPLE_PHASE"]
    func startSampler(seconds: Int) throws {
        guard let samplePath = environment["LIGHTBOX_INTERACTION_SAMPLE_REPORT"] else { return }
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(seconds), "1", "-file", samplePath]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        try sampler.run()
    }
    if samplePhase != "resize" && samplePhase != "search" && samplePhase != "tabs" && samplePhase != "continuous" && samplePhase != "scan" && samplePhase != "navigation" { try startSampler(seconds: 12) }
    defer { if sampler.isRunning { sampler.terminate() } }
    func finishPhaseSampler() async throws {
        // Keep later interactions out of a phase-specific CPU sample. Idle waiting
        // is outside the measured phase and does not block the main actor.
        while sampler.isRunning { try await Task.sleep(for: .milliseconds(25)) }
    }

    func initialStep(_ label: String, _ action: () -> Void) {
        let start = CACurrentMediaTime()
        action()
        initialSteps[label] = (CACurrentMediaTime() - start) * 1000
    }

    func update(_ action: () -> Void = {}) {
        let start = CACurrentMediaTime()
        action()
        host.layoutSubtreeIfNeeded()
        updates.append((CACurrentMediaTime() - start) * 1000)
    }
    func phase(_ label: String, _ body: () async throws -> Void) async throws {
        updates.removeAll(keepingCapacity: true)
        let pulse = ResponsivenessPulse(recordsEvents: environment["LIGHTBOX_INTERACTION_PROBE_ACTIONS"] == "1")
        try await Task.sleep(for: .milliseconds(16))
        pulse.reset()
        let start = CACurrentMediaTime()
        do { try await body() }
        catch { _ = await pulse.finish(); throw error }
        let wall = (CACurrentMediaTime() - start) * 1000
        try await Task.sleep(for: .milliseconds(20))
        var values = await pulse.finish()
        queueEvents[label] = pulse.events
        #expect((values["queue_max_ms"] ?? 0) <= (values["gap_max_ms"] ?? 0) + 1)
        values.merge(processMemoryMetrics(), uniquingKeysWith: { _, new in new })
        func mountedCards(_ view: NSView) -> Int {
            if let card = view as? AssetInteractionView { return card.debugSurface == "gallery-card" ? 1 : 0 }
            return view.subviews.reduce(0) { $0 + mountedCards($1) }
        }
        values["mounted_gallery_cards"] = Double(mountedCards(host))
        values["mounted_sidebar_rows"] = Double(state?.sidebarNavigation.availableRows.count ?? 0)
        values["wall_ms"] = wall
        values["updates"] = Double(updates.count)
        values["update_p50_ms"] = percentile(updates, 0.5)
        values["update_p95_ms"] = percentile(updates, 0.95)
        values["update_p99_ms"] = percentile(updates, 0.99)
        values["update_max_ms"] = updates.max() ?? 0
        values["update_over_16.67ms"] = Double(updates.filter { $0 > 16.67 }.count)
        report[label] = values
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("INTERACTION_PERF \(label) \(String(decoding: bytes, as: UTF8.self))")
    }

    try await phase("cold_start_and_load") {
        initialStep("state_init_ms") {
            state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
            if environment["LIGHTBOX_INTERACTION_PROBE_EXPANDED_SIDEBAR"] == "1" {
                var folder = root
                while folder.path != "/" {
                    state.sidebarNavigation.expandedPaths.insert(folder.standardizedFileURL.path)
                    folder.deleteLastPathComponent()
                }
            }
        }
        initialStep("host_init_ms") {
            host = NSHostingView(rootView: AnyView(RootShellView().environmentObject(state)
                .background(WindowConfigurator(appState: state))))
        }
        initialStep("window_init_ms") {
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2560, height: 1360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }
        initialStep("first_layout_ms") { update() }
        for _ in 0..<(recursiveProbe ? 0 : 1_000) where state.libraryLoadingStatus != nil || state.assets.isEmpty
            || state.assets.contains(where: { !$0.metadataLoaded }) {
            update()
            try await Task.sleep(for: .milliseconds(8))
        }
        if !recursiveProbe { #expect(!state.assets.isEmpty && state.libraryLoadingStatus == nil) }
    }
    report["initial_steps"] = initialSteps
    print("INTERACTION_INIT \(initialSteps)")
    defer { window.close() }
    func saveAndValidateReport() throws {
        if let output = environment["LIGHTBOX_INTERACTION_PROBE_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
            if environment["LIGHTBOX_INTERACTION_PROBE_ACTIONS"] == "1" {
                try JSONSerialization.data(withJSONObject: queueEvents, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("queue.json"))
            }
        }
        if environment["LIGHTBOX_ENFORCE_RESPONSIVENESS"] == "1" {
            for (label, values) in report {
                guard let queueDelay = values["queue_max_ms"] else { continue }
                let budget = label == "cold_start_and_load" ? 500.0 : 100.0
                #expect(queueDelay < budget, "Main actor exceeded \(budget)ms during \(label): \(values)")
            }
        }
        if environment["LIGHTBOX_ENFORCE_FRAME_WORK"] == "1" {
            for (label, values) in report where label.hasPrefix("continuous_scroll_") {
                #expect((values["update_p95_ms"] ?? 0) < 16.67, "Scroll layout exceeded the 60 Hz work budget: \(values)")
            }
        }
    }
    if recursiveProbe {
        if samplePhase == "scan" { try startSampler(seconds: 6) }
        try await phase("recursive_scan_and_metadata") {
            let deadline = CACurrentMediaTime() + 60
            var idleSince: Double?
            repeat {
                update()
                try await Task.sleep(for: .milliseconds(8))
                let busy = state.searchStatus == nil || state.searchStatus?.isSearching == true
                    || state.searchStatus?.isLoadingMetadata == true
                if busy { idleSince = nil }
                else if idleSince == nil { idleSince = CACurrentMediaTime() }
            } while CACurrentMediaTime() < deadline && (idleSince == nil
                || CACurrentMediaTime() - (idleSince ?? 0) < 0.5)
            #expect(state.searchStatus?.isSearching == false && state.searchStatus?.isLoadingMetadata == false)
            #expect(!state.activeAssets.isEmpty)
        }
        report["recursive_context"] = ["assets": Double(state.activeAssets.count),
            "visited": Double(state.searchStatus?.visitedCount ?? 0),
            "folders": Double(state.activeFolderEntries.count),
            "groups": Double(state.searchAssetGroups.count),
            "metadata_processed": Double(state.searchStatus?.metadataProcessed ?? 0),
            "metadata_total": Double(state.searchStatus?.metadataTotal ?? 0)]
        #expect(window.titlebarAccessoryViewControllers.contains { $0.view is NativeNavigationBar })
        if samplePhase == "scan" { try await finishPhaseSampler() }
        if environment["LIGHTBOX_INTERACTION_PROBE_SCAN_ONLY"] == "1" {
            try saveAndValidateReport()
            return
        }
    }
    let realAssets = state.activeAssets
    print("INTERACTION_CONTEXT assets=\(realAssets.count) refresh_limit=\(NSScreen.main?.maximumFramesPerSecond ?? 0) hidden_window=true visible_locations=\(state.sidebarVisibleLocationIDs.count) loaded_locations=\(state.sidebarLocations.count) loaded_volumes=\(state.sidebarVolumes.count)")

    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    func scrollPhase(_ label: String, width: CGFloat) async throws {
        update { state.thumbnailWidth = width }
        try await Task.sleep(for: .milliseconds(300))
        // RootShell also contains the sidebar scroll view. Prefer the widest one.
        let gallery = try #require(scrolls(host).max { $0.bounds.width < $1.bounds.width })
        let maximum = max(0, (gallery.documentView?.frame.height ?? 0) - gallery.contentView.bounds.height)
        print("INTERACTION_SCROLL \(label) maximum=\(maximum) viewport=\(gallery.contentView.bounds.height)")
        try await phase(label) {
            for step in 0..<240 {
                let fraction = Double(step < 120 ? step : 239 - step) / 119
                update {
                    gallery.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
                    gallery.reflectScrolledClipView(gallery.contentView)
                }
                try await Task.sleep(for: .milliseconds(8))
            }
        }
    }
    if environment["LIGHTBOX_INTERACTION_PROBE_CONTINUOUS"] == "1" {
        var requests: [[String: Double]] = []
        let oneWaySteps = max(1, Int(environment["LIGHTBOX_INTERACTION_PROBE_SCROLL_STEPS"] ?? "120") ?? 120)
        // The large-size anchor sequence remains an explicit diagnostic: its
        // resize/navigation setup has failed and must not silently count as pass.
        let widths: [CGFloat] = environment["LIGHTBOX_INTERACTION_PROBE_CONTINUOUS_LARGE"] == "1"
            ? [206, 657] : [206]
        for width in widths {
            update { state.thumbnailWidth = width }
            // Let resize publish its new card geometry before navigation reads
            // frames. Start each run outside the image group with no old anchor.
            let gallery = try #require(scrolls(host).max { $0.bounds.width < $1.bounds.width })
            update {
                gallery.contentView.scroll(to: .zero)
                gallery.reflectScrolledClipView(gallery.contentView)
            }
            for _ in 0..<40 { update(); try await Task.sleep(for: .milliseconds(8)) }
            let anchor = try #require(realAssets.dropFirst().first)
            update {
                // Use an offscreen neighbor to trigger a scroll request, then
                // select the same anchor before the deferred request executes.
                // Spatial neighbors of already mounted cards vary after resize.
                let generation = state.galleryKeyboardScrollGeneration
                state.handleGalleryKey(123, modifiers: [], from: realAssets[realAssets.count - 1].id)
                #expect(state.galleryKeyboardScrollGeneration > generation)
                state.galleryKeyboardFocusID = anchor.id
                state.replaceSelection(with: [anchor.id])
            }
            for _ in 0..<50 { update(); try await Task.sleep(for: .milliseconds(8)) }
            let anchorFrame = try #require(state.previewSpaceFrame(for: anchor.id))
            #expect(anchorFrame.intersects(host.bounds))
            let startOffset = gallery.contentView.bounds.minY
            let label = "continuous_scroll_\(Int(width))"
            let maximum = max(0, (gallery.documentView?.frame.height ?? 0) - gallery.contentView.bounds.height)
            #expect(maximum - startOffset >= CGFloat(oneWaySteps * 180))
            if samplePhase == "continuous", width == 206 { try startSampler(seconds: 6) }
            var previousRequest = CACurrentMediaTime()
            try await phase(label) {
                // Fixed step size and requested sleep, not a promised constant
                // speed: layout stalls also lengthen the actual step interval.
                for step in Array(1...oneWaySteps) + Array((0..<oneWaySteps).reversed()) {
                    let requestedOffset = min(maximum, startOffset + CGFloat(step) * 180)
                    guard abs(requestedOffset - gallery.contentView.bounds.minY) > 0.5 else { continue }
                    let now = CACurrentMediaTime()
                    let interval = (now - previousRequest) * 1000
                    previousRequest = now
                    update {
                        gallery.contentView.scroll(to: CGPoint(x: 0, y: requestedOffset))
                        gallery.reflectScrolledClipView(gallery.contentView)
                    }
                    requests.append(["width": Double(width), "requested_y": Double(requestedOffset),
                        "actual_y": Double(gallery.contentView.bounds.minY), "interval_ms": interval,
                        "update_ms": updates.last ?? 0])
                    #expect(abs(gallery.contentView.bounds.minY - requestedOffset) <= 0.75)
                    try await Task.sleep(for: .milliseconds(8))
                }
            }
            #expect((report[label]?["mounted_gallery_cards"] ?? 0) > 0)
            if samplePhase == "continuous", width == 206 { try await finishPhaseSampler() }
            update { state.galleryKeyboardFocusID = nil }
        }
        if let output = environment["LIGHTBOX_INTERACTION_PROBE_REPORT"] {
            try JSONSerialization.data(withJSONObject: requests, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("scroll.json"))
        }
    }
    if recursiveProbe, environment["LIGHTBOX_INTERACTION_PROBE_RECURSIVE_REFRESH"] == "1" {
        @MainActor func finishRecursiveRefresh() async throws {
            let deadline = CACurrentMediaTime() + 60
            repeat {
                update()
                try await Task.sleep(for: .milliseconds(8))
            } while CACurrentMediaTime() < deadline && (state.libraryLoadingStatus != nil
                || state.searchStatus?.isSearching == true || state.searchStatus?.isLoadingMetadata == true)
            #expect(state.libraryLoadingStatus == nil && state.searchStatus?.isSearching == false
                && state.searchStatus?.isLoadingMetadata == false)
            #expect(state.activeAssets.count == realAssets.count)
        }
        try await phase("recursive_refresh_and_metadata") {
            update { state.refreshLibrary(preservingVisibleSnapshot: true) }
            try await finishRecursiveRefresh()
        }
        if samplePhase == "navigation" { try startSampler(seconds: 4) }
        try await phase("recursive_scan_parent_navigation") {
            update { state.refreshLibrary(preservingVisibleSnapshot: true) }
            for _ in 0..<1_000 where state.searchStatus?.isLoadingMetadata != true {
                update()
                try await Task.sleep(for: .milliseconds(8))
            }
            #expect(state.searchStatus?.isLoadingMetadata == true)
            let header = try #require(window.titlebarAccessoryViewControllers.compactMap {
                $0.view as? NativeNavigationBar
            }.first)
            let up = try #require(header.subviews.compactMap { $0 as? NSButton }.first {
                $0.toolTip == state.localized(.goToParentFolder)
            })
            let parent = state.currentFolderURL.deletingLastPathComponent().standardizedFileURL.path
            var actions: [String: Double] = [:]
            @MainActor func navigationUpdate(_ label: String, _ action: () -> Void) {
                var mutation = 0.0
                update {
                    let started = CACurrentMediaTime()
                    action()
                    mutation = (CACurrentMediaTime() - started) * 1000
                }
                actions[label + "_mutation_ms"] = mutation
                actions[label + "_layout_ms"] = max(0, (updates.last ?? 0) - mutation)
            }
            navigationUpdate("parent") {
                // Dispatch the real control action; performClick also adds AppKit's
                // synthetic highlight delay, which is not application input latency.
                _ = NSApp.sendAction(up.action!, to: up.target, from: up)
            }
            let destination = state.currentFolderURL.path
            #expect(destination == parent)
            navigationUpdate("back") { state.goBack() }
            #expect(state.currentFolderURL.path == root.standardizedFileURL.path)
            try await finishRecursiveRefresh()
            report["recursive_navigation_actions"] = actions
        }
        if samplePhase == "navigation" { try await finishPhaseSampler() }
    }
    if environment["LIGHTBOX_INTERACTION_PROBE_CONTINUOUS_ONLY"] == "1" {
        try saveAndValidateReport()
        return
    }
    try await scrollPhase("scroll_206", width: 206)
    try await scrollPhase("scroll_657", width: 657)
    if samplePhase == "resize" { try startSampler(seconds: 3) }
    var resizeSteps: [[String: Double]] = []
    let galleryWidth = try #require(scrolls(host).max { $0.bounds.width < $1.bounds.width }).bounds.width
    func columnCount(for width: CGFloat) -> Int {
        let effective = min(width, GalleryThumbnailSizing.maximumWidth(viewportWidth: galleryWidth))
        return max(2, Int((galleryWidth - 36 + SpacingTokens.regular) / (effective + SpacingTokens.regular)))
    }
    try await phase("thumbnail_resize") {
        state.isScalingThumbnails = true
        var previousColumns = columnCount(for: state.thumbnailWidth)
        for step in 0..<60 {
            let width = CGFloat(170 + step * 8)
            let columns = columnCount(for: width)
            update { state.thumbnailWidth = width }
            resizeSteps.append(["width": Double(width), "columns": Double(columns),
                "changed_columns": columns != previousColumns ? 1 : 0, "update_ms": updates.last ?? 0])
            previousColumns = columns
            try await Task.sleep(for: .milliseconds(8))
        }
        state.isScalingThumbnails = false
        try await Task.sleep(for: .milliseconds(200))
        update()
    }
    if let output = environment["LIGHTBOX_INTERACTION_PROBE_REPORT"] {
        try JSONSerialization.data(withJSONObject: resizeSteps, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("resize.json"))
    }
    if samplePhase == "resize" { try await finishPhaseSampler() }
    try await phase("preview_open_step_close") {
        let asset = try #require(state.activeAssets.first)
        ImageCache.shared.removeMemoryObjects(reason: "interaction-cold-preview")
        update { state.showPreview(for: asset, sourceFrame: state.previewSpaceFrame(for: asset.id)) }
        for _ in 0..<40 { update(); try await Task.sleep(for: .milliseconds(8)) }
        for _ in 0..<12 {
            update { state.stepPreview(.next) }
            try await Task.sleep(for: .milliseconds(60))
        }
        update { _ = state.beginPreviewClose() }
        for _ in 0..<60 where state.previewAssetID != nil { update(); try await Task.sleep(for: .milliseconds(8)) }
        #expect(state.previewAssetID == nil)
    }
    if environment["LIGHTBOX_INTERACTION_PROBE_BROWSE_ONLY"] == "1" {
        try saveAndValidateReport()
        return
    }
    if samplePhase == "search" { try startSampler(seconds: 3) }
    var searchSteps: [[String: Any]] = []
    let collectsSearchSteps = samplePhase == "search" || environment["LIGHTBOX_INTERACTION_PROBE_ACTIONS"] == "1"
    func searchUpdate(_ label: String, _ action: () -> Void) {
        guard collectsSearchSteps else { update(action); return }
        var mutationMilliseconds = 0.0
        let startedAt = CACurrentMediaTime()
        update {
            let start = CACurrentMediaTime()
            action()
            mutationMilliseconds = (CACurrentMediaTime() - start) * 1000
        }
        let total = updates.last ?? 0
        searchSteps.append(["operation": label, "assets": state.activeAssets.count, "started_at": startedAt,
            "mutation_ms": mutationMilliseconds, "layout_ms": max(0, total - mutationMilliseconds),
            "update_ms": total])
    }
    try await phase("search_sort_filter") {
        for text in ["S", "S0", "S00", "S001", "", "B", "B-", ""] {
            searchUpdate("search:\(text)") { state.searchText = text }
            try await Task.sleep(for: .milliseconds(100))
        }
        for field in GallerySortField.allCases {
            searchUpdate("sort:\(field.rawValue)") { state.setSortField(field) }
            try await Task.sleep(for: .milliseconds(80))
        }
        searchUpdate("filter:Red") { state.selectedFilter = .tag("Red") }
        try await Task.sleep(for: .milliseconds(100))
        searchUpdate("filter:all") { state.selectedFilter = .all }
        try await Task.sleep(for: .milliseconds(100))
    }
    if collectsSearchSteps {
        if let output = environment["LIGHTBOX_INTERACTION_PROBE_REPORT"] {
            try JSONSerialization.data(withJSONObject: searchSteps, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("search.json"))
        }
        if samplePhase == "search" { try await finishPhaseSampler() }
    }
    try await phase("sidebar_window_resize") {
        for _ in 0..<4 {
            update { state.sidebarCollapsed.toggle() }
            for _ in 0..<50 { update(); try await Task.sleep(for: .milliseconds(8)) }
        }
        for step in 0..<40 {
            update { host.setFrameSize(NSSize(width: 1800 + step * 18, height: 1360)) }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
    try await phase("warm_refresh") {
        state.refreshLibrary(preservingVisibleSnapshot: true)
        for _ in 0..<1_000 where state.libraryLoadingStatus != nil
            || state.searchStatus?.isSearching == true || state.searchStatus?.isLoadingMetadata == true {
            update()
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(state.libraryLoadingStatus == nil && state.activeAssets.count == realAssets.count)
    }
    if samplePhase == "tabs" { try startSampler(seconds: 3) }
    try await phase("cached_tabs") {
        let galleryTab = state.activeTabID
        update { state.newTab() }
        let emptyTab = state.activeTabID
        for _ in 0..<6 {
            update { state.selectTab(galleryTab) }
            try await Task.sleep(for: .milliseconds(100))
            #expect(state.activeAssets.count == realAssets.count)
            update { state.selectTab(emptyTab) }
            try await Task.sleep(for: .milliseconds(100))
        }
        update { state.selectTab(galleryTab); state.closeTab(emptyTab) }
        for _ in 0..<200 where state.libraryLoadingStatus != nil {
            update(); try await Task.sleep(for: .milliseconds(8))
        }
    }
    if samplePhase == "tabs" { try await finishPhaseSampler() }
    try await phase("comparison_open_close") {
        for count in [2, 8] {
            update {
                state.selectedAssetIDs = Set(state.activeAssets.prefix(count).map(\.id))
                state.showComparisonFromSelection()
            }
            for _ in 0..<50 { update(); try await Task.sleep(for: .milliseconds(8)) }
            update { state.comparisonAssets = [] }
            for _ in 0..<40 { update(); try await Task.sleep(for: .milliseconds(8)) }
        }
        #expect(state.comparisonAssets.isEmpty)
    }
    for count in [2_000, 10_000] {
        try await phase("synthetic_\(count)_publish_sort") {
            update {
                state.assets = (0..<count).map { index in
                    LightboxAsset(id: "stress-\(index)", originalName: "Photo-\(index).jpg", width: 400,
                        height: CGFloat(240 + index % 5 * 80), tags: index % 3 == 0 ? ["Red"] : [],
                        addedAt: .distantPast, palette: MockPalette.imported[index % MockPalette.imported.count])
                }
            }
            try await Task.sleep(for: .milliseconds(200))
            for field in [GallerySortField.fileName, .time, .tag] {
                update { state.setSortField(field) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    // Attribute all-asset geometry separately from SwiftUI card updates. These
    // synthetic sizes do not perform real file decoding or disk reads.
    for count in [220, 2_000, 10_000] {
        let assets = Array(state.assets.prefix(count))
        var columns = Array(repeating: [LightboxAsset](), count: 7)
        for (index, asset) in assets.enumerated() { columns[index % 7].append(asset) }
        var samples: [Double] = []
        var geometryHeight: CGFloat = 0
        for step in 0..<60 {
            let start = CACurrentMediaTime()
            let placement = GalleryMasonryPlacement(columns: columns, itemWidth: CGFloat(170 + step * 8),
                spacing: SpacingTokens.regular, orderedAssets: assets)
            geometryHeight += placement.height
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        #expect(geometryHeight > 0)
        report["placement_\(count)_geometry"] = ["update_p95_ms": percentile(samples, 0.95),
            "update_max_ms": samples.max() ?? 0, "updates": Double(samples.count)]
    }
    try saveAndValidateReport()
}
