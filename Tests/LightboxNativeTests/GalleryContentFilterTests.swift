import Foundation
import Testing
@testable import LightboxNative

private func image(_ name: String, tags: [String] = [], deleted: Bool = false, size: Int64 = 1) -> LightboxAsset {
    var asset = LightboxAsset(originalName: name, width: 10, height: 10, tags: tags,
        sourceURL: URL(fileURLWithPath: "/tmp/filter/\(name)"), addedAt: .distantPast,
        fileSize: size, palette: MockPalette.imported[0], metadataLoaded: true)
    if deleted { asset.deletedAt = .now }
    return asset
}

@Test func galleryContentFiltersByTagTrashAndSearchInSortOrder() {
    let source = [image("c.jpg", tags: ["Red"]), image("a.jpg"), image("b.jpg", tags: ["Red"]), image("d.jpg", deleted: true)]
    func names(_ filter: LibraryFilter, _ text: String = "") -> [String] {
        GalleryContentFilter.visibleAssets(from: source, filter: filter, query: LightboxSearchQuery.parse(text),
            field: .fileName, direction: .ascending, reusing: nil).assets.map(\.originalName)
    }
    #expect(names(.all) == ["a.jpg", "b.jpg", "c.jpg"])
    #expect(names(.tag("Red")) == ["b.jpg", "c.jpg"])
    #expect(names(.trash) == ["d.jpg"])
    #expect(names(.all, "b") == ["b.jpg"])
    #expect(GalleryContentFilter.colorTags(in: source).map(\.name) == ["Red"])
}

// The kept sorted copy is only reused for the same source and sort, and
// gives the same result as sorting again.
@Test func galleryContentReusesItsSortedSourceSafely() {
    let source = (0..<30).map { image(String(format: "%02d.jpg", 29 - $0), tags: $0.isMultiple(of: 3) ? ["Blue"] : [], size: Int64($0)) }
    let first = GalleryContentFilter.visibleAssets(from: source, filter: .all, query: LightboxSearchQuery.parse(""),
        field: .fileName, direction: .ascending, reusing: nil)
    let kept = try! #require(first.sorted)
    let reused = GalleryContentFilter.visibleAssets(from: source, filter: .tag("Blue"), query: LightboxSearchQuery.parse(""),
        field: .fileName, direction: .ascending, reusing: kept)
    let fresh = GalleryContentFilter.visibleAssets(from: source, filter: .tag("Blue"), query: LightboxSearchQuery.parse(""),
        field: .fileName, direction: .ascending, reusing: nil)
    #expect(reused.assets == fresh.assets)
    #expect(reused.sorted == nil)   // a filtered result is not kept
    // A different sort ignores the kept copy.
    let bySize = GalleryContentFilter.visibleAssets(from: source, filter: .all, query: LightboxSearchQuery.parse(""),
        field: .size, direction: .descending, reusing: kept)
    #expect(bySize.assets.map(\.fileSize) == source.map(\.fileSize).sorted { ($0 ?? 0) > ($1 ?? 0) })
}

@Test func galleryContentFoldersFollowSearchAndHideInTrash() {
    let root = URL(fileURLWithPath: "/tmp/filter")
    let folders = ["Beta", "alpha", "Gamma"].map { LibraryFolderEntry(sourceID: "s", url: root.appendingPathComponent($0), rootURL: root, tags: []) }
    func names(_ text: String, trash: Bool = false, searchFolders: [LibraryFolderEntry]? = nil) -> [String] {
        GalleryContentFilter.visibleFolders(folders: folders, searchFolders: searchFolders, query: LightboxSearchQuery.parse(text),
            hasSearchQuery: !text.isEmpty, isViewingTrash: trash, field: .fileName, direction: .ascending).map(\.url.lastPathComponent)
    }
    #expect(names("") == ["alpha", "Beta", "Gamma"])
    #expect(names("", trash: true).isEmpty)
    #expect(names("gam") == ["Gamma"])
    #expect(names("a", searchFolders: [folders[1]]) == ["alpha"])
}
