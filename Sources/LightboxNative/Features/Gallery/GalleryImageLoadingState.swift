import Combine
import SwiftUI

struct GalleryImageLoadingConfiguration: Equatable {
    var loadsImage: Bool
    var priority: ImageDecodePriority
    var quality: ImageCacheQuality
}

@MainActor
final class GalleryImageLoadingState: ObservableObject {
    @Published private(set) var configuration: GalleryImageLoadingConfiguration
    var requiredPixelSize: CGFloat

    init(configuration: GalleryImageLoadingConfiguration, requiredPixelSize: CGFloat) {
        self.configuration = configuration
        self.requiredPixelSize = requiredPixelSize
    }

    func update(_ configuration: GalleryImageLoadingConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
    }
}

// Scroll changes update only the affected image subtrees. The masonry layout,
// card actions and selection do not depend on decode scheduling.
@MainActor
final class GalleryImageLoadingCoordinator {
    private var states: [LightboxAsset.ID: GalleryImageLoadingState] = [:]
    private var plan: GalleryRenderPlan?
    private var baseQuality: ImageCacheQuality = .thumbnail
    private var prefersFastRawThumbnails = false
    private var permitsFullThumbnailPromotion = true
    private var resizedIDs: Set<LightboxAsset.ID> = []

    func state(for id: LightboxAsset.ID, requiredPixelSize: CGFloat,
               initial: GalleryImageLoadingConfiguration) -> GalleryImageLoadingState {
        if let state = states[id] {
            if state.requiredPixelSize != requiredPixelSize {
                state.requiredPixelSize = requiredPixelSize
                resizedIDs.insert(id)
            }
            return state
        }
        let configuration = plan.map { configuration(for: id, requiredPixelSize: requiredPixelSize, plan: $0) } ?? initial
        let state = GalleryImageLoadingState(configuration: configuration, requiredPixelSize: requiredPixelSize)
        states[id] = state
        return state
    }

    func update(plan: GalleryRenderPlan, baseQuality: ImageCacheQuality,
                prefersFastRawThumbnails: Bool, permitsFullThumbnailPromotion: Bool) {
        var changedIDs = resizedIDs
        if let previous = self.plan,
           self.baseQuality == baseQuality,
           self.prefersFastRawThumbnails == prefersFastRawThumbnails,
           self.permitsFullThumbnailPromotion == permitsFullThumbnailPromotion {
            changedIDs.formUnion(previous.loadableAssetIDs.symmetricDifference(plan.loadableAssetIDs))
            changedIDs.formUnion(previous.prioritizedAssetIDs.symmetricDifference(plan.prioritizedAssetIDs))
            changedIDs.formUnion(previous.settledVisibleAssetIDs.symmetricDifference(plan.settledVisibleAssetIDs))
        } else {
            changedIDs.formUnion(states.keys)
        }
        self.plan = plan
        self.baseQuality = baseQuality
        self.prefersFastRawThumbnails = prefersFastRawThumbnails
        self.permitsFullThumbnailPromotion = permitsFullThumbnailPromotion
        resizedIDs.removeAll(keepingCapacity: true)
        for id in changedIDs {
            guard let state = states[id] else { continue }
            state.update(configuration(for: id, requiredPixelSize: state.requiredPixelSize, plan: plan))
        }
    }

    func retain(activeAssetIDs: Set<LightboxAsset.ID>) {
        states = states.filter { activeAssetIDs.contains($0.key) }
        resizedIDs.formIntersection(activeAssetIDs)
    }

    func clear() {
        states.removeAll()
        plan = nil
        resizedIDs.removeAll()
    }

    private func configuration(for id: LightboxAsset.ID, requiredPixelSize: CGFloat,
                               plan: GalleryRenderPlan) -> GalleryImageLoadingConfiguration {
        GalleryImageLoadingConfiguration(
            loadsImage: plan.loadableAssetIDs.contains(id),
            priority: plan.prioritizedAssetIDs.contains(id) ? .high : .low,
            quality: GalleryImagePriorityPlanner.displayQuality(
                baseQuality: baseQuality, isPrioritized: plan.prioritizedAssetIDs.contains(id),
                prefersFastRawThumbnails: prefersFastRawThumbnails,
                permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                isSettledVisible: plan.settledVisibleAssetIDs.contains(id), requiredPixelSize: requiredPixelSize
            )
        )
    }
}

struct GalleryAssetImageView: View {
    var asset: LightboxAsset
    @ObservedObject var loadingState: GalleryImageLoadingState

    var body: some View {
        let configuration = loadingState.configuration
        AssetImageView(asset: asset, quality: configuration.quality,
            decodePriority: configuration.priority, loadsImage: configuration.loadsImage)
    }
}
