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

@Test func sidebarTreeFolderIdentityPreservesRevealAndReload() {
    let root = URL(fileURLWithPath: "/Volumes/Identity Fixtures", isDirectory: true)
    let folder = LibraryFolderEntry(sourceID: "volume", url: root.appendingPathComponent("Trip/../穿搭图库/B页", isDirectory: true), rootURL: root)
    let reference = SidebarTreeFolder(folder: folder)
    let plan = SidebarTreeRevealPlan(folder: folder.url, roots: [root], showsHiddenItems: true)
    #expect(reference.id == folder.id)
    #expect(reference.path == plan?.row.path)
    #expect(SidebarDirectoryIdentity(url: root).path == plan?.row.root)
    var renamed = folder
    renamed.url = root.appendingPathComponent("穿搭图库/C页", isDirectory: true)
    let reloaded = SidebarTreeFolder(folder: renamed)
    #expect(reloaded.id != reference.id)
    #expect(reloaded.path == SidebarTreeRevealPlan(folder: renamed.url, roots: [root], showsHiddenItems: true)?.row.path)
    #expect(reference.folder.url == folder.url)
}

@Test func sidebarVolumeIdentityPreservesCanonicalRowPath() {
    let url = URL(fileURLWithPath: "/Volumes/Folder/../外置盘", isDirectory: true)
    let volume = SidebarVolume(url: url, displayName: "外置盘")
    #expect(volume.id == url.standardizedFileURL.path)
    #expect(volume.id == volume.url.path)
    #expect(SidebarTreeRevealPlan(folder: volume.url, roots: [volume.url], showsHiddenItems: true)?.row == SidebarTreeRowID(root: volume.id, path: volume.id))
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

@Test(arguments: [true, false])
@MainActor func previewKeyboardTakesFocusBeforeNextEventWhenAttached(requestedBeforeAttachment: Bool) throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = try #require(window.contentView)
    let gallery = AssetInteractionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    gallery.debugSurface = "gallery-card"
    content.addSubview(gallery)
    #expect(window.makeFirstResponder(gallery))
    let preview = PreviewKeyboardView(frame: .zero)
    var nextRequests = 0
    preview.onNext = { nextRequests += 1 }
    defer {
        preview.requestedFocus = false
        window.makeFirstResponder(nil)
        preview.removeFromSuperview()
        gallery.removeFromSuperview()
        window.close()
    }
    if requestedBeforeAttachment { preview.requestedFocus = true }
    content.addSubview(preview)
    if !requestedBeforeAttachment { preview.requestedFocus = true }

    // The next input event can arrive before an asynchronously queued focus handoff.
    #expect(window.firstResponder === preview)
    let next = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    (window.firstResponder as? PreviewKeyboardView)?.keyDown(with: next)
    #expect(nextRequests == 1)
}

@Test @MainActor func previewKeyboardDoesNotTakeFocusWithoutRequest() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = try #require(window.contentView)
    let information = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    content.addSubview(information)
    #expect(window.makeFirstResponder(information))
    let originalResponder = window.firstResponder
    let preview = PreviewKeyboardView(frame: .zero)
    defer {
        preview.requestedFocus = false
        window.makeFirstResponder(nil)
        preview.removeFromSuperview()
        information.removeFromSuperview()
        window.close()
    }
    preview.requestedFocus = true
    preview.requestedFocus = false
    content.addSubview(preview)
    #expect(window.firstResponder === originalResponder)
    #expect(window.firstResponder !== preview)
}

@MainActor private final class PreviewFocusRefusingView: NSView {
    var remainingRefusals = 1
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        guard remainingRefusals > 0 else { return true }
        remainingRefusals -= 1
        return false
    }
}

@Test @MainActor func previewKeyboardRetriesFocusAfterResponderInitiallyRefuses() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = try #require(window.contentView)
    let previous = PreviewFocusRefusingView(frame: .zero)
    content.addSubview(previous)
    #expect(window.makeFirstResponder(previous))
    let preview = PreviewKeyboardView(frame: .zero)
    var acquiredFocus = 0
    preview.onFocusAcquired = { acquiredFocus += 1 }
    content.addSubview(preview)
    defer {
        preview.requestedFocus = false
        window.makeFirstResponder(nil)
        preview.removeFromSuperview()
        previous.removeFromSuperview()
        window.close()
    }
    preview.requestedFocus = true
    #expect(window.firstResponder === previous)
    #expect(previous.remainingRefusals == 0)
    #expect(acquiredFocus == 0)
    try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === preview)
    #expect(acquiredFocus == 1)
}

@Test(arguments: [true, false])
@MainActor func previewKeyboardCancelledRetryDoesNotTakeFocus(detach: Bool) async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = try #require(window.contentView)
    let previous = PreviewFocusRefusingView(frame: .zero)
    content.addSubview(previous)
    #expect(window.makeFirstResponder(previous))
    let preview = PreviewKeyboardView(frame: .zero)
    var acquiredFocus = 0
    preview.onFocusAcquired = { acquiredFocus += 1 }
    content.addSubview(preview)
    defer {
        preview.requestedFocus = false
        window.makeFirstResponder(nil)
        preview.removeFromSuperview()
        previous.removeFromSuperview()
        window.close()
    }
    preview.requestedFocus = true
    #expect(window.firstResponder === previous)
    if detach { preview.removeFromSuperview() }
    else { preview.requestedFocus = false }
    try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === previous)
    #expect(window.firstResponder !== preview)
    #expect(acquiredFocus == 0)
}
