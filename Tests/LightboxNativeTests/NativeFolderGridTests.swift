import AppKit
import Testing
@testable import LightboxNative

@Test func folderGridPreservesLastRowAndDoesNotHitSpacing() {
    for width: CGFloat in [120, 375, 376, 980, 2200] {
        let grid = FolderGridPlacement(count: 449, width: width, showsRelativePath: false)
        let last = grid.frame(at: 448)
        #expect(last.maxX <= width + 0.01 && last.maxY == grid.height)
        #expect(grid.index(at: CGPoint(x: last.midX, y: last.midY)) == 448)
        #expect(grid.indices(intersecting: last).contains(448))
        #expect(grid.index(at: CGPoint(x: 1, y: 37)) == nil)
        #expect(grid.neighbor(of: 0, key: 123) == nil)
        #expect(grid.neighbor(of: 448, key: 124) == nil)
        #expect(grid.neighbor(of: 448, key: 125) == nil)
        if grid.columns > 1 {
            #expect(grid.index(at: CGPoint(x: grid.cellWidth + 2, y: 1)) == nil)
            #expect(grid.neighbor(of: grid.columns - 1, key: 124) == nil)
        }
    }
}

@MainActor private func folderGridFixture(_ count: Int, width: CGFloat = 600,
                                          open: @escaping (LibraryFolderEntry) -> Void = { _ in },
                                          clear: @escaping () -> Void = {}) -> NativeFolderGrid {
    let root = URL(fileURLWithPath: "/Lightbox-Folder-Grid-Fixture")
    let folders = (0..<count).map { index in
        var folder = LibraryFolderEntry(sourceID: "folder-grid", url: root.appendingPathComponent(String(format: "%03d", index)), rootURL: root)
        folder.tags = ["Red"]
        return folder
    }
    return NativeFolderGrid(folders: folders, availableWidth: width, showsRelativePath: false,
                            selectedFolderID: nil, showInFinderTitle: "Show in Finder", openInNewTabTitle: "Open in New Tab",
                            clearSelection: clear, open: open, openInNewTab: { _ in }, reveal: { _ in })
}

@Test @MainActor func folderGridAccessibilityKeepsOffscreenFoldersAndRejectsRemovedActions() throws {
    let view = NativeFolderGridView()
    defer { view.stop() }
    var opened: [String] = []
    let model = folderGridFixture(449, open: { opened.append($0.id) })
    view.configure(model)
    let children = try #require(view.accessibilityChildren() as? [FolderGridAccessibilityItem])
    #expect(children.count == 449)
    let last = try #require(children.last)
    #expect(last.isAccessibilityEnabled())
    #expect(last.accessibilityLabel() == "448, Red")
    #expect(last.accessibilityPerformPress())
    #expect(opened == [model.folders[448].id])
    view.configure(folderGridFixture(1, open: { opened.append($0.id) }))
    #expect(!last.isAccessibilityEnabled())
    #expect(!last.accessibilityPerformPress())
    #expect(view.accessibilityChildren()?.count == 1)
    #expect(opened.count == 1)
}

@Test @MainActor func folderGridKeyboardRevealsLastFolderAndRetainsFocusAcrossResize() throws {
    var opened: [String] = []
    var cleared = false
    var model = folderGridFixture(449, open: { opened.append($0.id) }, clear: { cleared = true })
    let view = NativeFolderGridView()
    view.configure(model)
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 240))
    view.frame = CGRect(x: 0, y: 0, width: 600, height: view.placement.height)
    scroll.documentView = view
    let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    defer { view.stop(); window.close() }
    let lastID = model.folders[448].id
    view.focus(id: lastID)
    #expect(window.firstResponder === view)
    #expect(scroll.contentView.bounds.minY > 0)
    #expect(view.visibleRect.intersects(view.placement.frame(at: 448)))
    model.availableWidth = 980
    view.configure(model)
    view.setFrameSize(CGSize(width: 980, height: view.placement.height))
    #expect(view.focusedID == lastID)
    model.availableWidth = 180
    view.configure(model)
    view.setFrameSize(CGSize(width: 180, height: view.placement.height))
    #expect(view.visibleRect.intersects(view.placement.frame(at: 448)))
    // Restore a multi-column row before checking horizontal navigation.
    model.availableWidth = 980
    view.configure(model)
    view.setFrameSize(CGSize(width: 980, height: view.placement.height))
    func press(_ key: UInt16) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
        view.keyDown(with: event)
    }
    try press(36)
    #expect(opened == [lastID])
    try press(123)
    #expect(view.focusedID == model.folders[447].id)
    try press(53)
    #expect(cleared && view.focusedID == nil)
}
