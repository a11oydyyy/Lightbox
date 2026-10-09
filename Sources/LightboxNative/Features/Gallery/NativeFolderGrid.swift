import AppKit
import CoreText
import SwiftUI

struct FolderGridPlacement {
    let count: Int
    let width: CGFloat
    let columns: Int
    let rowHeight: CGFloat
    let cellWidth: CGFloat
    private let columnSpacing: CGFloat = 16
    private let rowSpacing: CGFloat = 2

    init(count: Int, width: CGFloat, showsRelativePath: Bool) {
        self.count = max(0, count)
        self.width = max(0, width)
        columns = max(1, Int((max(0, width) + 16) / 196))
        rowHeight = showsRelativePath ? 44 : 36
        cellWidth = max(0, (max(0, width) - CGFloat(columns - 1) * 16) / CGFloat(columns))
    }

    var rows: Int { (count + columns - 1) / columns }
    var height: CGFloat { max(0, CGFloat(rows) * (rowHeight + rowSpacing) - rowSpacing) }

    func frame(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index % columns) * (cellWidth + columnSpacing),
               y: CGFloat(index / columns) * (rowHeight + rowSpacing),
               width: cellWidth, height: rowHeight)
    }

    func index(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.x < width, point.y < height else { return nil }
        let column = Int(point.x / (cellWidth + columnSpacing))
        let index = Int(point.y / (rowHeight + rowSpacing)) * columns + column
        guard column < columns, index < count, frame(at: index).contains(point) else { return nil }
        return index
    }

    func indices(intersecting rect: CGRect) -> Range<Int> {
        guard count > 0, rect.maxY >= 0, rect.minY < height else { return 0..<0 }
        let first = max(0, Int(floor(rect.minY / (rowHeight + rowSpacing)))) * columns
        let end = min(count, (Int(floor(max(0, rect.maxY) / (rowHeight + rowSpacing))) + 1) * columns)
        return min(first, end)..<end
    }

    func neighbor(of index: Int, key: UInt16) -> Int? {
        guard (0..<count).contains(index) else { return nil }
        let next: Int
        switch key {
        case 123: guard index % columns > 0 else { return nil }; next = index - 1
        case 124: guard index % columns < columns - 1 else { return nil }; next = index + 1
        case 125: next = index + columns
        case 126: next = index - columns
        default: return nil
        }
        return (0..<count).contains(next) ? next : nil
    }
}

struct NativeFolderGrid: NSViewRepresentable {
    var folders: [LibraryFolderEntry]
    var availableWidth: CGFloat
    var showsRelativePath: Bool
    var selectedFolderID: LibraryFolderEntry.ID?
    var showInFinderTitle: String
    var openInNewTabTitle: String
    var clearSelection: () -> Void
    var open: (LibraryFolderEntry) -> Void
    var openInNewTab: (LibraryFolderEntry) -> Void
    var reveal: (LibraryFolderEntry) -> Void

    func makeNSView(context: Context) -> NativeFolderGridView { NativeFolderGridView() }
    func updateNSView(_ view: NativeFolderGridView, context: Context) { view.configure(self) }
    static func dismantleNSView(_ view: NativeFolderGridView, coordinator: ()) { view.stop() }
}

// The folder region is one drawing/interaction surface, rather than hundreds of
// SwiftUI button trees. All folders remain reachable by keyboard and VoiceOver.
final class NativeFolderGridView: NSView, NSDraggingSource {
    private(set) var configuration: NativeFolderGrid?
    private(set) var placement = FolderGridPlacement(count: 0, width: 0, showsRelativePath: false)
    private var indicesByID: [String: Int] = [:]
    private var tagsByID: [String: [String]] = [:]
    private struct DisplayFolder {
        let id: String
        let name: String
        let relativePath: String
        var colorTags: [MacColorTag]
    }
    private var displayFolders: [DisplayFolder] = []
    private var accessibilityItems: [FolderGridAccessibilityItem]?
    private var icons: [String: NSImage] = [:]
    private struct TextKey: Hashable {
        var value: String
        var size: CGFloat
        var weight: CGFloat
        var width: CGFloat
        var locale: String
    }
    private struct TextLine {
        var line: CTLine
        var ascent: CGFloat
        var descent: CGFloat
    }
    private final class TextCacheKey: NSObject {
        let value: TextKey
        init(_ value: TextKey) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? TextCacheKey)?.value == value }
    }
    private final class CachedTextLine: NSObject {
        let value: TextLine
        init(_ value: TextLine) { self.value = value }
    }
    private static let sharedTextLines: NSCache<TextCacheKey, CachedTextLine> = {
        let cache = NSCache<TextCacheKey, CachedTextLine>()
        cache.countLimit = 4_096
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private var textLines: [TextKey: TextLine] = [:]
    private var hoveredIndex: Int?
    private(set) var focusedID: String?
    private var menuFolderID: String?
    private var tracking: NSTrackingArea?
    private var tagTask: Task<Void, Never>?
    nonisolated(unsafe) private var focusMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if widthChanged, window?.firstResponder === self,
           let focusedID, let index = indicesByID[focusedID] {
            scrollToVisible(placement.frame(at: index))
        }
    }

    func configure(_ next: NativeFolderGrid) {
        let foldersChanged = configuration?.folders != next.folders
        if foldersChanged || configuration?.availableWidth != next.availableWidth { textLines.removeAll(keepingCapacity: true) }
        let selectedChanged = configuration?.selectedFolderID != next.selectedFolderID
        configuration = next
        placement = FolderGridPlacement(count: next.folders.count, width: next.availableWidth,
                                        showsRelativePath: next.showsRelativePath)
        if foldersChanged {
            // URL-derived identity and labels are invariant between content
            // updates; resolving them for every draw dominated tab-switch work.
            displayFolders = next.folders.map { folder in
                DisplayFolder(id: folder.id, name: folder.name, relativePath: folder.relativePath,
                              colorTags: MacColorTag.all.filter { folder.tags.contains($0.name) })
            }
            indicesByID = Dictionary(displayFolders.enumerated().map { ($0.element.id, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
            tagsByID = Dictionary(zip(displayFolders, next.folders).map { ($0.0.id, $0.1.tags) },
                                  uniquingKeysWith: { first, _ in first })
            accessibilityItems = nil
            hoveredIndex = nil
            if let focusedID, indicesByID[focusedID] == nil { self.focusedID = nil }
            loadTags(next.folders)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        if selectedChanged, let id = next.selectedFolderID { focus(id: id) }
        needsDisplay = true
    }

    func stop() {
        tagTask?.cancel()
        tagTask = nil
        stopFocusMonitor()
    }

    private func loadTags(_ folders: [LibraryFolderEntry]) {
        tagTask?.cancel()
        tagTask = Task { [weak self] in
            for folder in folders {
                guard !Task.isCancelled else { return }
                let tags = folder.tags.isEmpty
                    ? await SidebarFolderTagCache.shared.tags(for: folder.url) : folder.tags
                guard !Task.isCancelled, let self, self.indicesByID[folder.id] != nil else { return }
                if self.tagsByID[folder.id] != tags {
                    self.tagsByID[folder.id] = tags
                    if let index = self.indicesByID[folder.id] {
                        self.displayFolders[index].colorTags = MacColorTag.all.filter { tags.contains($0.name) }
                        self.setNeedsDisplay(self.placement.frame(at: index))
                    }
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        icons.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let configuration else { return }
        for index in placement.indices(intersecting: dirtyRect) {
            let folder = displayFolders[index]
            let rect = placement.frame(at: index)
            let tags = folder.colorTags
            let selected = configuration.selectedFolderID == folder.id
            let focused = focusedID == folder.id && window?.firstResponder === self
            let shape = NSBezierPath(roundedRect: rect, xRadius: LightboxControlMetrics.cornerRadius,
                                     yRadius: LightboxControlMetrics.cornerRadius)
            if selected || hoveredIndex == index {
                (selected ? NSColor(LightboxColorTokens.navigationSelection)
                    : NSColor(LightboxColorTokens.primaryText).withAlphaComponent(LightboxControlMetrics.hoverOpacity)).setFill()
                shape.fill()
            }
            if focused && !selected {
                let inset: CGFloat = 0.5
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                    xRadius: LightboxControlMetrics.cornerRadius, yRadius: LightboxControlMetrics.cornerRadius)
                ring.lineWidth = 1
                // A quiet ring: the grid takes focus on any gallery click, so
                // the marker must not read heavier than selection.
                NSColor(LightboxColorTokens.secondaryText).withAlphaComponent(0.45).setStroke()
                ring.stroke()
            }
            let iconKey = tags.first?.name ?? ""
            if icons[iconKey] == nil {
                let color = NSColor(tags.first?.color ?? LightboxColorTokens.glyph)
                icons[iconKey] = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                        .applying(.init(hierarchicalColor: color)))
            }
            let icon = icons[iconKey]
            let iconSize = icon?.size ?? CGSize(width: 17, height: 15)
            icon?.draw(in: CGRect(x: rect.minX + 8, y: rect.midY - iconSize.height / 2,
                                 width: iconSize.width, height: iconSize.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let dot = MacTagDotMetrics.folderCardDotDiameter
            let gap = MacTagDotMetrics.sidebarSpacing
            let count = min(3, tags.count)
            let dotsWidth = CGFloat(count) * dot + CGFloat(max(0, count - 1)) * gap
            let textX = rect.minX + 8 + iconSize.width + 8
            let textWidth = max(0, rect.maxX - 8 - 4 - (count == 0 ? 0 : max(30, dotsWidth)) - textX)
            let subtitle = configuration.showsRelativePath && !folder.relativePath.isEmpty && folder.relativePath != folder.name
            drawText(folder.name, size: 12, weight: .semibold, color: NSColor(LightboxColorTokens.primaryText),
                     rect: CGRect(x: textX, y: rect.midY - (subtitle ? 14 : 7.5), width: textWidth, height: 15))
            if subtitle {
                drawText(folder.relativePath, size: 10, weight: .medium, color: NSColor(LightboxColorTokens.mutedText),
                         rect: CGRect(x: textX, y: rect.midY + 3, width: textWidth, height: 13))
            }
            for (offset, tag) in tags.prefix(3).enumerated() {
                let dotRect = CGRect(x: rect.maxX - 8 - dotsWidth + CGFloat(offset) * (dot + gap),
                                     y: rect.midY - dot / 2, width: dot, height: dot)
                let circle = NSBezierPath(ovalIn: dotRect)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = CGSize(width: 0, height: -1)
                shadow.set()
                NSColor(tag.color).setFill()
                circle.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.78).setStroke()
                circle.lineWidth = MacTagDotMetrics.folderCardStrokeWidth
                circle.stroke()
            }
        }
    }

    private func drawText(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, rect: CGRect) {
        guard rect.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let key = TextKey(value: value, size: size, weight: weight.rawValue, width: rect.width, locale: Locale.current.identifier)
        let text: TextLine
        if let cached = textLines[key] {
            text = cached
        } else if let cached = Self.sharedTextLines.object(forKey: TextCacheKey(key)) {
            text = cached.value
            textLines[key] = text
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: weight),
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]
            let full = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let line = CTLineCreateTruncatedLine(full, Double(rect.width), .middle, token) ?? full
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            text = TextLine(line: line, ascent: ascent, descent: descent)
            textLines[key] = text
            Self.sharedTextLines.setObject(CachedTextLine(text), forKey: TextCacheKey(key),
                                           cost: 1_024 + value.utf16.count * 64)
        }
        // Shape once; redraw with the current appearance and backing scale.
        // Invalidate on content/width changes, so this cache stays bounded to
        // the current folder labels rather than every resize or search result.
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(color.cgColor)
        context.translateBy(x: rect.minX, y: rect.midY + (text.ascent - text.descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(text.line, context)
        context.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let next = placement.index(at: convert(event.locationInWindow, from: nil))
        guard next != hoveredIndex else { return }
        if let previous = hoveredIndex { setNeedsDisplay(placement.frame(at: previous)) }
        hoveredIndex = next
        if let next {
            setNeedsDisplay(placement.frame(at: next))
            toolTip = configuration?.folders[next].name
        } else { toolTip = nil }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if let hoveredIndex { setNeedsDisplay(placement.frame(at: hoveredIndex)) }
        hoveredIndex = nil
        toolTip = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = placement.index(at: convert(event.locationInWindow, from: nil)),
              let configuration, let window else { return }
        let folder = configuration.folders[index]
        if event.modifierFlags.contains(.control) { showMenu(id: folder.id, at: convert(event.locationInWindow, from: nil)); return }
        let start = convert(event.locationInWindow, from: nil)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged, hypot(point.x - start.x, point.y - start.y) > 4 {
                let item = NSDraggingItem(pasteboardWriter: folder.url as NSURL)
                let tag = MacColorTag.all.first { (tagsByID[folder.id] ?? folder.tags).contains($0.name) }?.name ?? ""
                let rect = placement.frame(at: index)
                let icon = icons[tag]
                let size = icon?.size ?? CGSize(width: 17, height: 15)
                item.setDraggingFrame(CGRect(x: rect.minX + 8, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height), contents: icon)
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
            if next.type == .leftMouseUp {
                if placement.index(at: point) == index {
                    if event.modifierFlags.contains(.command) { configuration.openInNewTab(folder) }
                    else { configuration.open(folder) }
                }
                return
            }
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let index = placement.index(at: convert(event.locationInWindow, from: nil)),
           let id = configuration?.folders[index].id { showMenu(id: id, at: convert(event.locationInWindow, from: nil)) }
    }
    func showMenu(id: String, at point: CGPoint? = nil) {
        guard let configuration, let index = indicesByID[id] else { return }
        menuFolderID = id
        let menu = NSMenu()
        for (title, action) in [(configuration.openInNewTabTitle, #selector(openMenuFolder)),
                                (configuration.showInFinderTitle, #selector(revealMenuFolder))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let rect = placement.frame(at: index)
        menu.popUp(positioning: nil, at: point ?? CGPoint(x: rect.minX, y: rect.maxY), in: self)
    }
    @objc private func openMenuFolder() {
        guard let id = menuFolderID, let index = indicesByID[id], let configuration else { return }
        configuration.openInNewTab(configuration.folders[index])
    }
    @objc private func revealMenuFolder() {
        guard let id = menuFolderID, let index = indicesByID[id], let configuration else { return }
        configuration.reveal(configuration.folders[index])
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }

    func focus(id: String) {
        guard let index = indicesByID[id] else { return }
        focusedID = id
        scrollToVisible(placement.frame(at: index))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    override func becomeFirstResponder() -> Bool {
        if focusedID == nil { focusedID = configuration?.folders.first?.id }
        if let focusedID, let index = indicesByID[focusedID] { scrollToVisible(placement.frame(at: index)) }
        if focusMonitor == nil {
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window,
                       !self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.window?.makeFirstResponder(nil)
                    }
                }
                return event
            }
        }
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool {
        stopFocusMonitor()
        needsDisplay = true
        return true
    }
    private func stopFocusMonitor() {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
        focusMonitor = nil
    }
    deinit { if let focusMonitor { NSEvent.removeMonitor(focusMonitor) } }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        guard let configuration else { return }
        if event.keyCode == 53 {
            focusedID = nil
            configuration.clearSelection()
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }
        let index = focusedID.flatMap { indicesByID[$0] } ?? 0
        if event.keyCode == 48 {
            let previous = event.modifierFlags.contains(.shift)
            let next = index + (previous ? -1 : 1)
            if configuration.folders.indices.contains(next) { focus(id: configuration.folders[next].id) }
            else if previous { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        if event.keyCode == 109, event.modifierFlags.contains(.shift),
           configuration.folders.indices.contains(index) {
            showMenu(id: configuration.folders[index].id); return
        }
        if [36, 49, 76].contains(event.keyCode), configuration.folders.indices.contains(index) {
            configuration.open(configuration.folders[index]); return
        }
        if let next = placement.neighbor(of: index, key: event.keyCode) {
            focus(id: configuration.folders[next].id); return
        }
        super.keyDown(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { folderAccessibilityItems() }
    private func folderAccessibilityItems() -> [FolderGridAccessibilityItem] {
        if accessibilityItems == nil {
            accessibilityItems = configuration?.folders.map { FolderGridAccessibilityItem(owner: self, id: $0.id) } ?? []
        }
        return accessibilityItems ?? []
    }
    func folder(id: String) -> LibraryFolderEntry? {
        guard let index = indicesByID[id] else { return nil }
        return configuration?.folders[index]
    }
    func accessibilityFrame(id: String) -> CGRect {
        guard let window, let index = indicesByID[id] else { return .zero }
        return window.convertToScreen(convert(placement.frame(at: index), to: nil))
    }
    func accessibilityLabel(id: String) -> String? {
        guard let folder = folder(id: id) else { return nil }
        return ([folder.name] + MacColorTag.sort((tagsByID[id] ?? folder.tags).filter(MacColorTag.isColorTag))).joined(separator: ", ")
    }
    func activate(id: String) -> Bool {
        guard let folder = folder(id: id) else { return false }
        configuration?.open(folder)
        return true
    }
}

// Only immutable, actor-isolated callbacks cross the legacy AppKit boundary.
// Copying the callback avoids sending a mutable accessibility element to the actor.
final class FolderGridAccessibilityItem: NSAccessibilityElement, @unchecked Sendable {
    let id: String
    private let label: @MainActor @Sendable () -> String?
    private let frameProvider: @MainActor @Sendable () -> CGRect
    private let enabled: @MainActor @Sendable () -> Bool
    private let selected: @MainActor @Sendable () -> Bool
    private let focused: @MainActor @Sendable () -> Bool
    private let focus: @MainActor @Sendable (Bool) -> Void
    private let press: @MainActor @Sendable () -> Bool
    private let showMenu: @MainActor @Sendable () -> Bool

    @MainActor init(owner: NativeFolderGridView, id: String) {
        self.id = id
        label = { [weak owner] in owner?.accessibilityLabel(id: id) }
        frameProvider = { [weak owner] in owner?.accessibilityFrame(id: id) ?? .zero }
        enabled = { [weak owner] in owner?.folder(id: id) != nil }
        selected = { [weak owner] in owner?.configuration?.selectedFolderID == id }
        focused = { [weak owner] in owner?.focusedID == id && owner?.window?.firstResponder === owner }
        focus = { [weak owner] value in if value { owner?.focus(id: id) } }
        press = { [weak owner] in owner?.activate(id: id) ?? false }
        showMenu = { [weak owner] in
            guard let owner, owner.folder(id: id) != nil else { return false }
            owner.showMenu(id: id)
            return true
        }
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.button)
    }
    override func accessibilityLabel() -> String? {
        let callback = label
        return MainActor.assumeIsolated { callback() }
    }
    override func accessibilityFrame() -> NSRect {
        let callback = frameProvider
        return MainActor.assumeIsolated { callback() }
    }
    override func isAccessibilityEnabled() -> Bool {
        let callback = enabled
        return MainActor.assumeIsolated { callback() }
    }
    override func isAccessibilitySelected() -> Bool {
        let callback = selected
        return MainActor.assumeIsolated { callback() }
    }
    override func isAccessibilityFocused() -> Bool {
        let callback = focused
        return MainActor.assumeIsolated { callback() }
    }
    override func setAccessibilityFocused(_ value: Bool) {
        let callback = focus
        MainActor.assumeIsolated { callback(value) }
    }
    override func accessibilityPerformPress() -> Bool {
        let callback = press
        return MainActor.assumeIsolated { callback() }
    }
    override func accessibilityPerformShowMenu() -> Bool {
        let callback = showMenu
        return MainActor.assumeIsolated { callback() }
    }
}
