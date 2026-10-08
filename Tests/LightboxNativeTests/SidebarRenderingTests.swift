import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

@Test @MainActor func sidebarRevealWaitsForLoadedAncestorsAndRejectsMissingChildren() throws {
    let suite = "LightboxReveal-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let navigation = SidebarNavigationState(defaults: defaults)
    let root = SidebarTreeRowID(root: "/Volumes/SSD", path: "/Volumes/SSD")
    let parent = SidebarTreeRowID(root: root.root, path: "/Volumes/SSD/图库")
    let target = SidebarTreeRowID(root: root.root, path: "/Volumes/SSD/图库/B页")
    #expect(navigation.revealStep(for: target, available: []) == .scrollTo(root))
    #expect(navigation.revealStep(for: target, available: [root]) == .waitingForChildren)
    navigation.registerChildren([parent], of: root)
    #expect(navigation.revealStep(for: target, available: [root]) == .scrollTo(parent))
    #expect(navigation.revealStep(for: target, available: [root, parent]) == .waitingForChildren)
    navigation.registerChildren([target], of: parent)
    #expect(navigation.revealStep(for: target, available: [root, parent]) == .scrollTo(target))
    navigation.forgetChildren(of: parent)
    #expect(navigation.revealStep(for: target, available: [root, parent]) == .waitingForChildren)
    navigation.registerChildren([], of: parent)
    #expect(navigation.revealStep(for: target, available: [root, parent]) == .missing)
    #expect(navigation.revealStep(for: .init(root: root.root, path: "/Volumes/SSDBackup/B页"), available: []) == .missing)
    navigation.pendingReveal = target
    navigation.resetReveal()
    #expect(navigation.pendingReveal == nil)
    #expect(navigation.revealStep(for: target, available: [root]) == .waitingForChildren)
}

// Exercise the actual nested lazy stacks and ScrollViewProxy, not just a route model.
@Test @MainActor func sidebarLazilyRevealsLastAndDeepRowsAfterCollapseAndReload() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxSidebarLazy-\(UUID())").standardizedFileURL
    let suite = "LightboxSidebarLazy-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    for index in 0..<449 {
        try FileManager.default.createDirectory(at: work.appendingPathComponent(String(format: "%03d", index)), withIntermediateDirectories: true)
    }
    let lastFolder = work.appendingPathComponent("448")
    let deepFolder = lastFolder.appendingPathComponent("第一层/第二层/目标")
    try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)
    let source = LibrarySource(id: "sidebar-lazy", name: "Sidebar", rootURL: work, kind: .external)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
        sidebarDestinationLoader: { _ in .init(locations: [], volumes: [.init(url: work, displayName: "Fixture")]) })
    let navigation = state.sidebarNavigation
    // A fixture root still appears under Volumes, independently of user settings.
    let originalLocations = LightboxSettingsStore.loadSidebarVisibleLocationIDs()
    defer { LightboxSettingsStore.saveSidebarVisibleLocationIDs(originalLocations) }
    state.sidebarVisibleLocationIDs.insert(.volumes)
    navigation.expandedPaths.insert(work.path)
    let originalCollapsed = LightboxSettingsStore.loadSidebarCollapsed()
    defer { LightboxSettingsStore.saveSidebarCollapsed(originalCollapsed) }
    state.sidebarCollapsed = false
    let host = NSHostingView(rootView: ResidentSidebarHost(appState: state)
        .frame(width: state.sidebarWidth + 10).frame(maxHeight: .infinity))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
    try await wait { state.libraryLoadingStatus == nil && navigation.availableRows.count > 2 }
    #expect(navigation.availableRows.count < 80)
    let last = SidebarTreeRowID(root: work.path, path: lastFolder.path)
    #expect(!navigation.availableRows.contains(last))
    navigation.pendingReveal = last
    try await wait { navigation.pendingReveal == nil && navigation.availableRows.contains(last) }
    #expect(navigation.availableRows.count < 80)
    let plan = try #require(SidebarTreeRevealPlan(folder: deepFolder, roots: [work], showsHiddenItems: false))
    navigation.expandedPaths.formUnion(plan.ancestors)
    navigation.pendingReveal = plan.row
    try await wait { navigation.pendingReveal == nil && navigation.availableRows.contains(plan.row) }
    #expect(navigation.availableRows.count < 80)
    navigation.expandedPaths.removeAll()
    try await wait { navigation.availableRows.count == 1 }
    navigation.expandedPaths.formUnion(plan.ancestors)
    navigation.pendingReveal = plan.row
    try await wait { navigation.pendingReveal == nil && navigation.availableRows.contains(plan.row) }
    // Re-reading a subtree must not leave an impossible reveal waiting forever.
    navigation.expandedPaths.removeAll()
    try await wait { navigation.availableRows.count == 1 }
    try FileManager.default.removeItem(at: deepFolder)
    navigation.expandedPaths.formUnion(plan.ancestors)
    navigation.pendingReveal = plan.row
    try await wait { navigation.pendingReveal == nil }
    #expect(!navigation.availableRows.contains(plan.row))
}
