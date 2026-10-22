import AppKit
import ImageIO
import SwiftUI

/// The preview at 100%, for checking focus: one image pixel per screen pixel.
/// Drag or scroll to move around, pinch to zoom further (up to 400%) or out
/// to the whole image; a click without a drag goes back to the fitted preview.
/// Stepping to another image keeps the same spot, so a burst can be compared.
///
/// The full-resolution image is decoded here, for the shown image only, and
/// never enters the shared thumbnail cache.
struct PreviewLoupe: NSViewRepresentable {
    var asset: LightboxAsset
    /// The fitted preview's frame in this view's (top-left) coordinates. Where
    /// the pointer is on it when the loupe opens is where the loupe looks.
    var imageFrame: CGRect
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> PreviewLoupeView {
        let view = PreviewLoupeView()
        view.onDismiss = onDismiss
        view.show(asset, imageFrame: imageFrame)
        return view
    }

    func updateNSView(_ view: PreviewLoupeView, context: Context) {
        view.onDismiss = onDismiss
        view.show(asset, imageFrame: imageFrame)
    }

    static func dismantleNSView(_ view: PreviewLoupeView, coordinator: ()) {
        view.cancelDecode()
    }
}

final class PreviewLoupeView: NSView {
    var onDismiss: () -> Void = {}
    private let scrollView = NSScrollView()
    private let imageView = PreviewLoupeImageView()
    private var assetID: LightboxAsset.ID?
    private var decodeTask: Task<Void, Never>?
    /// What the loupe looks at, as a fraction of the image; kept across steps.
    private var focus: CGPoint?
    /// Set when it opens: read once the view is in the window and laid out.
    private var pointerImageFrame: CGRect?
    private var needsCentering = false
    private var hasFullResolution = false
    private var pixelSize = CGSize(width: 1, height: 1)
    private var documentScale: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 4
        scrollView.contentView = PreviewLoupeClipView()
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = imageView
        scrollView.autoresizingMask = [.width, .height]
        imageView.onClick = { [weak self] in self?.onDismiss() }
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateMinimumMagnification()
        guard needsCentering, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        needsCentering = false
        if let frame = pointerImageFrame {
            pointerImageFrame = nil
            focus = pointerFocus(in: frame)
        }
        center(on: focus ?? CGPoint(x: 0.5, y: 0.5))
    }

    func show(_ asset: LightboxAsset, imageFrame: CGRect) {
        guard asset.id != assetID, let url = asset.sourceURL else { return }
        if assetID == nil {
            pointerImageFrame = imageFrame
        } else if !needsCentering {
            focus = visibleFocus()
        }
        assetID = asset.id

        hasFullResolution = false
        display(nil, pixelSize: CGSize(width: max(1, asset.width), height: max(1, asset.height)))
        // The preview (usually in memory already) stands in, stretched, until
        // the full image is decoded.
        ImageCache.shared.image(for: url, quality: .preview, knownFileSignature: asset.fileContentSignature,
                                priority: .high) { [weak self] image in
            guard let self, self.assetID == asset.id, !self.hasFullResolution else { return }
            self.imageView.image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.decodeFullResolution(url) }.value
            guard let self, !Task.isCancelled, self.assetID == asset.id, let image else { return }
            self.hasFullResolution = true
            self.imageView.image = image
            // Usually the size the asset already had; otherwise keep the same
            // spot and zoom on the corrected size rather than starting over.
            let size = CGSize(width: image.width, height: image.height)
            guard size != self.pixelSize else { return }
            let focus = self.needsCentering ? nil : self.visibleFocus()
            self.pixelSize = size
            self.sizeDocument()
            if let focus { self.focus = focus }
            self.needsCentering = true
            self.needsLayout = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 100% depends on the screen it is shown on; the first sizing ran
        // before the view had a window.
        guard let window, window.backingScaleFactor != documentScale else { return }
        sizeDocument()
        needsCentering = true
        needsLayout = true
    }

    func cancelDecode() {
        decodeTask?.cancel()
    }

    /// A new image at 100%.
    private func display(_ image: CGImage?, pixelSize: CGSize) {
        imageView.image = image
        self.pixelSize = pixelSize
        sizeDocument()
        scrollView.magnification = 1
        needsCentering = true
        needsLayout = true
    }

    /// One image pixel per screen pixel on the screen it is shown on.
    private func sizeDocument() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        documentScale = scale
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale))
        updateMinimumMagnification()
    }

    /// Down to the whole image fitting the window (or 100% for a small one).
    private func updateMinimumMagnification() {
        let document = imageView.frame.size
        guard document.width > 0, document.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        scrollView.minMagnification = min(1, bounds.width / document.width, bounds.height / document.height)
    }

    private func center(on point: CGPoint) {
        // The clip view may not be laid out for the new size yet; what it
        // will show follows from the scroll view's size and magnification.
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let document = imageView.frame.size
        let visible = CGSize(width: scrollView.contentSize.width / scrollView.magnification,
                             height: scrollView.contentSize.height / scrollView.magnification)
        let origin = CGPoint(x: document.width * point.x - visible.width / 2,
                             y: document.height * point.y - visible.height / 2)
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: visible)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func visibleFocus() -> CGPoint {
        let document = imageView.frame.size
        guard document.width > 0, document.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let visible = scrollView.contentView.bounds
        return CGPoint(x: min(1, max(0, visible.midX / document.width)),
                       y: min(1, max(0, visible.midY / document.height)))
    }

    private func pointerFocus(in imageFrame: CGRect) -> CGPoint {
        guard let window, imageFrame.width > 0, imageFrame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard imageFrame.contains(pointer) else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (pointer.x - imageFrame.minX) / imageFrame.width,
                       y: (pointer.y - imageFrame.minY) / imageFrame.height)
    }

    /// The whole image at its pixel size, rotated upright. RAW files are
    /// developed with Apple's defaults, not Camera Raw's settings.
    nonisolated static func decodeFullResolution(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Keeps an image smaller than the window in its middle.
private final class PreviewLoupeClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

/// The image; dragging it moves the view, a click without a drag dismisses.
private final class PreviewLoupeImageView: NSView {
    var onClick: () -> Void = {}
    var image: CGImage? {
        didSet { layer?.contents = image }
    }
    private var pressLocation: NSPoint?
    private var dragStart: NSPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        // Pixels stay crisp past 100%, where focus is judged.
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        dragStart = event.locationInWindow
        didDrag = false
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let press = pressLocation, let clip = superview as? NSClipView else { return }
        let location = event.locationInWindow
        let magnification = enclosingScrollView?.magnification ?? 1
        if hypot(location.x - press.x, location.y - press.y) > 3 { didDrag = true }
        // Window coordinates grow upward; this view's grow downward.
        var origin = clip.bounds.origin
        origin.x -= (location.x - start.x) / magnification
        origin.y += (location.y - start.y) / magnification
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        dragStart = location
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        dragStart = nil
        pressLocation = nil
        if !didDrag { onClick() }
    }
}
