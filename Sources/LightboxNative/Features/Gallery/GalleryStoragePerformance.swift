import Foundation

struct GalleryStoragePerformance: Equatable {
    var usesConservativeExternalLoading: Bool
    var prefersFastRawThumbnails: Bool
}

@MainActor
final class GalleryStoragePerformanceCache {
    private struct Key: Equatable {
        var source: LibrarySource?
        var revision: Int
        var assetCount: Int
    }

    private var key: Key?
    private var value = GalleryStoragePerformance(
        usesConservativeExternalLoading: false, prefersFastRawThumbnails: false
    )
    private let classifySource: (LibrarySource) -> Bool

    init(classifySource: @escaping (LibrarySource) -> Bool = { $0.usesConservativeExternalLoading }) {
        self.classifySource = classifySource
    }

    func configuration(
        source: LibrarySource?,
        activeAssets: [LightboxAsset],
        revision: Int
    ) -> GalleryStoragePerformance {
        let nextKey = Key(source: source, revision: revision, assetCount: activeAssets.count)
        guard key != nextKey else { return value }

        // Resolving symlinks and sampling file extensions belong to a library change,
        // not each scroll-driven SwiftUI body evaluation.
        let conservative = source.map(classifySource) ?? false
        var prefersRaw = false
        if conservative, activeAssets.count >= 500 {
            let sample = activeAssets.prefix(120)
            let rawCount = sample.reduce(0) { count, asset in
                guard let ext = asset.sourceURL?.pathExtension.lowercased(),
                      Self.rawImageExtensions.contains(ext) else { return count }
                return count + 1
            }
            prefersRaw = Double(rawCount) / Double(sample.count) >= 0.60
        }
        value = GalleryStoragePerformance(
            usesConservativeExternalLoading: conservative,
            prefersFastRawThumbnails: prefersRaw
        )
        key = nextKey
        return value
    }

    private static let rawImageExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf",
        "fff", "iiq", "k25", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf",
        "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "x3f"
    ]
}
