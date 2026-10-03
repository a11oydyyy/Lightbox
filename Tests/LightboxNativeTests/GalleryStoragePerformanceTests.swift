import Foundation
import Testing
@testable import LightboxNative

@Test @MainActor func galleryScrollingReusesStorageClassificationAndRawSample() {
    var classifications = 0
    let cache = GalleryStoragePerformanceCache { _ in
        classifications += 1
        return true
    }
    let source = LibrarySource(id: "external", name: "Photos", rootURL: URL(fileURLWithPath: "/Volumes/Photos"), kind: .external)
    let assets = (0..<10_000).map { galleryStorageAsset($0, extension: $0 < 72 ? "ARW" : "jpg") }
    for _ in 0..<1_000 {
        let result = cache.configuration(source: source, activeAssets: assets, revision: 1)
        #expect(result.usesConservativeExternalLoading)
        #expect(result.prefersFastRawThumbnails)
    }
    #expect(classifications == 1)
    let revised = (0..<500).map { galleryStorageAsset($0, extension: "jpg") }
    #expect(!cache.configuration(source: source, activeAssets: revised, revision: 2).prefersFastRawThumbnails)
    #expect(classifications == 2)
}

@Test @MainActor func galleryStoragePolicyInvalidatesForSourceAndLibraryChanges() {
    var classifications = 0
    let cache = GalleryStoragePerformanceCache { source in
        classifications += 1
        return source.kind == .external
    }
    let assets = (0..<500).map { galleryStorageAsset($0, extension: "dng") }
    let url = URL(fileURLWithPath: "/tmp/gallery-storage")
    let external = LibrarySource(id: "external", name: "Photos", rootURL: url, kind: .external)
    let local = LibrarySource.favorites(rootURL: url)
    #expect(cache.configuration(source: external, activeAssets: assets, revision: 1).prefersFastRawThumbnails)
    #expect(!cache.configuration(source: local, activeAssets: assets, revision: 1).usesConservativeExternalLoading)
    #expect(!cache.configuration(source: local, activeAssets: assets, revision: 1).prefersFastRawThumbnails)
    #expect(classifications == 2)
    #expect(!cache.configuration(source: external, activeAssets: Array(assets.prefix(499)), revision: 1).prefersFastRawThumbnails)
    #expect(classifications == 3)
    #expect(!cache.configuration(source: nil, activeAssets: assets, revision: 1).usesConservativeExternalLoading)
    #expect(classifications == 3)
}

private func galleryStorageAsset(_ index: Int, extension ext: String) -> LightboxAsset {
    let url = URL(fileURLWithPath: "/tmp/gallery-storage/\(index).\(ext)")
    return LightboxAsset(originalName: url.lastPathComponent, width: 100, height: 100, tags: [],
                        sourceURL: url, addedAt: .distantPast, palette: MockPalette.imported[0])
}
