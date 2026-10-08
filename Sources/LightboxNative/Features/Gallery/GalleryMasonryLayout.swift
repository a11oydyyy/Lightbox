import AppKit
import SwiftUI

struct GalleryMasonryFrameKey: LayoutValueKey {
    static let defaultValue = CGRect.zero
}

struct GalleryMasonryLayout: Layout {
    var width: CGFloat
    var height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let frame = subview[GalleryMasonryFrameKey.self]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

struct GalleryMasonryPlacement {
    private struct Entry {
        var asset: LightboxAsset
        var frame: CGRect
        var order: Int
    }
    private var entriesByColumn: [[Entry]] = []
    var frames: [LightboxAsset.ID: CGRect] = [:]
    var height: CGFloat = 0

    init(columns: [[LightboxAsset]], itemWidth: CGFloat, spacing: CGFloat, orderedAssets: [LightboxAsset] = []) {
        let orderByID = Dictionary(orderedAssets.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for (index, assets) in columns.enumerated() {
            var y: CGFloat = 0
            var entries: [Entry] = []
            for asset in assets {
                let h = itemWidth / max(0.35, asset.aspectRatio)
                let frame = CGRect(x: CGFloat(index) * (itemWidth + spacing), y: y, width: itemWidth, height: h)
                frames[asset.id] = frame
                entries.append(Entry(asset: asset, frame: frame, order: orderByID[asset.id] ?? frames.count))
                y += h + spacing
            }
            entriesByColumn.append(entries)
            height = max(height, max(0, y - spacing))
        }
    }

    func assets(intersecting rect: CGRect) -> [LightboxAsset] {
        guard !rect.isEmpty else { return [] }
        var visible: [Entry] = []
        for column in entriesByColumn {
            var low = 0
            var high = column.count
            while low < high {
                let middle = (low + high) / 2
                if column[middle].frame.maxY < rect.minY { low = middle + 1 }
                else { high = middle }
            }
            while low < column.count, column[low].frame.minY <= rect.maxY {
                if column[low].frame.intersects(rect) { visible.append(column[low]) }
                low += 1
            }
        }
        return visible.sorted { $0.order < $1.order }.map(\.asset)
    }
}

@MainActor final class GalleryMasonryPlacementCache {
    private struct Entry {
        var revision: Int
        var width: CGFloat
        var columnCount: Int
        var placement: GalleryMasonryPlacement
    }
    private var entries: [String: Entry] = [:]
    func placement(identity: String, revision: Int, columns: [[LightboxAsset]],
                   itemWidth: CGFloat, assets: [LightboxAsset]) -> GalleryMasonryPlacement {
        if let entry = entries[identity], entry.revision == revision,
           entry.width == itemWidth, entry.columnCount == columns.count { return entry.placement }
        let placement = GalleryMasonryPlacement(columns: columns, itemWidth: itemWidth,
            spacing: SpacingTokens.regular, orderedAssets: assets)
        entries[identity] = Entry(revision: revision, width: itemWidth, columnCount: columns.count, placement: placement)
        return placement
    }
    func retain(identities: Set<String>) { entries = entries.filter { identities.contains($0.key) } }
    func removeAll() { entries.removeAll() }
}

struct GalleryVirtualMasonryGrid<Card: View>: View {
    var placement: GalleryMasonryPlacement
    var width: CGFloat
    var viewportHeight: CGFloat
    var isScaling: Bool
    var revealAssetIDs: Set<LightboxAsset.ID>
    var framesChanged: ([LightboxAsset.ID: CGRect], Set<LightboxAsset.ID>, Set<LightboxAsset.ID>, UUID) -> Void
    @ViewBuilder var card: (LightboxAsset) -> Card
    @LightboxViewState private var mountRevision = 0
    @LightboxViewState private var viewportState = GalleryMasonryViewportState()
    @LightboxViewState private var frameOwner = GalleryMasonryFrameOwner()

    private var mountMargin: CGFloat { isScaling ? 32 : max(120, viewportHeight * 0.25) }

    private var loadRect: CGRect {
        let rect = viewportState.rect.isEmpty ? CGRect(x: 0, y: 0, width: width, height: viewportHeight) : viewportState.rect
        return rect.insetBy(dx: 0, dy: -mountMargin)
    }

    var body: some View {
        let _ = mountRevision
        let visible = placement.assets(intersecting: loadRect)
        let _ = viewportState.mountedIDs = visible.map(\.id)
        let mountedIDs = Set(visible.map(\.id))
        GalleryMasonryLayout(width: width, height: placement.height) {
            ForEach(visible) { asset in
                card(asset).layoutValue(key: GalleryMasonryFrameKey.self, value: placement.frames[asset.id] ?? .zero)
            }
            // ScrollViewReader needs a real target even when its card is offscreen.
            // Only requested keyboard/restore targets get a lightweight marker.
            ForEach(revealAssetIDs.subtracting(mountedIDs).sorted(), id: \.self) { id in
                if let frame = placement.frames[id] {
                    Color.clear.frame(width: frame.width, height: frame.height)
                        .id(id).accessibilityHidden(true).allowsHitTesting(false)
                        .layoutValue(key: GalleryMasonryFrameKey.self, value: frame)
                }
            }
        }
        .background {
            // The deterministic layout already knows every card rect. One grid
            // origin replaces a GeometryReader and preference callback per card.
            GeometryReader { geometry in
                let origin = geometry.frame(in: .named("GalleryContent")).origin
                Color.clear.preference(key: GalleryMasonryFramesKey.self, value: Dictionary(
                    uniqueKeysWithValues: visible.compactMap { asset in
                        placement.frames[asset.id].map { (asset.id, $0.offsetBy(dx: origin.x, dy: origin.y)) }
                    }))
            }
        }
        .onPreferenceChange(GalleryMasonryFramesKey.self) { frames in
            guard frameOwner.isActive else { return }
            let ids = Set(frames.keys)
            let removed = frameOwner.ids.subtracting(ids)
            let added = ids.subtracting(frameOwner.ids)
            frameOwner.ids = ids
            framesChanged(frames, removed, added, frameOwner.id)
        }
        .background(GalleryMasonryViewportProbe { rect in
            let next = placement.assets(intersecting: rect.insetBy(dx: 0, dy: -mountMargin)).map(\.id)
            viewportState.rect = rect
            // Pixel scrolling updates geometry/load priorities elsewhere. Only
            // change this subtree when a card enters or leaves the mount window.
            if next != viewportState.mountedIDs {
                viewportState.mountedIDs = next
                mountRevision &+= 1
            }
        })
        .onAppear { frameOwner.isActive = true }
        .onDisappear {
            frameOwner.isActive = false
            framesChanged([:], frameOwner.ids, [], frameOwner.id)
            frameOwner.ids = []
        }
    }
}

private final class GalleryMasonryViewportState {
    var rect = CGRect.zero
    var mountedIDs: [LightboxAsset.ID] = []
}

private final class GalleryMasonryFrameOwner {
    let id = UUID()
    var isActive = true
    var ids: Set<LightboxAsset.ID> = []
}

private struct GalleryMasonryFramesKey: PreferenceKey {
    static let defaultValue: [LightboxAsset.ID: CGRect] = [:]
    static func reduce(value: inout [LightboxAsset.ID: CGRect], nextValue: () -> [LightboxAsset.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct GalleryMasonryViewportProbe: NSViewRepresentable {
    var changed: (CGRect) -> Void
    func makeNSView(context: Context) -> GalleryMasonryViewportView { GalleryMasonryViewportView() }
    func updateNSView(_ view: GalleryMasonryViewportView, context: Context) {
        view.changed = changed
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: GalleryMasonryViewportView, coordinator: ()) { view.detach() }
}

private final class GalleryMasonryViewportView: NSView {
    var changed: ((CGRect) -> Void)?
    private weak var clip: NSClipView?
    private var token: NSObjectProtocol?
    private var pending = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        if let clip = enclosingScrollView?.contentView {
            self.clip = clip
            clip.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                }
        }
        scheduleUpdate()
    }
    override func layout() { super.layout(); scheduleUpdate() }
    func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard let clip = self.clip, self.window != nil else { return }
            self.changed?(self.convert(clip.bounds, from: clip))
        }
    }
    func detach() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        clip = nil
    }
}
