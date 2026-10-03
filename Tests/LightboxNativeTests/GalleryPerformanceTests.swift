import AppKit
import Testing
@testable import LightboxNative

@Test func galleryRubberBandSelectionUsesOnlyActiveReportedFrames() {
    let frames = [
        "visible": CGRect(x: 0, y: 0, width: 100, height: 100),
        "outside": CGRect(x: 120, y: 0, width: 100, height: 100),
        "inactive": CGRect(x: 0, y: 0, width: 100, height: 100)
    ]
    let selection = CGRect(x: 10, y: 10, width: 50, height: 50)
    #expect(RubberBandSelectionView.intersectingAssetIDs(
        in: selection, assetFrames: frames, activeAssetIDs: ["visible", "outside", "unreported"]
    ) == ["visible"])
    #expect(RubberBandSelectionView.intersectingAssetIDs(
        in: selection, assetFrames: [:], activeAssetIDs: ["visible"]
    ).isEmpty)
    #expect(RubberBandSelectionView.intersectingAssetIDs(
        in: selection, assetFrames: frames, activeAssetIDs: []
    ).isEmpty)
}

@Test @MainActor func galleryMasonryCacheKeepsUnchangedGroupsWarmAcrossRevisions() {
    let cache = GalleryMasonryColumnCache()
    let first = galleryPerformanceAsset(id: "first")
    let second = galleryPerformanceAsset(id: "second")
    var computations = 0
    func columns(_ identity: String, revision: Int = 1, count: Int = 2, width: CGFloat = 200) -> [[LightboxAsset]] {
        cache.columns(identity: identity, revision: revision, assets: identity == "first" ? [first] : [second], columnCount: count, itemWidth: width) {
            computations += 1
            return identity == "first" ? [[first]] : [[second]]
        }
    }

    #expect(columns("first") == [[first]])
    #expect(columns("second") == [[second]])
    #expect(columns("first") == [[first]])
    #expect(columns("second") == [[second]])
    #expect(computations == 2)
    _ = columns("first", count: 3)
    #expect(computations == 3)
    _ = columns("first", count: 3, width: 200.01)
    #expect(computations == 3)
    _ = columns("first", revision: 2)
    _ = columns("second", revision: 2)
    #expect(computations == 4)
}

@Test @MainActor func galleryMasonryCacheRetainsOneWidthPerGroupAtTenThousandAssets() {
    let cache = GalleryMasonryColumnCache()
    let assets = (0..<10_000).map { galleryPerformanceAsset(id: "asset-\($0)") }
    var computations = 0
    func columns(_ identity: String, width: CGFloat) -> [[LightboxAsset]] {
        cache.columns(identity: identity, revision: 1, assets: assets, columnCount: 5, itemWidth: width) {
            computations += 1
            return [assets]
        }
    }
    _ = columns("other-group", width: 150)
    for width in 200..<400 {
        #expect(columns("active", width: CGFloat(width)).first?.count == 10_000)
    }
    #expect(computations == 201)
    _ = columns("active", width: 399)
    _ = columns("other-group", width: 150)
    #expect(computations == 201)
    _ = columns("active", width: 200)
    #expect(computations == 202)
}


@Test @MainActor func recursiveMasonryCacheRecomputesOnlyChangedFolder() {
    let cache = GalleryMasonryColumnCache()
    var groups = (0..<100).map { group in
        (0..<100).map { galleryPerformanceAsset(id: "group-\(group)-asset-\($0)") }
    }
    var computations = 0
    func columns(_ group: Int, revision: Int) -> [[LightboxAsset]] {
        cache.columns(identity: "group-\(group)", revision: revision, assets: groups[group],
                      columnCount: 5, itemWidth: 200) {
            computations += 1
            return [groups[group]]
        }
    }
    for group in groups.indices { _ = columns(group, revision: 1) }
    #expect(computations == 100)
    groups[42][0].width = 240
    groups[42][0].tags = ["Updated"]
    groups[42][0].fileSize = 1_234
    for group in groups.indices {
        #expect(columns(group, revision: 2).flatMap { $0 } == groups[group])
    }
    #expect(computations == 101)
    for group in groups.indices { _ = columns(group, revision: 2) }
    #expect(computations == 101)
    groups[42][0].tags = ["Metadata only"]
    groups[42][0].fileSize = 5_678
    #expect(columns(42, revision: 3).first?.first?.tags == ["Metadata only"])
    #expect(columns(42, revision: 3).first?.first?.fileSize == 5_678)
    #expect(computations == 102)
    cache.retain(identities: ["group-42"])
    _ = columns(42, revision: 3)
    #expect(computations == 102)
    _ = columns(0, revision: 3)
    #expect(computations == 103)
    cache.removeAll()
    _ = columns(42, revision: 3)
    #expect(computations == 104)
}

@Test func galleryRubberBandTenThousandAssetComparison() {
    let ids = (0..<10_000).map { "asset-\($0)" }
    let activeIDs = Set(ids)
    var frames = Dictionary(uniqueKeysWithValues: ids.suffix(60).enumerated().map { index, id in
        (id, CGRect(x: CGFloat(index % 5) * 120, y: CGFloat(index / 5) * 120, width: 100, height: 100))
    })
    frames["inactive"] = CGRect(x: 0, y: 0, width: 100, height: 100)
    let rects = [
        CGRect(x: 0, y: 0, width: 590, height: 500),
        CGRect(x: 10, y: 10, width: 50, height: 50),
        CGRect(x: 700, y: 0, width: 100, height: 100),
        CGRect(x: 0, y: 0, width: 100, height: 100)
    ]
    for rect in rects {
        let baseline = Set(ids.filter { frames[$0]?.intersects(rect) == true })
        #expect(RubberBandSelectionView.intersectingAssetIDs(
            in: rect, assetFrames: frames, activeAssetIDs: activeIDs
        ) == baseline)
    }

    let clock = ContinuousClock()
    var baselineCount = 0
    let baselineDuration = clock.measure {
        for iteration in 0..<100 {
            baselineCount += Set(ids.filter { frames[$0]?.intersects(rects[iteration % rects.count]) == true }).count
        }
    }
    var frameCount = 0
    let frameDuration = clock.measure {
        for iteration in 0..<100 {
            frameCount += RubberBandSelectionView.intersectingAssetIDs(
                in: rects[iteration % rects.count], assetFrames: frames, activeAssetIDs: activeIDs
            ).count
        }
    }
    #expect(frameCount == baselineCount)
    // Timings are diagnostic; correctness does not depend on machine load.
    print("Gallery rubber-band comparison: assets=\(ids.count) frames=\(frames.count) iterations=100 baseline=\(baselineDuration) frame-based=\(frameDuration)")
}

private func galleryPerformanceAsset(id: String) -> LightboxAsset {
    LightboxAsset(id: id, originalName: "\(id).jpg", width: 100, height: 100, tags: [], addedAt: .distantPast, palette: MockPalette.imported[0])
}
