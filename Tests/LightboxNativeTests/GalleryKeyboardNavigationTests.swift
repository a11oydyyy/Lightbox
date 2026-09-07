import AppKit
import Testing
@testable import LightboxNative

@Test func sidebarRevealOnlyExpandsAncestorsInsideVisibleRoot() {
    let root = URL(fileURLWithPath: "/Pictures")
    let plan = SidebarTreeRevealPlan(folder: root.appendingPathComponent("Trips/Istanbul"), roots: [root], showsHiddenItems: false)
    #expect(plan?.ancestors == ["/Pictures", "/Pictures/Trips"])
    #expect(plan?.row.path == "/Pictures/Trips/Istanbul")
    #expect(SidebarTreeRevealPlan(folder: root, roots: [root], showsHiddenItems: false)?.ancestors.isEmpty == true)
    #expect(SidebarTreeRevealPlan(folder: URL(fileURLWithPath: "/PicturesBackup"), roots: [root], showsHiddenItems: false) == nil)
    #expect(SidebarTreeRevealPlan(folder: root.appendingPathComponent(".hidden/Child"), roots: [root], showsHiddenItems: false) == nil)
    #expect(SidebarTreeRevealPlan(folder: root.appendingPathComponent(".hidden/Child"), roots: [root], showsHiddenItems: true) != nil)
    let nested = SidebarTreeRevealPlan(folder: root.appendingPathComponent("Trips/Istanbul"), roots: [root, root.appendingPathComponent("Trips")], showsHiddenItems: false)
    #expect(nested?.row.root == "/Pictures/Trips")
    #expect(nested?.ancestors == ["/Pictures/Trips"])
}

@Test func galleryKeyboardUsesSpatialNeighborsAndStopsAtEdges() {
    let ids = ["a", "b", "c", "d"]
    let frames = ["a": CGRect(x: 0, y: 60, width: 100, height: 150),
                  "b": CGRect(x: 120, y: 60, width: 100, height: 80),
                  "c": CGRect(x: 0, y: 230, width: 100, height: 80),
                  "d": CGRect(x: 120, y: 160, width: 100, height: 150)]
    #expect(GalleryKeyboardNavigation.targetIndex(key: 124, current: 0, ids: ids, frames: frames) == 1)
    #expect(GalleryKeyboardNavigation.targetIndex(key: 125, current: 0, ids: ids, frames: frames) == 2)
    #expect(GalleryKeyboardNavigation.targetIndex(key: 123, current: 0, ids: ids, frames: frames) == nil)
    #expect(GalleryKeyboardNavigation.targetIndex(key: 124, current: 3, ids: ids, frames: [:]) == nil)
    #expect(GalleryKeyboardNavigation.targetIndex(key: 124, current: 0, ids: ids, frames: [:]) == 1)
    #expect(GalleryKeyboardNavigation.targetIndex(key: 124, current: 0, ids: [], frames: [:]) == nil)
}

@Test @MainActor func galleryKeyboardActivationAndAccessibilityRespectDisabledState() {
    let view = AssetInteractionView()
    view.debugSurface = "gallery-card"
    var activations = 0
    view.onActivate = { activations += 1 }
    #expect(view.accessibilityPerformPress())
    #expect(activations == 1)
    view.isInteractionEnabled = false
    #expect(!view.accessibilityPerformPress())
    #expect(!view.acceptsFirstResponder)
    #expect(activations == 1)
}


@Test @MainActor func galleryKeyboardDoesNotStealTextOrControlFocus() {
    #expect(!AssetInteractionView.canRestoreGalleryFocus(over: NSTextView()))
    #expect(!AssetInteractionView.canRestoreGalleryFocus(over: NSSearchField()))
    #expect(!AssetInteractionView.canRestoreGalleryFocus(over: NSButton()))
    #expect(AssetInteractionView.canRestoreGalleryFocus(over: AssetInteractionView()))
}


@Test @MainActor func keyboardFocusRequestsSurviveWindowAttachment() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
    let preview = PreviewKeyboardView(frame: .zero)
    preview.requestedFocus = true
    window.contentView?.addSubview(preview)
    try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === preview)
    preview.requestedFocus = false
    preview.removeFromSuperview()
    let card = AssetInteractionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    card.debugSurface = "gallery-card"
    var focusVisible = false
    card.onFocusChanged = { focusVisible = $0 }
    card.requestedKeyboardFocus = true
    window.contentView?.addSubview(card)
    try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === card)
    #expect(focusVisible)
    window.makeFirstResponder(nil)
    try await Task.sleep(for: .milliseconds(30))
    #expect(!focusVisible)
    card.requestedKeyboardFocus = false
    card.removeFromSuperview()
}
