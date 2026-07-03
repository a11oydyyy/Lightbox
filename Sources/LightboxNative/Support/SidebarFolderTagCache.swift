import Foundation

final class SidebarFolderTagCache: @unchecked Sendable {
    static let shared = SidebarFolderTagCache()

    private let queue = DispatchQueue(label: "io.github.a11oydyyy.Lightbox.sidebar-folder-tags", qos: .utility)
    private let lock = NSLock()
    private let maxEntries: Int
    private var tagsByPath: [String: [String]] = [:]
    private var insertionOrder: [String] = []

    init(maxEntries: Int = 2_048) {
        self.maxEntries = max(1, maxEntries)
    }

    func cachedTags(for url: URL) -> [String]? {
        cachedTags(forPath: key(for: url))
    }

    func tags(for url: URL) async -> [String] {
        let path = key(for: url)
        if let cached = cachedTags(forPath: path) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                if let cached = self.cachedTags(forPath: path) {
                    continuation.resume(returning: cached)
                    return
                }

                let tags = FinderTagStore.colorTags(for: url)
                self.store(tags, forPath: path)
                continuation.resume(returning: tags)
            }
        }
    }

    func store(_ tags: [String], for url: URL) {
        store(tags, forPath: key(for: url))
    }

    func clear() {
        lock.lock()
        tagsByPath.removeAll()
        insertionOrder.removeAll()
        lock.unlock()
    }

    private func cachedTags(forPath path: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return tagsByPath[path]
    }

    private func store(_ tags: [String], forPath path: String) {
        lock.lock()
        if tagsByPath[path] == nil {
            insertionOrder.append(path)
        }
        tagsByPath[path] = tags
        while tagsByPath.count > maxEntries, !insertionOrder.isEmpty {
            let evictedPath = insertionOrder.removeFirst()
            tagsByPath.removeValue(forKey: evictedPath)
        }
        lock.unlock()
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
