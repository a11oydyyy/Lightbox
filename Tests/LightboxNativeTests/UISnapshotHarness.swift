import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LightboxNative

// Visual-review harness: renders the real window offscreen to PNG, light and dark.
// Opt-in: LIGHTBOX_UI_SNAPSHOT=1 [LIGHTBOX_UI_SCENES=browse,select,search,...]
// swift test --filter uiSnapshotHarness. Writes to .claude-preview/ui (git-excluded).
// Glass and materials do not render offscreen; judge those in the app.
private let snapshotDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".claude-preview/ui", isDirectory: true)

private func writeImage(_ url: URL, width: Int, height: Int, hue: CGFloat) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let top = NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor
    let bottom = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45, alpha: 1).cgColor
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

@MainActor private func snapshot(_ window: NSWindow, _ name: String) async throws {
    for _ in 0..<12 {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
    }
    let frameView = try #require(window.contentView?.superview)
    let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: snapshotDirectory.appendingPathComponent("\(name).png"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_UI_SNAPSHOT"] == "1"))
@MainActor func uiSnapshotHarness() async throws {
    try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxUISnapshot-\(UUID())")
    let library = work.appendingPathComponent("旅行 2026")
    for folder in ["京都", "海邊", "街拍"] {
        try FileManager.default.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let sizes = [(1200, 800), (800, 1200), (1000, 1000), (1600, 900), (900, 1350), (1200, 900)]
    // 京都 stays empty (placeholder tile); the others get covers and counts.
    for (folder, count, hue) in [("街拍", 7, 0.58), ("海邊", 12, 0.12)] {
        for index in 0..<count {
            try writeImage(library.appendingPathComponent(folder).appendingPathComponent(String(format: "S_%03d.jpg", index)),
                           width: 300, height: 200, hue: CGFloat(hue) + CGFloat(index) * 0.01)
        }
    }
    for index in 0..<24 {
        let size = sizes[index % sizes.count]
        try writeImage(library.appendingPathComponent(String(format: "IMG_%04d.jpg", index + 1)),
                       width: size.0 / 4, height: size.1 / 4, hue: CGFloat(index) / 24)
    }
    // Listed only in the "otherfiles" scene.
    for (name, bytes) in [("行程表.pdf", 182_000), ("海邊 剪輯.mov", 48_000_000), ("備註.txt", 2_400), ("原始檔備份.zip", 9_600_000)] {
        try Data(count: bytes).write(to: library.appendingPathComponent(name))
    }
    let suite = "LightboxUISnapshot-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }
    let source = LibrarySource(id: "ui-snapshot", name: "旅行 2026", rootURL: library, kind: .external)
    let tab = LightboxTab(source: source, folderURL: library)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    state.appLanguage = .traditionalChinese
    state.sidebarVisibleLocationIDs.remove(.volumes)
    state.sidebarCollapsed = false
    for _ in 0..<200 where state.libraryLoadingStatus != nil || state.activeAssets.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
    }

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = NSHostingView(rootView: RootShellView()
        .environmentObject(state)
        .tint(LightboxColorTokens.accent)
        .environment(\.locale, state.appLanguage.locale)
        .background(WindowConfigurator(appState: state)))
    window.orderFrontRegardless()
    defer { window.close() }

    let scenes = (ProcessInfo.processInfo.environment["LIGHTBOX_UI_SCENES"] ?? "browse,select")
        .split(separator: ",").map(String.init)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        let mode = appearance == .aqua ? "light" : "dark"
        for scene in scenes {
            if !["searchselect", "selectmore"].contains(scene) { state.clearSelection() }
            if scene != "preview" { state.closePreview() }
            switch scene {
            case "select":
                state.selectedAssetIDs = Set(state.activeAssets.prefix(3).map(\.id))
            case "selectmore":
                // Grows an existing multi-selection: no app-state publish.
                state.selectedAssetIDs = Set(state.activeAssets.prefix(5).map(\.id))
            case "compare2", "compare4":
                state.closeComparison()
                state.selectedAssetIDs = Set(state.activeAssets.prefix(scene == "compare2" ? 2 : 4).map(\.id))
                state.showComparisonFromSelection()
            case "preview":
                // A portrait image fills the height: the details sit at the bottom margin.
                state.closeComparison()
                if let portrait = state.activeAssets.first(where: { $0.height > $0.width }) {
                    state.showPreview(for: portrait)
                    try await Task.sleep(for: MotionTokens.previewGeometryDuration + .milliseconds(200))
                }
            case "otherfiles":
                if !state.showsOtherFiles {
                    state.showsOtherFiles = true
                    for _ in 0..<200 where state.libraryLoadingStatus != nil || state.activeAssets.allSatisfy(\.isImage) {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    state.setSortField(.type)
                }
            case "list":
                state.galleryViewMode = .list
                state.selectedAssetIDs = Set(state.activeAssets.dropFirst(1).prefix(2).map(\.id))
            case "grid":
                state.galleryViewMode = .grid
            case "focus":
                state.galleryKeyboardFocusID = state.activeAssets.dropFirst(2).first?.id
            case "search":
                state.focusSearch()
                state.searchText = "IMG_001"
            case "searchselect":
                state.selectedAssetIDs = Set(state.activeAssets.prefix(2).map(\.id))
            case "clearsearch":
                state.searchText = ""
            case "empty":
                state.openSidebarFolder(library.appendingPathComponent("京都"))
            case "home":
                state.openSidebarFolder(library)
            case "trash":
                state.openTrashFromSidebar()
            case "collapsed":
                state.sidebarCollapsed = true
            case "expanded":
                state.sidebarCollapsed = false
            case "newtab":
                if !state.isShowingStartPage { state.newTab() }
            case "back":
                if state.isShowingStartPage, let first = state.tabs.first { state.selectTab(first.id) }
            default:
                break
            }
            try await snapshot(window, "\(scene)-\(mode)")
        }
    }
}
