import Foundation
import ImageIO

/// Whether Camera Raw (or Lightroom) has saved develop settings for an image,
/// the same thing Bridge marks on thumbnails: `crs:HasSettings` in its XMP.
/// RAW files keep it in a sidecar beside them (`IMG_1.xmp`, or `IMG_1.CR2.xmp`);
/// JPEG, TIFF, DNG and other files carry it inside.
///
/// Answers are kept per path while the file (and sidecar) modification time and
/// size are unchanged, so a folder revisit only `stat`s.
enum CameraRawSettings {
    static let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// `signature` (the file's, from a listing) and `sidecarNames` (the
    /// lowercased `.xmp` names in its folder) spare a `stat` per file and per
    /// sidecar candidate; without them both are looked up.
    static func hasSettings(for url: URL, signature: FileContentSignature? = nil,
                            sidecarNames: Set<String>? = nil) -> Bool {
        let path = url.standardizedFileURL.path
        let isRaw = LightboxAsset.rawImageExtensions.contains(url.pathExtension.lowercased())
        let sidecars = isRaw ? RawSidecar.candidates(for: url).compactMap { sidecar -> (URL, FileContentSignature)? in
            if let sidecarNames, !sidecarNames.contains(sidecar.lastPathComponent.lowercased()) { return nil }
            return FileContentSignature(url: sidecar).map { (sidecar, $0) }
        } : []
        // DNG keeps settings inside unless Camera Raw is set to write sidecars.
        let readsEmbedded = !isRaw || url.pathExtension.lowercased() == "dng"
        let fileSignature = readsEmbedded ? (signature ?? FileContentSignature(url: url)) : nil
        let key = ([fileSignature] + sidecars.map(\.1)).map { $0?.cacheKeyComponent ?? "-" }.joined(separator: "|")
        if let known = cache.value(for: path, key: key) { return known }

        let result = sidecars.contains { sidecarHasSettings($0.0) } || (readsEmbedded && embeddedHasSettings(url))
        cache.store(result, for: path, key: key)
        return result
    }

    /// Sidecars are small XML files; Camera Raw writes the flag as an
    /// attribute, other tools sometimes as an element.
    static func sidecarHasSettings(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 << 20) else { return false }
        return xmpHasSettings(String(decoding: data, as: UTF8.self))
    }

    static func xmpHasSettings(_ xmp: String) -> Bool {
        xmp.range(of: #"crs:HasSettings\s*=\s*["']True["']|<crs:HasSettings>\s*True\s*<"#, options: .regularExpression) != nil
    }

    static func embeddedHasSettings(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        else { return false }
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            guard CGImageMetadataTagCopyNamespace(tag) as String? == namespace,
                  CGImageMetadataTagCopyName(tag) as String? == "HasSettings"
            else { return true }
            let value = CGImageMetadataTagCopyValue(tag)
            found = (value as? String)?.caseInsensitiveCompare("True") == .orderedSame
                || (value as? NSNumber)?.boolValue == true
            return false
        }
        return found
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (key: String, value: Bool)] = [:]

        func value(for path: String, key: String) -> Bool? {
            lock.withLock { entries[path].flatMap { $0.key == key ? $0.value : nil } }
        }

        func store(_ value: Bool, for path: String, key: String) {
            lock.withLock {
                if entries.count > 100_000 { entries.removeAll(keepingCapacity: true) }
                entries[path] = (key, value)
            }
        }
    }
}
