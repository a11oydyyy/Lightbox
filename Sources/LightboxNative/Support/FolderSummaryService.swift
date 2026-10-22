import Darwin
import Foundation

/// Cover image and image count for folder cells.
///
/// Folders are read in the background one at a time, so network volumes are
/// not flooded, with the most recently requested (visible) folders first.
/// Results are kept in memory and in the index database. A stored summary is
/// reused while the folder's modification time is unchanged, so revisiting a
/// folder costs one `stat` per subfolder instead of a directory read.
@MainActor
final class FolderSummaryService {
    typealias Update = @MainActor (URL, FolderImageSummary) -> Void

    private let worker: FolderSummaryWorker
    private var memory: [String: FolderImageSummary] = [:]
    /// Paths checked against disk since their folder list was last shown.
    private var verified: Set<String> = []
    private var queue: [URL] = []
    private var queuedPaths: Set<String> = []
    private var updates: [String: Update] = [:]
    private var pump: Task<Void, Never>?

    init(
        indexDatabaseURL: URL?,
        read: @escaping @Sendable (URL) -> FolderImageSummary? = { LocalImageSource.folderImageSummary(in: $0) }
    ) {
        worker = FolderSummaryWorker(databaseURL: indexDatabaseURL, read: read)
    }

    /// The last known summary, possibly from before the folder changed; a
    /// request refreshes it.
    func summary(for url: URL) -> FolderImageSummary? {
        memory[Self.key(url)]
    }

    /// Loads summaries for `urls`, earlier entries first, ahead of anything
    /// requested before. `update` runs on the main actor for each result.
    func request(_ urls: [URL], update: @escaping Update) {
        var front: [URL] = []
        for url in urls {
            let key = Self.key(url)
            updates[key] = update
            guard !verified.contains(key) else { continue }
            if queuedPaths.contains(key) { queue.removeAll { Self.key($0) == key } }
            queuedPaths.insert(key)
            front.append(url)
        }
        guard !front.isEmpty else { return }
        queue.insert(contentsOf: front, at: 0)
        startPumpIfNeeded()
    }

    /// Forget pending work outside the folders now on screen, and re-check
    /// these folders against disk the next time they are requested.
    func reset(keeping urls: [URL]) {
        let keep = Set(urls.map(Self.key))
        queue.removeAll { !keep.contains(Self.key($0)) }
        queuedPaths = queuedPaths.intersection(keep)
        updates = updates.filter { keep.contains($0.key) }
        verified.subtract(keep)
    }

    private func startPumpIfNeeded() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, let url = self.nextURL() {
                let summary = await self.worker.load(url)
                let key = Self.key(url)
                self.verified.insert(key)
                guard let summary else { continue }
                self.memory[key] = summary
                self.updates[key]?(url, summary)
            }
            self?.pump = nil
        }
    }

    private func nextURL() -> URL? {
        guard !queue.isEmpty else { return nil }
        let url = queue.removeFirst()
        queuedPaths.remove(Self.key(url))
        return url
    }

    nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// Serializes directory reads and index access off the main actor.
private actor FolderSummaryWorker {
    private let databaseURL: URL?
    private let read: @Sendable (URL) -> FolderImageSummary?
    // Opened on first use, on the worker, so creating the app state stays
    // free of database work on the main actor.
    private lazy var store: LightboxIndexStore? = databaseURL.map { LightboxIndexStore(databaseURL: $0) }

    init(databaseURL: URL?, read: @escaping @Sendable (URL) -> FolderImageSummary?) {
        self.databaseURL = databaseURL
        self.read = read
    }

    func load(_ url: URL) -> FolderImageSummary? {
        let path = FolderSummaryService.key(url)
        guard let modificationTime = Self.modificationTime(path) else { return nil }
        if let cached = store?.cachedFolderSummary(path: path), cached.modificationTime == modificationTime {
            return cached.summary
        }
        guard let summary = read(url) else { return nil }
        store?.storeFolderSummary(summary, path: path, modificationTime: modificationTime)
        return summary
    }

    private static func modificationTime(_ path: String) -> Double? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}
