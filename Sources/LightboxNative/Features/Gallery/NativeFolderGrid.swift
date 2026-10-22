import AppKit
import CoreText
import SwiftUI

/// The image grid's column lines. Folder cells span whole image columns so
/// both grids share one set of vertical edges.
struct FolderColumnGuide: Equatable {
    var count: Int
    var width: CGFloat
    var spacing: CGFloat
}

struct FolderGridPlacement {
    static let minimumCellWidth: CGFloat = 180
    /// A folder tile: a cover thumbnail, then name and image count, on a faint
    /// fill. Shared with the section header so its chevron centers on the
    /// thumbnail column and its title lines up with the folder names.
    static let tileHeight: CGFloat = 48
    static let contentInset: CGFloat = 6
    static let thumbnailSize = CGSize(width: 48, height: 36)
    static let thumbnailRadius: CGFloat = 6
    static let iconTextGap: CGFloat = 10
    static let restFillOpacity: CGFloat = 0.045
    static let hoverFillOpacity = CGFloat(LightboxControlMetrics.hoverOpacity)
    @MainActor static let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

    let count: Int
    let width: CGFloat
    let columns: Int
    let rowHeight: CGFloat
    let cellWidth: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat

    init(count: Int, width: CGFloat, showsRelativePath: Bool, columnGuide: FolderColumnGuide? = nil) {
        self.count = max(0, count)
        self.width = max(0, width)
        // Tiles hold two text lines either way: the image count, or the
        // relative path in search results.
        rowHeight = Self.tileHeight
        rowSpacing = columnGuide?.spacing ?? 2
        if let guide = columnGuide, guide.count > 0, guide.width > 0 {
            // Fewest image columns per folder that still fit a readable name.
            let span = max(1, Int(ceil((Self.minimumCellWidth + guide.spacing) / (guide.width + guide.spacing))))
            columns = max(1, guide.count / span)
            cellWidth = CGFloat(span) * guide.width + CGFloat(span - 1) * guide.spacing
            columnSpacing = guide.spacing
        } else {
            columnSpacing = 16
            columns = max(1, Int((max(0, width) + columnSpacing) / (Self.minimumCellWidth + columnSpacing)))
            cellWidth = max(0, (max(0, width) - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns))
        }
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
    var columnGuide: FolderColumnGuide? = nil
    var showsRelativePath: Bool
    var selectedFolderID: LibraryFolderEntry.ID?
    var showInFinderTitle: String
    var openInNewTabTitle: String
    var renameTitle: String = ""
    var clearSelection: () -> Void
    var open: (LibraryFolderEntry) -> Void
    var openInNewTab: (LibraryFolderEntry) -> Void
    /// Nil for a folder that cannot be renamed.
    var rename: ((LibraryFolderEntry) -> Void)? = nil
    var reveal: (LibraryFolderEntry) -> Void
    var summaries: FolderSummaryService? = nil
    var imageCountText: (Int) -> String = { "\($0)" }

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
    private var summariesByID: [String: FolderImageSummary] = [:]
    private var summaryRequestedIDs: Set<String> = []
    private var covers: [String: NSImage] = [:]
    private var coverRequests: [String: ImageCacheRequest] = [:]
    private var coverRequestedIDs: Set<String> = []
    /// Covers that arrived after their tile was drawn fade in from the placeholder.
    private var coverFadeStarts: [String: CFTimeInterval] = [:]
    private var coverFadeScheduled = false

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
        if foldersChanged || configuration?.availableWidth != next.availableWidth
            || configuration?.columnGuide != next.columnGuide { textLines.removeAll(keepingCapacity: true) }
        let selectedChanged = configuration?.selectedFolderID != next.selectedFolderID
        configuration = next
        placement = FolderGridPlacement(count: next.folders.count, width: next.availableWidth,
                                        showsRelativePath: next.showsRelativePath, columnGuide: next.columnGuide)
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
            resetSummaries(for: next)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        if selectedChanged, let id = next.selectedFolderID { focus(id: id) }
        needsDisplay = true
    }

    func stop() {
        tagTask?.cancel()
        tagTask = nil
        stopFocusMonitor()
        coverRequests.values.forEach { $0.cancel() }
        coverRequests.removeAll()
    }

    /// Keeps covers for folders still listed, starts from the service's last
    /// known summaries, and re-checks these folders against disk lazily.
    private func resetSummaries(for next: NativeFolderGrid) {
        let ids = Set(displayFolders.map(\.id))
        for (id, request) in coverRequests where !ids.contains(id) { request.cancel() }
        coverRequests = coverRequests.filter { ids.contains($0.key) }
        covers = covers.filter { ids.contains($0.key) }
        coverRequestedIDs = coverRequestedIDs.intersection(covers.keys)
        summaryRequestedIDs = []
        summariesByID = [:]
        for folder in next.folders {
            if let known = next.summaries?.summary(for: folder.url) { summariesByID[folder.id] = known }
        }
        next.summaries?.reset(keeping: next.folders.map(\.url))
    }

    /// Requests summaries and covers for folders drawn on screen. Called after
    /// drawing, never during it.
    private func loadVisible(summaryIndices: [Int], coverIndices: [Int]) {
        guard let configuration else { return }
        if let service = configuration.summaries, !summaryIndices.isEmpty {
            let folders = summaryIndices.map { configuration.folders[$0] }
            service.request(folders.map(\.url)) { [weak self] url, summary in
                guard let self, let id = folders.first(where: { $0.url == url })?.id,
                      let index = self.indicesByID[id] else { return }
                let coverChanged = self.summariesByID[id]?.coverURL != summary.coverURL
                self.summariesByID[id] = summary
                if coverChanged {
                    self.coverRequests.removeValue(forKey: id)?.cancel()
                    self.covers.removeValue(forKey: id)
                    self.coverRequestedIDs.remove(id)
                }
                self.setNeedsDisplay(self.placement.frame(at: index))
            }
        }
        for index in coverIndices {
            let id = displayFolders[index].id
            guard let coverURL = summariesByID[id]?.coverURL else { continue }
            coverRequests[id] = ImageCache.shared.image(for: coverURL, quality: .thumbnailFast, priority: .low) { [weak self] image in
                guard let self, self.summariesByID[id]?.coverURL == coverURL else { return }
                self.coverRequests.removeValue(forKey: id)
                guard let image, let index = self.indicesByID[id] else { return }
                self.covers[id] = Self.tileCover(image, scale: self.window?.backingScaleFactor ?? 2) ?? image
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.coverFadeStarts[id] = CACurrentMediaTime()
                }
                self.setNeedsDisplay(self.placement.frame(at: index))
            }
        }
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
        var missingSummaries: [Int] = []
        var missingCovers: [Int] = []
        let primary = NSColor(LightboxColorTokens.primaryText)
        for index in placement.indices(intersecting: dirtyRect) {
            let folder = displayFolders[index]
            let rect = placement.frame(at: index)
            let tags = folder.colorTags
            let selected = configuration.selectedFolderID == folder.id
            let focused = focusedID == folder.id && window?.firstResponder === self
            let summary = summariesByID[folder.id]
            if !summaryRequestedIDs.contains(folder.id) {
                summaryRequestedIDs.insert(folder.id)
                missingSummaries.append(index)
            }
            if summary?.coverURL != nil, covers[folder.id] == nil, !coverRequestedIDs.contains(folder.id) {
                coverRequestedIDs.insert(folder.id)
                missingCovers.append(index)
            }

            // Tile: a faint resting fill makes each folder a clear target even
            // when only a few sit in a wide row.
            let radius = RadiusTokens.card
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            (selected ? NSColor(LightboxColorTokens.navigationSelection)
                : primary.withAlphaComponent(hoveredIndex == index
                    ? FolderGridPlacement.hoverFillOpacity : FolderGridPlacement.restFillOpacity)).setFill()
            shape.fill()
            if focused && !selected {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                ring.lineWidth = 1
                // A quiet ring: the grid takes focus on any gallery click, so
                // the marker must not read heavier than selection.
                NSColor(LightboxColorTokens.secondaryText).withAlphaComponent(0.45).setStroke()
                ring.stroke()
            }

            let thumbRect = thumbnailRect(in: rect)
            drawThumbnail(in: thumbRect, cover: covers[folder.id], coverAlpha: coverAlpha(folder.id), tag: tags.first)

            let dot = MacTagDotMetrics.folderCardDotDiameter
            let gap = MacTagDotMetrics.sidebarSpacing
            let count = min(3, tags.count)
            let dotsWidth = CGFloat(count) * dot + CGFloat(max(0, count - 1)) * gap
            let textX = thumbRect.maxX + FolderGridPlacement.iconTextGap
            let textWidth = max(0, rect.maxX - 8 - 4 - (count == 0 ? 0 : max(30, dotsWidth)) - textX)
            let countText = summary.flatMap { $0.imageCount > 0 ? configuration.imageCountText($0.imageCount) : nil }
            let path = configuration.showsRelativePath && !folder.relativePath.isEmpty && folder.relativePath != folder.name
                ? folder.relativePath : nil
            let subtitle = [path, countText].compactMap { $0 }.joined(separator: " · ")
            drawText(folder.name, size: 12, weight: .semibold, color: primary,
                     rect: CGRect(x: textX, y: rect.midY - (subtitle.isEmpty ? 7.5 : 15), width: textWidth, height: 15))
            if !subtitle.isEmpty {
                drawText(subtitle, size: 10.5, weight: .medium, color: NSColor(LightboxColorTokens.mutedText),
                         rect: CGRect(x: textX, y: rect.midY + 2, width: textWidth, height: 13))
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
        scheduleCoverFadeFrameIfNeeded()
        if !missingSummaries.isEmpty || !missingCovers.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.loadVisible(summaryIndices: missingSummaries, coverIndices: missingCovers)
            }
        }
    }

    private func thumbnailRect(in tile: CGRect) -> CGRect {
        let size = FolderGridPlacement.thumbnailSize
        return CGRect(x: tile.minX + FolderGridPlacement.contentInset, y: tile.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Ease-out opacity for a cover that is fading in; 1 once settled.
    private func coverAlpha(_ id: String) -> CGFloat {
        guard let start = coverFadeStarts[id] else { return 1 }
        let progress = min(1, (CACurrentMediaTime() - start) / MotionTokens.chromeRevealDurationSeconds)
        if progress >= 1 { coverFadeStarts.removeValue(forKey: id) }
        return CGFloat(1 - (1 - progress) * (1 - progress))
    }

    /// Redraws fading tiles on the next frame until every fade has settled.
    private func scheduleCoverFadeFrameIfNeeded() {
        guard !coverFadeStarts.isEmpty, !coverFadeScheduled else { return }
        coverFadeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self else { return }
            self.coverFadeScheduled = false
            for id in self.coverFadeStarts.keys {
                guard let index = self.indicesByID[id] else {
                    self.coverFadeStarts.removeValue(forKey: id)
                    continue
                }
                self.setNeedsDisplay(self.thumbnailRect(in: self.placement.frame(at: index)))
            }
        }
    }

    /// The cover, aspect-filled and clipped; before it loads (or for folders
    /// without images) a folder symbol in the folder's tag color. A fading
    /// cover is drawn over the placeholder.
    /// `image` cropped to fill a cover thumbnail, at the screen's density:
    /// scaling the decoded thumbnail (up to 360 px) at high quality on every
    /// redraw of every tile was most of the grid's drawing time.
    static func tileCover(_ image: NSImage, scale: CGFloat) -> NSImage? {
        let size = FolderGridPlacement.thumbnailSize
        guard image.size.width > 0, image.size.height > 0,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelWidth = Int((size.width * scale).rounded()), pixelHeight = Int((size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fill = max(CGFloat(pixelWidth) / CGFloat(source.width), CGFloat(pixelHeight) / CGFloat(source.height))
        let drawn = CGSize(width: CGFloat(source.width) * fill, height: CGFloat(source.height) * fill)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (CGFloat(pixelWidth) - drawn.width) / 2, y: (CGFloat(pixelHeight) - drawn.height) / 2,
                                        width: drawn.width, height: drawn.height))
        guard let tile = context.makeImage() else { return nil }
        return NSImage(cgImage: tile, size: size)
    }

    private func drawThumbnail(in rect: CGRect, cover: NSImage?, coverAlpha: CGFloat = 1, tag: MacColorTag?) {
        let radius = FolderGridPlacement.thumbnailRadius
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let primary = NSColor(LightboxColorTokens.primaryText)
        if cover == nil || coverAlpha < 1 {
            drawPlaceholder(in: rect, path: path, tag: tag)
        }
        if let cover, cover.size.width > 0, cover.size.height > 0 {
            let scale = max(rect.width / cover.size.width, rect.height / cover.size.height)
            let size = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            cover.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: coverAlpha, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            primary.withAlphaComponent(0.10 * coverAlpha).setStroke()
            edge.stroke()
        }
    }

    private func drawPlaceholder(in rect: CGRect, path: NSBezierPath, tag: MacColorTag?) {
        NSColor(LightboxColorTokens.primaryText).withAlphaComponent(0.06).setFill()
        path.fill()
        guard let icon = folderIcon(tag: tag) else { return }
        icon.draw(in: CGRect(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2,
                             width: icon.size.width, height: icon.size.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func folderIcon(tag: MacColorTag?) -> NSImage? {
        let key = tag?.name ?? ""
        if icons[key] == nil {
            let color = NSColor(tag?.color ?? LightboxColorTokens.glyph)
            icons[key] = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(FolderGridPlacement.iconConfiguration.applying(.init(hierarchicalColor: color)))
        }
        return icons[key]
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
                let tag = MacColorTag.all.first { (tagsByID[folder.id] ?? folder.tags).contains($0.name) }
                let thumb = thumbnailRect(in: placement.frame(at: index))
                if let cover = covers[folder.id] {
                    item.setDraggingFrame(thumb, contents: cover)
                } else {
                    let icon = folderIcon(tag: tag)
                    let size = icon?.size ?? CGSize(width: 17, height: 15)
                    item.setDraggingFrame(CGRect(x: thumb.midX - size.width / 2, y: thumb.midY - size.height / 2,
                        width: size.width, height: size.height), contents: icon)
                }
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
        var items = [(configuration.openInNewTabTitle, #selector(openMenuFolder))]
        if configuration.rename != nil { items.append((configuration.renameTitle, #selector(renameMenuFolder))) }
        items.append((configuration.showInFinderTitle, #selector(revealMenuFolder)))
        for (title, action) in items {
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
    @objc private func renameMenuFolder() {
        guard let id = menuFolderID, let index = indicesByID[id], let configuration else { return }
        configuration.rename?(configuration.folders[index])
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
