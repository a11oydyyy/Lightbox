import AppKit
import SwiftUI

struct RubberBandSelectionLayer: NSViewRepresentable {
    var assetFrames: [LightboxAsset.ID: CGRect]
    var excludedFrames: [CGRect] = []
    var visibleAssetIDs: [LightboxAsset.ID]
    var selectedAssetIDs: Set<LightboxAsset.ID>
    var onSelectionRectChange: (CGRect?) -> Void
    var onSelectionChange: (Set<LightboxAsset.ID>) -> Void

    func makeNSView(context: Context) -> RubberBandSelectionView {
        RubberBandSelectionView()
    }

    func updateNSView(_ nsView: RubberBandSelectionView, context: Context) {
        nsView.assetFrames = assetFrames
        nsView.excludedFrames = excludedFrames
        nsView.visibleAssetIDs = visibleAssetIDs
        nsView.selectedAssetIDs = selectedAssetIDs
        nsView.onSelectionRectChange = onSelectionRectChange
        nsView.onSelectionChange = onSelectionChange
    }
}

final class RubberBandSelectionView: NSView {
    var assetFrames: [LightboxAsset.ID: CGRect] = [:]
    var excludedFrames: [CGRect] = []
    var visibleAssetIDs: [LightboxAsset.ID] = []
    var selectedAssetIDs: Set<LightboxAsset.ID> = []
    var onSelectionRectChange: (CGRect?) -> Void = { _ in }
    var onSelectionChange: (Set<LightboxAsset.ID>) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent ?? NSApp.currentEvent,
              event.type == .leftMouseDown,
              !assetFrames.isEmpty
        else {
            return nil
        }

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
        var didDrag = false

        while true {
            guard let nextEvent = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                return
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                let currentPoint = selectionPoint(for: nextEvent)
                let rect = selectionRect(from: startPoint, to: currentPoint)
                guard rect.width > 3 || rect.height > 3 else { continue }

                didDrag = true
                onSelectionRectChange(rect)

                var selectedIDs = intersectingAssetIDs(in: rect)
                if extendsSelection {
                    selectedIDs.formUnion(baseSelection)
                }
                onSelectionChange(selectedIDs)

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

    private func intersectingAssetIDs(in selectionRect: CGRect) -> Set<LightboxAsset.ID> {
        Set(
            visibleAssetIDs.filter { id in
                guard let frame = assetFrames[id] else { return false }
                return frame.intersects(selectionRect)
            }
        )
    }
}
