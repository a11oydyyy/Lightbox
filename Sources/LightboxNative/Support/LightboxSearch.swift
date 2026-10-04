import Foundation

struct LightboxSearchStatus: Equatable, Sendable {
    var isSearching: Bool
    var limitReached = false
    var discoveredCount = 0
    var visitedCount = 0
    var metadataProcessed = 0
    var metadataTotal = 0

    var isLoadingMetadata: Bool { metadataProcessed < metadataTotal }
}

struct LightboxSearchScanResult: Sendable {
    var assets: [LightboxAsset]
    var folders: [LibraryFolderEntry] = []
    var visitedCount: Int
    var limitReached: Bool
}

/// Directory workers replace their own partial snapshot. The lock covers only
/// in-memory bookkeeping; callbacks and all filesystem work run outside it.
final class RecursiveScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: LightboxSearchScanResult] = [:]
    private var lastPublicationAt = Date.distantPast
    private var publishedFirstImage = false
    private let onProgress: @Sendable (LightboxSearchScanResult) -> Void

    init(onProgress: @escaping @Sendable (LightboxSearchScanResult) -> Void) {
        self.onProgress = onProgress
    }

    func update(directory: URL, snapshot: LightboxSearchScanResult) {
        guard !Task.isCancelled else { return }
        lock.lock()
        snapshots[directory.path] = snapshot
        let now = Date()
        let hasImages = !snapshot.assets.isEmpty
        guard (!publishedFirstImage && hasImages) || now.timeIntervalSince(lastPublicationAt) >= 0.5 else {
            lock.unlock()
            return
        }
        publishedFirstImage = publishedFirstImage || hasImages
        lastPublicationAt = now
        var combined = LightboxSearchScanResult(assets: [], visitedCount: 0, limitReached: false)
        for partial in snapshots.values {
            combined.assets.append(contentsOf: partial.assets)
            combined.folders.append(contentsOf: partial.folders)
            combined.visitedCount += partial.visitedCount
            combined.limitReached = combined.limitReached || partial.limitReached
        }
        lock.unlock()
        guard !Task.isCancelled else { return }
        onProgress(combined)
    }
}

struct LightboxSearchQuery: Equatable, Sendable {
    private var nameTerms: [String] = []

    var isEmpty: Bool {
        nameTerms.isEmpty
    }

    static func parse(_ rawValue: String) -> LightboxSearchQuery {
        let terms = rawValue
            .split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
        return LightboxSearchQuery(nameTerms: terms)
    }

    func matches(_ asset: LightboxAsset) -> Bool {
        mayMatchAssetName(asset.originalName)
    }

    func mayMatchAssetName(_ name: String) -> Bool {
        containsAllTerms(in: name)
    }

    func mayMatchFolderName(_ name: String) -> Bool {
        containsAllTerms(in: name)
    }

    func matches(_ folder: LibraryFolderEntry) -> Bool {
        mayMatchFolderName(folder.name)
    }

    private func containsAllTerms(in value: String) -> Bool {
        guard !nameTerms.isEmpty else { return true }
        let searchableValue = Self.normalized(value)
        for term in nameTerms where !searchableValue.contains(term) {
            return false
        }
        return true
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
