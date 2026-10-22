import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import LightboxNative

// A tab returns to where it was scrolled: after switching away and back, and
// after the app is reopened.
@MainActor
@Test func tabScrollPositionSurvivesSwitchingAndRelaunch() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxTabScroll-\(UUID())")
    var tabs: [LightboxTab] = []
    for name in ["Tab-A", "Tab-B"] {
        let folder = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<90 { try Data([1]).write(to: folder.appendingPathComponent(String(format: "%@-%03d.jpg", name, index))) }
        tabs.append(LightboxTab(source: LibrarySource(id: name, name: name, rootURL: folder, kind: .external), folderURL: folder))
    }
    defer { try? FileManager.default.removeItem(at: work) }
    let suite = "LightboxTabScroll-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    LightboxTabStore.save(tabs: tabs, activeTabID: tabs[0].id, defaults: defaults)

    func findScroll(_ view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScroll).first
    }
    func open() async throws -> (AppState, NSWindow, NSScrollView) {
        let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
        state.showFolderCards = false
        let host = NSHostingView(rootView: GalleryView().environmentObject(state).coordinateSpace(name: "PreviewSpace"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        await waitWhile {
            host.layoutSubtreeIfNeeded()
            return !(state.libraryLoadingStatus == nil && state.activeAssets.count == 90)
        }
        try await settle(host)
        return (state, window, try #require(findScroll(host)))
    }
    func settle(_ view: NSView) async throws {
        for _ in 0..<40 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func fraction(_ scroll: NSScrollView) -> Double {
        let documentHeight = scroll.documentView?.frame.height ?? 1
        return scroll.contentView.bounds.origin.y / max(1, documentHeight - scroll.contentView.bounds.height)
    }

    var (state, window, scroll) = try await open()
    func scrollTo(_ target: Double) async throws {
        let height = try #require(scroll.documentView?.frame.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: (height - scroll.contentView.bounds.height) * target))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(scroll)
    }
    // Switching tabs rebuilds the gallery's scroll view; measure the new one.
    func show(_ tab: LightboxTab) async throws {
        state.selectTab(tab.id)
        await waitWhile { state.libraryLoadingStatus != nil }
        let content = try #require(window.contentView)
        try await settle(content)
        scroll = try #require(findScroll(content))
        try await settle(content)
    }
    // Each tab keeps its own position: A at 70%, B at 30%.
    try await scrollTo(0.7)
    let before = fraction(scroll)
    #expect(state.activeTabScrollAnchorAssetID != nil)
    try await show(tabs[1])
    try await scrollTo(0.3)
    let beforeB = fraction(scroll)
    try await show(tabs[0])
    let afterSwitch = fraction(scroll)
    try await show(tabs[1])
    let afterSwitchB = fraction(scroll)
    print("TABSCROLL A \(before) -> \(afterSwitch), B \(beforeB) -> \(afterSwitchB)")
    #expect(abs(afterSwitch - before) < 0.1, "A after switching back: \(afterSwitch), before: \(before)")
    #expect(abs(afterSwitchB - beforeB) < 0.1, "B after switching back: \(afterSwitchB), before: \(beforeB)")
    try await show(tabs[0])

    state.persistTabsImmediately()
    window.close()
    (state, window, scroll) = try await open()
    try await settle(scroll)
    let afterRelaunch = fraction(scroll)
    print("TABSCROLL after relaunch=\(afterRelaunch)")
    #expect(abs(afterRelaunch - before) < 0.1, "after reopening: \(afterRelaunch), before: \(before)")
    window.close()
}

// The same, in the full window (sidebar, header, folder row) with real images,
// the way the app shows tabs.
@MainActor
@Test func tabScrollPositionSurvivesSwitchingInTheFullWindow() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxTabScrollFull-\(UUID())")
    var tabs: [LightboxTab] = []
    for name in ["Tab-A", "Tab-B"] {
        let folder = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Child"), withIntermediateDirectories: true)
        for index in 0..<90 {
            let url = folder.appendingPathComponent(String(format: "%@-%03d.jpg", name, index))
            let size = index.isMultiple(of: 3) ? CGSize(width: 90, height: 120) : CGSize(width: 120, height: 80)
            let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        tabs.append(LightboxTab(source: LibrarySource(id: name, name: name, rootURL: folder, kind: .external), folderURL: folder))
    }
    defer { try? FileManager.default.removeItem(at: work) }
    let suite = "LightboxTabScrollFull-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    LightboxTabStore.save(tabs: tabs, activeTabID: tabs[0].id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    state.sidebarVisibleLocationIDs = []
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = NSHostingView(rootView: RootShellView().environmentObject(state)
        .background(WindowConfigurator(appState: state)))
    window.orderFrontRegardless()
    defer { window.close() }
    func settle() async throws {
        for _ in 0..<50 { window.contentView?.superview?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func findScroll(_ view: NSView) -> NSScrollView? {
        // The gallery's scroll view is the tallest one.
        var found: [NSScrollView] = []
        func walk(_ view: NSView) { if let scroll = view as? NSScrollView { found.append(scroll) }; view.subviews.forEach(walk) }
        walk(view)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    func gallery() throws -> NSScrollView {
        let content = try #require(window.contentView)
        return try #require(findScroll(content))
    }
    func fraction() throws -> Double {
        let scroll = try gallery()
        let height = scroll.documentView?.frame.height ?? 1
        return scroll.contentView.bounds.origin.y / max(1, height - scroll.contentView.bounds.height)
    }
    func scrollTo(_ target: Double) async throws {
        let scroll = try gallery()
        let height = try #require(scroll.documentView?.frame.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: (height - scroll.contentView.bounds.height) * target))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
    }
    // Switch the way a click does and let the window lay out on its own
    // display cycle: forcing layout here hid a restore that ran before the
    // new scroll view had its full height.
    func show(_ tab: LightboxTab) async throws {
        state.selectTab(tab.id)
        await waitWhile { state.libraryLoadingStatus != nil || state.activeAssets.count != 90 }
        try await Task.sleep(for: .milliseconds(800))
    }
    await waitWhile { state.libraryLoadingStatus != nil || state.activeAssets.count != 90 }
    try await settle()
    try await scrollTo(0.7)
    let beforeA = try fraction()
    try await show(tabs[1])
    try await scrollTo(0.3)
    let beforeB = try fraction()
    // Switching back shows the cached contents at once; the recheck that
    // follows is not announced as a scan.
    state.selectTab(tabs[0].id)
    #expect(state.libraryLoadingStatus?.isBackground == true)
    #expect(state.navigationActivityText == nil)
    try await show(tabs[0])
    let afterA = try fraction()
    try await show(tabs[1])
    let afterB = try fraction()
    // The recheck finishing must not overwrite the saved positions: a second
    // round trip lands in the same places.
    try await show(tabs[0])
    let againA = try fraction()
    try await show(tabs[1])
    let againB = try fraction()
    print("TABSCROLLFULL A \(beforeA) -> \(afterA) -> \(againA), B \(beforeB) -> \(afterB) -> \(againB)")
    for (label, before, after) in [("A", beforeA, afterA), ("B", beforeB, afterB), ("A again", beforeA, againA), ("B again", beforeB, againB)] {
        #expect(abs(after - before) < 0.1, "\(label): \(after), before: \(before)")
    }
    #expect(state.tabs.allSatisfy { $0.scrollAnchorAssetID != nil })
    // Restoring and recording use the same reference, so round trips do not
    // creep (they used to shift by the header and folder row each time).
    #expect(abs(againA - afterA) < 0.02 && abs(againB - afterB) < 0.02)
}
