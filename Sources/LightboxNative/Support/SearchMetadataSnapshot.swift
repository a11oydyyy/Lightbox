import Foundation

/// Reuse known dimensions only for the same identity and modification metadata.
/// This is a transient refresh snapshot, not a content checksum or a tag cache.
struct SearchMetadataSnapshot: Sendable {
    private let assetsByID: [LightboxAsset.ID: LightboxAsset]

    init(_ assets: [LightboxAsset]) {
        assetsByID = assets.reduce(into: [:]) { result, asset in
            guard asset.metadataLoaded, asset.sourceURL != nil,
                  asset.width.isFinite, asset.height.isFinite,
                  asset.width > 0, asset.height > 0,
                  asset.fileContentSignature != nil else { return }
            result[asset.id] = asset
        }
    }

    func mergingDimensions(into assets: [LightboxAsset]) -> [LightboxAsset] {
        guard !assetsByID.isEmpty else { return assets }
        return assets.map { asset in
            guard !asset.metadataLoaded, let old = assetsByID[asset.id],
                  asset.sourceURL == old.sourceURL,
                  let signature = asset.fileContentSignature,
                  signature == old.fileContentSignature else { return asset }
            var merged = asset
            merged.width = old.width
            merged.height = old.height
            merged.metadataLoaded = true
            return merged
        }
    }
}
