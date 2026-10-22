import Foundation

/// Reuse known dimensions only for the same identity and modification metadata.
/// This is a transient refresh snapshot, not a content checksum or a tag cache.
struct SearchMetadataSnapshot: Sendable {
    private let assetsByID: [LightboxAsset.ID: LightboxAsset]

    init(_ assets: [LightboxAsset]) {
        assetsByID = assets.reduce(into: [:]) { result, asset in
            guard asset.sourceURL != nil else { return }
            result[asset.id] = asset
        }
    }

    /// Recursive scans skip Finder tags (an extra read per file) and the metadata
    /// pass reloads them; `keepingTags` shows the known tags until it does, so a
    /// refresh does not blink every tag off and back on.
    func mergingDimensions(into assets: [LightboxAsset], keepingTags: Bool = false) -> [LightboxAsset] {
        guard !assetsByID.isEmpty else { return assets }
        return assets.map { asset in
            guard let old = assetsByID[asset.id], asset.sourceURL == old.sourceURL else { return asset }
            var merged = asset
            if keepingTags { merged.tags = old.tags }
            // Rechecked by the metadata pass; kept meanwhile so the badge does not blink.
            merged.hasCameraRawSettings = old.hasCameraRawSettings
            guard !asset.metadataLoaded, Self.hasUsableDimensions(old),
                  let signature = asset.fileContentSignature,
                  signature == old.fileContentSignature else { return merged }
            merged.width = old.width
            merged.height = old.height
            merged.metadataLoaded = true
            return merged
        }
    }

    /// Sizes from the index for images still waiting for theirs, while the
    /// file's modification time and size match what was stored.
    static func mergingStored(_ stored: [String: StoredImageDimensions], into assets: [LightboxAsset]) -> [LightboxAsset] {
        guard !stored.isEmpty else { return assets }
        return assets.map { asset in
            guard asset.isImage, !asset.metadataLoaded,
                  let path = asset.sourceURL?.standardizedFileURL.path, let known = stored[path],
                  let signature = asset.fileContentSignature,
                  known.signature.matchesStoredMetadata(signature) else { return asset }
            var merged = asset
            merged.width = known.width
            merged.height = known.height
            merged.metadataLoaded = true
            return merged
        }
    }

    private static func hasUsableDimensions(_ asset: LightboxAsset) -> Bool {
        asset.metadataLoaded && asset.width.isFinite && asset.height.isFinite
            && asset.width > 0 && asset.height > 0 && asset.fileContentSignature != nil
    }
}
