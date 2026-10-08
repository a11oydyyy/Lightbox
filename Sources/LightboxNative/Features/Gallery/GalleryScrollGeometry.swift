import AppKit

struct GalleryContentOrigin: Equatable {
    var selection: CGPoint
    var preview: CGPoint
    var scrollOffset: CGFloat
}

struct GalleryRenderPlan: Equatable {
    var loadableAssetIDs: Set<LightboxAsset.ID>
    var prioritizedAssetIDs: Set<LightboxAsset.ID>
    var settledVisibleAssetIDs: Set<LightboxAsset.ID>
}

// Geometry is interaction data. Moving it does not invalidate the SwiftUI grid.
@MainActor
final class GalleryScrollGeometry {
    let imageLoading = GalleryImageLoadingCoordinator()
    var isScrolling = false
    var scrollDirection: GalleryScrollDirection = .stationary
    private(set) var navigationToken: String?
    private(set) var contentFrames: [LightboxAsset.ID: CGRect] = [:]
    private var frameOwners: [LightboxAsset.ID: UUID] = [:]
    var folderFrame: CGRect?
    var groupHeaderFrames: [String: CGRect] = [:]
    private(set) var origin = GalleryContentOrigin(selection: .zero, preview: .zero, scrollOffset: 0)
    private(set) var renderPlan: GalleryRenderPlan?
    private var settleTask: Task<Void, Never>?

    @discardableResult
    func resetIfNeeded(navigationToken: String) -> Bool {
        guard self.navigationToken != navigationToken else { return false }
        clear()
        self.navigationToken = navigationToken
        return true
    }

    @discardableResult
    func updateContentFrame(_ frame: CGRect, for id: LightboxAsset.ID,
                            owner: UUID? = nil, registering: Bool = true) -> Bool {
        // Lazy columns can mount a replacement before the previous card leaves.
        // Only the currently registered instance may update or remove its frame.
        if let owner, !registering, frameOwners[id] != owner { return false }
        frameOwners[id] = owner
        contentFrames[id] = frame
        return true
    }

    @discardableResult
    func remove(_ id: LightboxAsset.ID, owner: UUID? = nil) -> Bool {
        if let owner, frameOwners[id] != owner { return false }
        frameOwners.removeValue(forKey: id)
        contentFrames.removeValue(forKey: id)
        return true
    }

    func retain(activeAssetIDs: Set<LightboxAsset.ID>) {
        imageLoading.retain(activeAssetIDs: activeAssetIDs)
        contentFrames = GalleryAssetFrameLifecycle.activeFrames(contentFrames, activeAssetIDs: activeAssetIDs)
        frameOwners = frameOwners.filter { activeAssetIDs.contains($0.key) }
    }

    func updateOrigin(_ origin: GalleryContentOrigin) {
        self.origin = origin
    }

    var selectionFrames: [LightboxAsset.ID: CGRect] {
        translatedFrames(by: origin.selection)
    }

    var previewFrames: [LightboxAsset.ID: CGRect] {
        translatedFrames(by: origin.preview)
    }

    var exclusionFrames: [CGRect] {
        let frames = (folderFrame.map { [$0] } ?? []) + Array(groupHeaderFrames.values)
        return frames.map { $0.offsetBy(dx: origin.selection.x, dy: origin.selection.y) }
    }

    private func translatedFrames(by point: CGPoint) -> [LightboxAsset.ID: CGRect] {
        contentFrames.mapValues { $0.offsetBy(dx: point.x, dy: point.y) }
    }

    // The caller publishes only when card loading/quality actually changes.
    func replaceRenderPlan(_ plan: GalleryRenderPlan) -> Bool {
        guard renderPlan != plan else { return false }
        renderPlan = plan
        return true
    }

    func scheduleScrollSettled(_ settled: @escaping @MainActor () -> Void) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            settled()
        }
    }

    func clear() {
        imageLoading.clear()
        isScrolling = false
        scrollDirection = .stationary
        settleTask?.cancel()
        settleTask = nil
        contentFrames.removeAll()
        frameOwners.removeAll()
        folderFrame = nil
        groupHeaderFrames.removeAll()
        origin = GalleryContentOrigin(selection: .zero, preview: .zero, scrollOffset: 0)
        renderPlan = nil
        navigationToken = nil
    }
}
