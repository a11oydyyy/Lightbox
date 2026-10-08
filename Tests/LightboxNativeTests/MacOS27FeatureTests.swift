import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

private struct OrderedItem: Identifiable { let id: Int }

@Test func sidebarReorderPreservesMultiSelectionAndRejectsStaleDestination() {
    let items = (0..<6).map { OrderedItem(id: $0) }
    #expect(SidebarOrder.moving([3, 1], before: 5, in: items).map(\.id) == [0, 2, 4, 1, 3, 5])
    #expect(SidebarOrder.moving([0], before: nil, in: items).map(\.id) == [1, 2, 3, 4, 5, 0])
    #expect(SidebarOrder.moving([1], before: 1, in: items).map(\.id) == items.map(\.id))
    #expect(SidebarOrder.moving([1], before: 99, in: items).map(\.id) == items.map(\.id))
    #expect(SidebarOrder.moving([99], before: nil, in: items).map(\.id) == items.map(\.id))
}

@Test @MainActor func sidebarPinnedOrderSurvivesReloadAndNewSources() throws {
    let suite = "LightboxSidebarOrder-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sources = ["Alpha", "Beta", "Gamma"].map {
        LibrarySource(id: $0, name: $0, rootURL: URL(fileURLWithPath: "/tmp/\($0)"), kind: .external)
    }
    let state = SidebarNavigationState(defaults: defaults)
    state.reorder(["Gamma"], before: "Alpha", sources: sources)
    let restored = SidebarNavigationState(defaults: defaults)
    #expect(restored.ordered(sources).map(\.id) == ["Gamma", "Alpha", "Beta"])
    #expect(restored.ordered(Array(sources.dropFirst())).map(\.id) == ["Gamma", "Beta"])
}

@Test @MainActor func nativeRefreshAttachesTriggersAndDisablesOwnedController() async throws {
    guard #available(macOS 27, *) else { return }
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
    let document = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 1000))
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    defer { window.close() }
    let view = GalleryRefreshView()
    var refreshes = 0
    view.refresh = { refreshes += 1 }
    document.addSubview(view)
    view.attach()
    let controller = try #require(scroll.refreshController)
    _ = (controller.target as? NSObject)?.perform(controller.action, with: controller)
    #expect(refreshes == 1)
    view.isRefreshing = true
    view.attach()
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.isRefreshing)
    _ = (controller.target as? NSObject)?.perform(controller.action, with: controller)
    #expect(refreshes == 1)
    view.isRefreshing = false
    view.attach()
    #expect(!controller.isRefreshing)
    view.isEnabled = false
    view.attach()
    try await Task.sleep(for: .milliseconds(100))
    // AppKit may retain an ended controller until the window detaches. It must
    // have neither a live action target nor an active refresh at that point.
    #expect(controller.target == nil)
    #expect(!controller.isRefreshing)
    view.isEnabled = true
    view.attach()
    let replacement = try #require(scroll.refreshController)
    #expect(replacement.target === view)
    view.detach()
    #expect(replacement.target == nil)
    #expect(!replacement.isRefreshing)
}
