import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

// The selection checkbox is built only while it shows: a selected card draws
// it; an unselected one draws nothing there, with or without a selection
// elsewhere (until it is hovered or focused).
@MainActor
@Test func selectionCheckboxShowsOnlyOnSelectedCards() throws {
    let asset = LightboxAsset(id: "card", originalName: "card.jpg", width: 300, height: 200, tags: [],
                              addedAt: .now, palette: MockPalette.imported[0])
    func render(selected: Bool, selecting: Bool) throws -> NSBitmapImageRep {
        let card = AssetCardView(asset: asset, isSelected: selected, isExplicitlySelected: selected,
            showsSelectionControl: selecting, loadsImage: false, compareMenuTitle: "", menuTitles: .english,
            onClick: { _ in }, onRestore: {}, onMoveToTrash: {}, onApplyTag: { _ in }, onOpenWith: { _ in },
            onRevealInFinder: {}, onCopy: {}, onShare: { _ in }, onAddToCompareTray: {})
            .frame(width: 180, height: 120)
            .padding(8)
        // A real hosting view: the card's AppKit interaction layer has no
        // ImageRenderer rendering.
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: 196, height: 136)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if ProcessInfo.processInfo.environment["LIGHTBOX_UI_SNAPSHOT"] == "1" {
            let name = selected ? "card-selected" : (selecting ? "card-selecting" : "card-plain")
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".claude-preview/ui", isDirectory: true)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        return rep
    }
    /// The checkbox: 8pt in from the card's top-leading corner (the card sits
    /// 8pt in), 18pt square; sampled in pixels at the rep's scale.
    func checkboxRegion(_ rep: NSBitmapImageRep) -> [NSColor?] {
        let scale = CGFloat(rep.pixelsWide) / 196
        return stride(from: 17.0, to: 33.0, by: 2.0).flatMap { y in
            stride(from: 17.0, to: 33.0, by: 2.0).map { x in rep.colorAt(x: Int(x * scale), y: Int(y * scale)) }
        }
    }
    let plain = try render(selected: false, selecting: false)
    let selecting = try render(selected: false, selecting: true)
    let selected = try render(selected: true, selecting: true)
    #expect(checkboxRegion(plain) == checkboxRegion(selecting))
    #expect(checkboxRegion(selected) != checkboxRegion(plain))
}
