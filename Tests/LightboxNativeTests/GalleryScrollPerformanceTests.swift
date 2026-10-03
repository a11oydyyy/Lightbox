import AppKit
import SwiftUI
import Testing
@testable import LightboxNative

@MainActor
@Test func galleryScrollOriginUpdatesReplacePerCardSubmissions() {
    let geometry = GalleryScrollGeometry()
    let frames = Dictionary(uniqueKeysWithValues: (0..<60).map { index in
        ("photo-\(index)", CGRect(x: index * 20, y: 180, width: 16, height: 100))
    })
    for (id, frame) in frames { geometry.updateContentFrame(frame, for: id) }
    let ids = Set(frames.keys)
    let plan = GalleryRenderPlan(loadableAssetIDs: ids, prioritizedAssetIDs: ids, settledVisibleAssetIDs: [])
    #expect(geometry.replaceRenderPlan(plan))
    var oldAbsoluteFrameSubmissions = 0
    var originUpdates = 0
    var contentFrameSubmissions = 0
    var renderPublications = 0
    for step in 1...120 {
        let selectionOrigin = CGPoint(x: 11, y: -CGFloat(step))
        let previewOrigin = CGPoint(x: 42, y: 23 - CGFloat(step))
        geometry.updateOrigin(.init(selection: selectionOrigin, preview: previewOrigin, scrollOffset: CGFloat(step)))
        originUpdates += 1
        let selectionFrames = geometry.selectionFrames
        let previewFrames = geometry.previewFrames
        for (id, frame) in frames {
            oldAbsoluteFrameSubmissions += 2
            #expect(selectionFrames[id] == frame.offsetBy(dx: selectionOrigin.x, dy: selectionOrigin.y))
            #expect(previewFrames[id] == frame.offsetBy(dx: previewOrigin.x, dy: previewOrigin.y))
            if geometry.contentFrames[id] != frame { contentFrameSubmissions += 1 }
        }
        // All 60 cards stay within this viewport and preload window.
        let visible = Set(geometry.selectionFrames.compactMap { id, frame in
            GalleryImagePriorityPlanner.isVisible(frame, viewportHeight: 1000) ? id : nil
        })
        let nextPlan = GalleryRenderPlan(loadableAssetIDs: visible, prioritizedAssetIDs: visible, settledVisibleAssetIDs: [])
        if geometry.replaceRenderPlan(nextPlan) { renderPublications += 1 }
    }
    #expect(oldAbsoluteFrameSubmissions == 14_400)
    #expect(originUpdates == 120)
    #expect(contentFrameSubmissions == 0)
    #expect(renderPublications == 0)
}

@MainActor
@Test func galleryScrollSmallMovementKeepsImmediateInteractionFrames() throws {
    let geometry = GalleryScrollGeometry()
    let frame = CGRect(x: 40, y: 70, width: 60, height: 50)
    geometry.updateContentFrame(frame, for: "photo")
    geometry.folderFrame = CGRect(x: 0, y: 0, width: 400, height: 40)
    geometry.groupHeaderFrames = ["group": CGRect(x: 10, y: 45, width: 350, height: 20)]
    geometry.updateOrigin(.init(selection: CGPoint(x: 8, y: -12), preview: CGPoint(x: 28, y: 18), scrollOffset: 12))
    let current = try #require(geometry.selectionFrames["photo"])
    #expect(current == frame.offsetBy(dx: 8, dy: -12))
    let movedEdge = CGPoint(x: current.midX, y: current.minY + 1)
    #expect(RubberBandSelectionView.isInsideAssetFrame(movedEdge, assetFrames: Array(geometry.selectionFrames.values)))
    #expect(!RubberBandSelectionView.isInsideAssetFrame(movedEdge, assetFrames: [frame]))
    #expect(RubberBandSelectionView.intersectingAssetIDs(
        in: CGRect(x: current.midX, y: current.minY + 1, width: 1, height: 1),
        assetFrames: geometry.selectionFrames, activeAssetIDs: ["photo"]
    ) == ["photo"])
    #expect(geometry.previewFrames["photo"] == frame.offsetBy(dx: 28, dy: 18))
    #expect(geometry.exclusionFrames.contains(CGRect(x: 8, y: -12, width: 400, height: 40)))
    // Top rubber-band overscroll is a signed translation, even with zero scroll offset.
    geometry.updateOrigin(.init(selection: CGPoint(x: 8, y: 9), preview: CGPoint(x: 28, y: 39), scrollOffset: 0))
    #expect(geometry.selectionFrames["photo"]?.minY == 79)
}

@MainActor
@Test func galleryScrollLayoutCollapseAndNavigationInvalidateGeometry() async throws {
    let geometry = GalleryScrollGeometry()
    geometry.updateContentFrame(CGRect(x: 10, y: 40, width: 80, height: 120), for: "photo")
    geometry.updateContentFrame(CGRect(x: 100, y: 40, width: 80, height: 120), for: "collapsed")
    geometry.updateOrigin(.init(selection: CGPoint(x: 0, y: -10), preview: CGPoint(x: 20, y: 15), scrollOffset: 10))
    let resized = CGRect(x: 12, y: 60, width: 70, height: 105)
    geometry.updateContentFrame(resized, for: "photo")
    #expect(geometry.selectionFrames["photo"] == resized.offsetBy(dx: 0, dy: -10))
    geometry.remove("collapsed")
    #expect(geometry.previewFrames["collapsed"] == nil)
    geometry.retain(activeAssetIDs: ["other"])
    #expect(geometry.contentFrames.isEmpty)
    geometry.folderFrame = CGRect(x: 0, y: 0, width: 400, height: 50)
    geometry.groupHeaderFrames = ["group": CGRect(x: 0, y: 50, width: 400, height: 30)]
    var settled = false
    geometry.scheduleScrollSettled { settled = true }
    #expect(geometry.resetIfNeeded(navigationToken: "folder-a"))
    geometry.updateContentFrame(resized, for: "new")
    #expect(!geometry.resetIfNeeded(navigationToken: "folder-a"))
    #expect(geometry.contentFrames["new"] == resized)
    #expect(geometry.resetIfNeeded(navigationToken: "folder-b"))
    #expect(geometry.contentFrames.isEmpty)
    geometry.clear()
    try await Task.sleep(for: .milliseconds(220))
    #expect(!settled)
    #expect(geometry.selectionFrames.isEmpty)
    #expect(geometry.previewFrames.isEmpty)
    #expect(geometry.exclusionFrames.isEmpty)
    #expect(geometry.renderPlan == nil)
}

@MainActor
private final class GalleryNativeGeometryMeasurements {
    var contentFrame: CGRect?
    var selectionFrame: CGRect?
    var previewFrame: CGRect?
    var origin: GalleryContentOrigin?
    var contentChanges = 0
    var absoluteChanges = 0
    var originChanges = 0
}

private struct GalleryNativeGeometryFixture: View {
    var measurements: GalleryNativeGeometryMeasurements

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 31)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 90)
                    Color.blue.frame(width: 140, height: 100)
                        .background {
                            GeometryReader { proxy in
                                let content = proxy.frame(in: .named("GalleryContent"))
                                let selection = proxy.frame(in: .named("GallerySelectionSpace"))
                                let preview = proxy.frame(in: .named("PreviewSpace"))
                                Color.clear
                                    .onAppear {
                                        measurements.contentFrame = content
                                        measurements.selectionFrame = selection
                                        measurements.previewFrame = preview
                                    }
                                    .onChange(of: content) { frame in
                                        measurements.contentFrame = frame
                                        measurements.contentChanges += 1
                                    }
                                    .onChange(of: selection) { frame in
                                        measurements.selectionFrame = frame
                                        measurements.absoluteChanges += 1
                                    }
                                    .onChange(of: preview) { frame in
                                        measurements.previewFrame = frame
                                        measurements.absoluteChanges += 1
                                    }
                            }
                        }
                    Color.clear.frame(height: 1800)
                }
                .padding(.top, 58)
                .padding(.bottom, 92)
                .frame(maxWidth: .infinity)
                .coordinateSpace(name: "GalleryContent")
                .background {
                    GeometryReader { proxy in
                        let origin = GalleryContentOrigin(
                            selection: proxy.frame(in: .named("GallerySelectionSpace")).origin,
                            preview: proxy.frame(in: .named("PreviewSpace")).origin,
                            scrollOffset: max(0, -proxy.frame(in: .named("GallerySelectionSpace")).minY)
                        )
                        Color.clear
                            .onAppear { measurements.origin = origin }
                            .onChange(of: origin) { origin in
                                measurements.origin = origin
                                measurements.originChanges += 1
                            }
                    }
                }
            }
            .coordinateSpace(name: "GallerySelectionSpace")
        }
        .coordinateSpace(name: "PreviewSpace")
    }
}

@MainActor
@Test func galleryScrollNativeContentCoordinatesStayStable() async throws {
    let measurements = GalleryNativeGeometryMeasurements()
    let host = NSHostingView(rootView: GalleryNativeGeometryFixture(measurements: measurements))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(40))
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
    let scroll = try #require(scrollView(in: host))
    let initial = try #require(measurements.contentFrame)
    #expect(initial.minY == 148) // Content coordinates include the gallery top padding.
    measurements.contentChanges = 0
    measurements.absoluteChanges = 0
    measurements.originChanges = 0
    for offset in [12, 24, 36, 48] {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let origin = try #require(measurements.origin)
        #expect(abs(origin.selection.y + CGFloat(offset)) < 0.5)
        #expect(measurements.contentFrame == initial)
        #expect(measurements.selectionFrame == initial.offsetBy(dx: origin.selection.x, dy: origin.selection.y))
        #expect(measurements.previewFrame == initial.offsetBy(dx: origin.preview.x, dy: origin.preview.y))
        #expect(abs(origin.preview.y - origin.selection.y - 31) < 0.5)
    }
    #expect(measurements.contentChanges == 0)
    #expect(measurements.originChanges > 0)
    #expect(measurements.absoluteChanges >= measurements.originChanges * 2)
}
