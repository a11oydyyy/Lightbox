import Foundation
import Testing
@testable import LightboxNative

/// The pairwise comparator `GalleryAssetSorter` used before keys were
/// precomputed; the keyed sort must produce the same order.
private func referenceSorted(
    _ items: [LightboxAsset],
    field: GallerySortField,
    direction: GallerySortDirection
) -> [LightboxAsset] {
    func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
        guard lhs != rhs else { return nil }
        return direction == .ascending ? lhs < rhs : lhs > rhs
    }
    func compareText(_ lhs: String, _ rhs: String) -> Bool? {
        let order = lhs.localizedStandardCompare(rhs)
        guard order != .orderedSame else { return nil }
        return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
    }
    func tagRank(_ asset: LightboxAsset) -> Int {
        guard let first = MacColorTag.sort(asset.tags.filter(MacColorTag.isColorTag)).first else { return Int.max }
        return MacColorTag.all.firstIndex { $0.name == first } ?? Int.max
    }
    func fileType(_ asset: LightboxAsset) -> String {
        let fromURL = asset.sourceURL?.pathExtension.lowercased() ?? ""
        return fromURL.isEmpty ? URL(fileURLWithPath: asset.originalName).pathExtension.lowercased() : fromURL
    }
    func pixels(_ asset: LightboxAsset) -> CGFloat {
        asset.isImage && asset.metadataLoaded && asset.width > 1 && asset.height > 1 ? asset.width * asset.height : 0
    }
    func tieBreak(_ lhs: LightboxAsset, _ rhs: LightboxAsset) -> Bool {
        compareText(lhs.originalName, rhs.originalName) ?? compareText(lhs.id, rhs.id) ?? false
    }
    return items.sorted { lhs, rhs in
        let primary: Bool? = switch field {
        case .time: compare(lhs.addedAt, rhs.addedAt)
        case .size: compare(lhs.fileSize ?? 0, rhs.fileSize ?? 0)
        case .tag: compare(tagRank(lhs), tagRank(rhs))
        case .fileName: compareText(lhs.originalName, rhs.originalName)
        case .type: compareText(fileType(lhs), fileType(rhs))
        case .dimensions: compare(pixels(lhs), pixels(rhs))
        }
        return primary ?? tieBreak(lhs, rhs)
    }
}

@Test(arguments: GallerySortField.allCases)
func keyedSorterMatchesPairwiseComparator(field: GallerySortField) {
    var generator = SystemRandomNumberGenerator()
    let names = ["IMG_2.jpg", "IMG_10.jpg", "img_2.JPG", "Cover.png", "cover.PNG", "照片 1.heic", "照片 12.heic", "a.tiff", "Z.dng", "b"]
    let extensions = ["jpg", "JPG", "png", "heic", "dng", ""]
    let colorTags = MacColorTag.all.map(\.name)
    let assets = (0..<600).map { index -> LightboxAsset in
        let name = names[Int.random(in: 0..<names.count, using: &generator)]
        let ext = extensions[Int.random(in: 0..<extensions.count, using: &generator)]
        let folder = "/Volumes/Test/d\(Int.random(in: 0..<4, using: &generator))"
        let url = URL(fileURLWithPath: "\(folder)/\(index)-\(name)\(ext.isEmpty ? "" : ".\(ext)")")
        return LightboxAsset(
            // Unique IDs keep the order total; names repeat to exercise the ID tie-break.
            id: "asset-\(index)",
            originalName: name,
            // Few sizes, so equal pixel counts (100×400 and 200×200) tie.
            width: [100, 200, 400][Int.random(in: 0..<3, using: &generator)],
            height: [100, 200, 400][Int.random(in: 0..<3, using: &generator)],
            tags: (0..<Int.random(in: 0...2, using: &generator)).map { _ in
                Bool.random(using: &generator) ? colorTags[Int.random(in: 0..<colorTags.count, using: &generator)] : "Project"
            },
            sourceURL: Bool.random(using: &generator) ? url : nil,
            addedAt: Date(timeIntervalSince1970: Double(Int.random(in: 0..<8, using: &generator))),
            fileSize: Bool.random(using: &generator) ? Int64(Int.random(in: 0..<5, using: &generator)) : nil,
            palette: MockPalette.imported[0],
            metadataLoaded: Int.random(in: 0..<5, using: &generator) > 0
        )
    }
    for direction in GallerySortDirection.allCases {
        let expected = referenceSorted(assets, field: field, direction: direction).map(\.id)
        let actual = GalleryAssetSorter.sorted(assets, field: field, direction: direction).map(\.id)
        #expect(actual == expected, "field=\(field) direction=\(direction)")
    }
}
