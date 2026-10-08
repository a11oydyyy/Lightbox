import Foundation
import Testing
@testable import LightboxNative

@Test @MainActor func galleryScrollingReusesPublishedStoragePolicyAndRawSample() {
    let cache = GalleryStoragePerformanceCache()
    let source = LibrarySource(id: "external", name: "Photos", rootURL: URL(fileURLWithPath: "/Volumes/Photos"), kind: .external)
    let assets = (0..<10_000).map { galleryStorageAsset($0, extension: $0 < 72 ? "ARW" : "jpg") }
    for _ in 0..<1_000 {
        let result = cache.configuration(source: source, usesConservativeExternalLoading: true, activeAssets: assets, revision: 1)
        #expect(result.usesConservativeExternalLoading)
        #expect(result.prefersFastRawThumbnails)
    }
    let revised = (0..<500).map { galleryStorageAsset($0, extension: "jpg") }
    #expect(!cache.configuration(source: source, usesConservativeExternalLoading: true, activeAssets: revised, revision: 2).prefersFastRawThumbnails)
}

@Test @MainActor func galleryStoragePolicyInvalidatesForSourceAndLibraryChanges() {
    let cache = GalleryStoragePerformanceCache()
    let assets = (0..<500).map { galleryStorageAsset($0, extension: "dng") }
    let url = URL(fileURLWithPath: "/tmp/gallery-storage")
    let external = LibrarySource(id: "external", name: "Photos", rootURL: url, kind: .external)
    let local = LibrarySource.favorites(rootURL: url)
    #expect(cache.configuration(source: external, usesConservativeExternalLoading: true, activeAssets: assets, revision: 1).prefersFastRawThumbnails)
    #expect(!cache.configuration(source: local, usesConservativeExternalLoading: false, activeAssets: assets, revision: 1).usesConservativeExternalLoading)
    #expect(!cache.configuration(source: local, usesConservativeExternalLoading: false, activeAssets: assets, revision: 1).prefersFastRawThumbnails)
    #expect(!cache.configuration(source: external, usesConservativeExternalLoading: true, activeAssets: Array(assets.prefix(499)), revision: 1).prefersFastRawThumbnails)
    #expect(!cache.configuration(source: nil, usesConservativeExternalLoading: false, activeAssets: assets, revision: 1).usesConservativeExternalLoading)
}

private func galleryStorageAsset(_ index: Int, extension ext: String) -> LightboxAsset {
    let url = URL(fileURLWithPath: "/tmp/gallery-storage/\(index).\(ext)")
    return LightboxAsset(originalName: url.lastPathComponent, width: 100, height: 100, tags: [],
                        sourceURL: url, addedAt: .distantPast, palette: MockPalette.imported[0])
}

@Test @MainActor func publishedStorageClassificationInvalidatesPolicyWithoutAssetRevisionChange() {
    let cache = GalleryStoragePerformanceCache()
    let source = LibrarySource(id: "photos", name: "Photos", rootURL: URL(fileURLWithPath: "/tmp/photos"), kind: .external)
    let assets = (0..<500).map { galleryStorageAsset($0, extension: "arw") }
    let unknown = cache.configuration(source: source, usesConservativeExternalLoading: true,
                                      activeAssets: assets, revision: 1)
    #expect(unknown.usesConservativeExternalLoading && unknown.prefersFastRawThumbnails)
    let resolvedLocal = cache.configuration(source: source, usesConservativeExternalLoading: false,
                                            activeAssets: assets, revision: 1)
    #expect(!resolvedLocal.usesConservativeExternalLoading && !resolvedLocal.prefersFastRawThumbnails)
}
