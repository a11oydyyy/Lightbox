import AppKit
import SwiftUI

struct RubberBandSelectionLayer: NSViewRepresentable {
    var assetFrames: [LightboxAsset.ID: CGRect]
    var frameProvider: (() -> [LightboxAsset.ID: CGRect])? = nil
    /// Card frames in the scroll content's own coordinates, and where that
    /// content's origin sits in this layer: with them the selection follows
    /// the content as it scrolls during a drag.
    var contentFrameProvider: (() -> [LightboxAsset.ID: CGRect])? = nil
    var contentOriginProvider: (() -> CGPoint)? = nil
    var scrollViewProvider: (() -> NSScrollView?)? = nil
    var excludedFrameProvider: (() -> [CGRect])? = nil
    var excludedFrames: [CGRect] = []
    var activeAssetIDs: Set<LightboxAsset.ID>
    var selectedAssetIDs: Set<LightboxAsset.ID>
    var onSelectionRectChange: (CGRect?) -> Void
    var onSelectionChange: (Set<LightboxAsset.ID>) -> Void

    func makeNSView(context: Context) -> RubberBandSelectionView {
        RubberBandSelectionView()
    }

    func updateNSView(_ nsView: RubberBandSelectionView, context: Context) {
        nsView.assetFrames = assetFrames
        nsView.frameProvider = frameProvider
        nsView.contentFrameProvider = contentFrameProvider
        nsView.contentOriginProvider = contentOriginProvider
        nsView.scrollViewProvider = scrollViewProvider
        nsView.excludedFrameProvider = excludedFrameProvider
        nsView.excludedFrames = excludedFrames
        nsView.activeAssetIDs = activeAssetIDs
        nsView.selectedAssetIDs = selectedAssetIDs
        nsView.onSelectionRectChange = onSelectionRectChange
        nsView.onSelectionChange = onSelectionChange
    }
}

final class RubberBandSelectionView: NSView {
    var assetFrames: [LightboxAsset.ID: CGRect] = [:]
    var frameProvider: (() -> [LightboxAsset.ID: CGRect])? = nil
    var contentFrameProvider: (() -> [LightboxAsset.ID: CGRect])? = nil
    var contentOriginProvider: (() -> CGPoint)? = nil
    var scrollViewProvider: (() -> NSScrollView?)? = nil
    var excludedFrameProvider: (() -> [CGRect])? = nil
    var excludedFrames: [CGRect] = []
    var activeAssetIDs: Set<LightboxAsset.ID> = []
    /// How close to the top or bottom edge a drag starts scrolling, as
    /// Finder's does; the bars float over these edges.
    var autoscrollEdge: CGFloat = 64
    var selectedAssetIDs: Set<LightboxAsset.ID> = []
    var onSelectionRectChange: (CGRect?) -> Void = { _ in }
    var onSelectionChange: (Set<LightboxAsset.ID>) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent ?? NSApp.currentEvent,
              event.type == .leftMouseDown else { return nil }
        let assetFrames = frameProvider?() ?? assetFrames
        guard !assetFrames.isEmpty else { return nil }
        let excludedFrames = excludedFrames + (excludedFrameProvider?() ?? [])

        let selectionPoint = Self.selectionPoint(from: point, boundsHeight: bounds.height)
        guard !Self.contains(selectionPoint, in: excludedFrames) else {
            return nil
        }

        guard !Self.isAboveSelectableAssetArea(selectionPoint, assetFrames: Array(assetFrames.values)) else {
            return nil
        }

        let isInsideAsset = Self.isInsideAssetFrame(selectionPoint, assetFrames: Array(assetFrames.values))
        return isInsideAsset ? nil : self
    }

    nonisolated static func selectionPoint(from point: CGPoint, boundsHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: boundsHeight - point.y)
    }

    nonisolated static func isAboveSelectableAssetArea(_ point: CGPoint, assetFrames: [CGRect]) -> Bool {
        guard let firstAssetTop = assetFrames.map(\.minY).min() else {
            return false
        }

        return point.y < firstAssetTop
    }

    nonisolated static func isInsideAssetFrame(_ point: CGPoint, assetFrames: [CGRect]) -> Bool {
        assetFrames.contains { frame in
            let targetFrame = frame.insetBy(dx: -2, dy: -2)
            return targetFrame.contains(point)
        }
    }

    nonisolated private static func contains(_ point: CGPoint, in frames: [CGRect]) -> Bool {
        frames.contains { frame in
            let hitFrame = frame.insetBy(dx: -4, dy: -4)
            return hitFrame.contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        let startPoint = selectionPoint(for: event)
        let baseSelection = selectedAssetIDs
        let extendsSelection = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        let scrollView = scrollViewProvider?()
        // The content's origin moves with the scroll view's clip; tracking
        // the clip directly keeps up even before SwiftUI reports the move.
        let startScroll = scrollView?.contentView.bounds.origin.y ?? 0
        let startOrigin = contentOriginProvider?() ?? .zero
        func contentOrigin() -> CGPoint {
            let scrolled = (scrollView?.contentView.bounds.origin.y ?? 0) - startScroll
            return CGPoint(x: startOrigin.x, y: startOrigin.y - scrolled)
        }
        let startContentPoint = CGPoint(x: startPoint.x - startOrigin.x, y: startPoint.y - startOrigin.y)
        // Cards scrolled far away unmount and drop their frames; keep the last
        // known ones so they stay selected while the rectangle still covers them.
        var knownFrames: [LightboxAsset.ID: CGRect] = [:]
        var lastPoint = startPoint
        var didDrag = false

        func update() {
            let origin = contentOrigin()
            let currentContentPoint = CGPoint(x: lastPoint.x - origin.x, y: lastPoint.y - origin.y)
            let rect = selectionRect(from: startContentPoint, to: currentContentPoint)
            guard didDrag || rect.width > 3 || rect.height > 3 else { return }

            didDrag = true
            onSelectionRectChange(rect.offsetBy(dx: origin.x, dy: origin.y))

            knownFrames.merge(contentFrames(), uniquingKeysWith: { _, new in new })
            var selectedIDs = Self.intersectingAssetIDs(in: rect, assetFrames: knownFrames, activeAssetIDs: activeAssetIDs)
            if extendsSelection {
                selectedIDs.formUnion(baseSelection)
            }
            onSelectionChange(selectedIDs)
        }

        while true {
            // Wakes about 60 times a second while held still, to keep scrolling
            // when the pointer rests near an edge.
            let nextEvent = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .scrollWheel],
                until: Date(timeIntervalSinceNow: 1.0 / 60),
                inMode: .eventTracking,
                dequeue: true
            )
            guard let nextEvent else {
                if didDrag, let scrollView,
                   Self.scroll(scrollView, by: Self.autoscrollStep(at: lastPoint.y, height: bounds.height, edge: autoscrollEdge)) {
                    update()
                }
                continue
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                lastPoint = selectionPoint(for: nextEvent)
                update()

            case .scrollWheel:
                // The trackpad or wheel still scrolls while selecting.
                scrollView?.scrollWheel(with: nextEvent)
                if didDrag { update() }

            case .leftMouseUp:
                onSelectionRectChange(nil)
                if !didDrag, !extendsSelection {
                    onSelectionChange([])
                }
                return

            default:
                break
            }
        }
    }

    /// Points to scroll per tick for a pointer at `y` (from the top): nothing
    /// outside the edge bands, faster the deeper in, fastest past the edge.
    nonisolated static func autoscrollStep(at y: CGFloat, height: CGFloat, edge: CGFloat) -> CGFloat {
        func speed(_ depth: CGFloat) -> CGFloat { min(36, 3 + depth * 0.45) }
        if y < edge { return -speed(edge - y) }
        if y > height - edge { return speed(y - (height - edge)) }
        return 0
    }

    /// Scrolls `scrollView` by `dy` within its content; whether it moved.
    @discardableResult
    static func scroll(_ scrollView: NSScrollView, by dy: CGFloat) -> Bool {
        guard dy != 0 else { return false }
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin.y += dy
        let target = clip.constrainBoundsRect(proposed).origin
        guard abs(target.y - clip.bounds.origin.y) > 0.5 else { return false }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    private func contentFrames() -> [LightboxAsset.ID: CGRect] {
        contentFrameProvider?() ?? frameProvider?() ?? assetFrames
    }

    private func selectionRect(from startPoint: CGPoint, to currentPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    private func selectionPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return Self.selectionPoint(from: point, boundsHeight: bounds.height)
    }

    nonisolated static func intersectingAssetIDs(
        in selectionRect: CGRect,
        assetFrames: [LightboxAsset.ID: CGRect],
        activeAssetIDs: Set<LightboxAsset.ID>
    ) -> Set<LightboxAsset.ID> {
        assetFrames.reduce(into: []) { selectedIDs, entry in
            guard activeAssetIDs.contains(entry.key), entry.value.intersects(selectionRect) else { return }
            selectedIDs.insert(entry.key)
        }
    }
}
