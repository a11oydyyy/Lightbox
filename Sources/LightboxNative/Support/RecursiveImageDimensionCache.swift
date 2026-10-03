import Foundation

/// An evictable cache of successful probes, validated against the complete stat signature.
final class RecursiveImageDimensionCache: @unchecked Sendable {
    static let shared = RecursiveImageDimensionCache()

    private final class Entry {
        let dimensions: CGSize
        init(_ dimensions: CGSize) { self.dimensions = dimensions }
    }

    // NSCache synchronizes its operations; stat and image decoding happen outside its locks.
    private let entries = NSCache<NSString, Entry>()

    init(countLimit: Int = 20_000) {
        entries.countLimit = max(1, countLimit)
    }

    func dimensions(for url: URL, resolver: (URL) -> CGSize?) -> CGSize? {
        guard !Task.isCancelled else { return nil }
        guard let signature = FileContentSignature(url: url) else { return resolver(url) }
        let key = "\(url.standardizedFileURL.path)|\(signature.cacheKeyComponent)" as NSString
        if let cached = entries.object(forKey: key) { return cached.dimensions }
        guard let dimensions = resolver(url) else { return nil }
        if !Task.isCancelled, FileContentSignature(url: url) == signature {
            entries.setObject(Entry(dimensions), forKey: key)
        }
        return dimensions
    }
}
