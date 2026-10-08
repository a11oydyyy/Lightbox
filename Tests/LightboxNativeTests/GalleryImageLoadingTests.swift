import Combine
import Testing
@testable import LightboxNative

@Test @MainActor func galleryScrollLoadingPublishesOnlyChangedImages() {
    let coordinator = GalleryImageLoadingCoordinator()
    let initial = GalleryImageLoadingConfiguration(loadsImage: true, priority: .low, quality: .thumbnailBalanced)
    let stable = coordinator.state(for: "stable", requiredPixelSize: 412, initial: initial)
    let entering = coordinator.state(for: "entering", requiredPixelSize: 412, initial: initial)
    var stableUpdates = 0
    var enteringUpdates = 0
    let first = stable.$configuration.dropFirst().sink { _ in stableUpdates += 1 }
    let second = entering.$configuration.dropFirst().sink { _ in enteringUpdates += 1 }
    defer { first.cancel(); second.cancel() }
    for _ in 0..<120 {
        coordinator.update(plan: GalleryRenderPlan(loadableAssetIDs: ["stable", "entering"],
            prioritizedAssetIDs: ["entering"], settledVisibleAssetIDs: []),
            baseQuality: .thumbnailBalanced, prefersFastRawThumbnails: false, permitsFullThumbnailPromotion: false)
    }
    #expect(stableUpdates == 0)
    #expect(enteringUpdates == 1)
    coordinator.update(plan: GalleryRenderPlan(loadableAssetIDs: ["stable", "entering"],
        prioritizedAssetIDs: ["entering"], settledVisibleAssetIDs: ["stable", "entering"]),
        baseQuality: .thumbnailBalanced, prefersFastRawThumbnails: false, permitsFullThumbnailPromotion: false)
    #expect(stableUpdates == 0)
    #expect(enteringUpdates == 1)
    #expect(stable.configuration.quality == .thumbnailBalanced)
}

@Test func galleryThumbnailQualityRetainsEnoughPixelsAtRest() {
    for settled in [false, true] {
        #expect(GalleryImagePriorityPlanner.displayQuality(baseQuality: .thumbnailBalanced, isPrioritized: true,
            permitsFullThumbnailPromotion: false, isSettledVisible: settled, requiredPixelSize: 412) == .thumbnailBalanced)
    }
    #expect(GalleryImagePriorityPlanner.displayQuality(baseQuality: .thumbnailBalanced, isPrioritized: true,
        permitsFullThumbnailPromotion: false, isSettledVisible: true, requiredPixelSize: 820) == .thumbnail)
    #expect(GalleryImagePriorityPlanner.displayQuality(baseQuality: .thumbnailFast, isPrioritized: false,
        isSettledVisible: true, requiredPixelSize: 412) == .thumbnailBalanced)
}

@Test @MainActor func galleryLoadingRegistrationUsesCurrentPlanAndReleasesOldLibrary() {
    let coordinator = GalleryImageLoadingCoordinator()
    let initial = GalleryImageLoadingConfiguration(loadsImage: false, priority: .low, quality: .thumbnailBalanced)
    coordinator.update(plan: GalleryRenderPlan(loadableAssetIDs: ["photo"], prioritizedAssetIDs: ["photo"],
        settledVisibleAssetIDs: ["photo"]), baseQuality: .thumbnailBalanced,
        prefersFastRawThumbnails: false, permitsFullThumbnailPromotion: false)
    let state = coordinator.state(for: "photo", requiredPixelSize: 412, initial: initial)
    #expect(state.configuration.loadsImage)
    #expect(state.configuration.priority == .high)
    #expect(state.configuration.quality == .thumbnailBalanced)
    _ = coordinator.state(for: "photo", requiredPixelSize: 820, initial: initial)
    coordinator.update(plan: GalleryRenderPlan(loadableAssetIDs: ["photo"], prioritizedAssetIDs: ["photo"],
        settledVisibleAssetIDs: ["photo"]), baseQuality: .thumbnailBalanced,
        prefersFastRawThumbnails: false, permitsFullThumbnailPromotion: false)
    #expect(state.configuration.quality == .thumbnail)
    coordinator.clear()
    #expect(coordinator.state(for: "photo", requiredPixelSize: 412, initial: initial) !== state)
}
