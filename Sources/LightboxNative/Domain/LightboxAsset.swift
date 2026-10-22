import Darwin
import Foundation
import SwiftUI

struct LightboxAsset: Identifiable, Hashable, Sendable {
    let id: String
    var originalName: String
    var width: CGFloat
    var height: CGFloat
    var tags: [String]
    var sourceURL: URL?
    var addedAt: Date
    var contentModifiedAt: Date?
    var fileSize: Int64?
    var palette: MockPalette
    var deletedAt: Date?
    var metadataLoaded: Bool
    /// Camera Raw or Lightroom has saved develop settings for it (see
    /// `CameraRawSettings`); nil until the background metadata pass has checked.
    var hasCameraRawSettings: Bool? = nil
    /// False for other files (PDFs, videos, documents…), which the gallery
    /// shows as icon tiles when "Show Other Files" is on. They have no pixel
    /// size to load, so they are square and their metadata counts as loaded.
    let isImage: Bool

    init(
        id: String? = nil,
        originalName: String,
        width: CGFloat,
        height: CGFloat,
        tags: [String],
        sourceURL: URL? = nil,
        addedAt: Date,
        contentModifiedAt: Date? = nil,
        fileSize: Int64? = nil,
        palette: MockPalette,
        deletedAt: Date? = nil,
        metadataLoaded: Bool = true
    ) {
        self.id = id ?? Self.stableID(originalName: originalName, sourceURL: sourceURL)
        self.originalName = originalName
        self.width = width
        self.height = height
        self.tags = tags
        self.sourceURL = sourceURL
        self.addedAt = addedAt
        self.contentModifiedAt = contentModifiedAt
        self.fileSize = fileSize
        self.palette = palette
        self.deletedAt = deletedAt
        // Assets without a file (mock and in-memory ones) are images.
        isImage = sourceURL == nil || Self.isImageName(originalName)
        self.metadataLoaded = isImage ? metadataLoaded : true
        if !isImage {
            self.width = 1
            self.height = 1
        }
    }

    /// Camera RAW formats.
    static let rawImageExtensions: Set<String> = [
        "raw", "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "rw2", "orf", "ori", "pef", "srw", "x3f", "erf", "rwl", "3fr",
        "mef", "mos", "mrw", "dcr", "kdc", "fff", "iiq", "ari", "bay"
    ]

    /// Extensions the gallery decodes as images, RAW formats included.
    static let imageExtensions: Set<String> = rawImageExtensions.union([
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"
    ])

    static func isImageName(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The same file under a new name or path. Becoming an image means its
    /// size is still to be read.
    func renamed(to url: URL) -> LightboxAsset {
        let name = url.lastPathComponent
        let becomesImage = !isImage && Self.isImageName(name)
        return LightboxAsset(
            originalName: name, width: width, height: height, tags: tags, sourceURL: url,
            addedAt: addedAt, contentModifiedAt: contentModifiedAt, fileSize: fileSize, palette: palette,
            deletedAt: deletedAt, metadataLoaded: becomesImage ? false : metadataLoaded
        )
    }

    /// `isImage` from an ID alone (see `stableID`), without finding the asset.
    static func isImageID(_ id: ID) -> Bool {
        !id.hasPrefix("file:") || isImageName(id)
    }

    var aspectRatio: CGFloat {
        max(0.35, width / max(1, height))
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    var fileContentSignature: FileContentSignature? {
        FileContentSignature(
            modificationTime: contentModifiedAt?.timeIntervalSince1970,
            fileSize: fileSize
        )
    }

    static func stableID(originalName: String, sourceURL: URL?) -> String {
        if let sourceURL {
            return "file:\(sourceURL.standardizedFileURL.path)"
        }

        return "memory:\(originalName)"
    }
}

struct FileContentSignature: Equatable, Hashable, Sendable {
    let modificationTime: TimeInterval
    let fileSize: Int64
    let fileSystemIdentifier: String?
    let statusChangeTime: TimeInterval?

    init(
        modificationTime: TimeInterval,
        fileSize: Int64,
        fileSystemIdentifier: String? = nil,
        statusChangeTime: TimeInterval? = nil
    ) {
        precondition(modificationTime.isFinite)
        precondition(fileSize >= 0)
        precondition(statusChangeTime?.isFinite != false)
        self.modificationTime = modificationTime
        self.fileSize = fileSize
        self.fileSystemIdentifier = fileSystemIdentifier
        self.statusChangeTime = statusChangeTime
    }

    init?(modificationTime: TimeInterval?, fileSize: Int64?) {
        guard let modificationTime,
              modificationTime.isFinite,
              let fileSize,
              fileSize >= 0
        else {
            return nil
        }

        self.init(modificationTime: modificationTime, fileSize: fileSize)
    }

    init?(url: URL) {
        var fileStatus = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return Int32(-1) }
            return stat(path, &fileStatus)
        }
        guard result == 0, fileStatus.st_size >= 0 else { return nil }

        let modificationTime = TimeInterval(fileStatus.st_mtimespec.tv_sec)
            + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
        let statusChangeTime = TimeInterval(fileStatus.st_ctimespec.tv_sec)
            + TimeInterval(fileStatus.st_ctimespec.tv_nsec) / 1_000_000_000

        self.init(
            modificationTime: modificationTime,
            fileSize: Int64(fileStatus.st_size),
            fileSystemIdentifier: "\(fileStatus.st_dev):\(fileStatus.st_ino)",
            statusChangeTime: statusChangeTime
        )
    }

    var cacheKeyComponent: String {
        let statusChangeKey = statusChangeTime.map { String($0.bitPattern) } ?? "unknown"
        return "\(modificationTime.bitPattern):\(fileSize):\(fileSystemIdentifier ?? "unknown"):\(statusChangeKey)"
    }

    func matchesModificationMetadata(_ other: FileContentSignature) -> Bool {
        modificationTime == other.modificationTime && fileSize == other.fileSize
    }

    /// For a size stored from `stat` against a listing's resource values:
    /// the two round the modification time differently by well under 1ms.
    func matchesStoredMetadata(_ other: FileContentSignature) -> Bool {
        fileSize == other.fileSize && abs(modificationTime - other.modificationTime) < 0.001
    }
}

enum GallerySortField: String, CaseIterable, Codable, Hashable, Sendable {
    case time
    case size
    case tag
    case fileName
    case type
    /// Pixel count; images without a known size and other files count as smallest.
    case dimensions
}

enum GallerySortDirection: String, CaseIterable, Codable, Hashable, Sendable {
    case ascending
    case descending

    var toggled: GallerySortDirection {
        switch self {
        case .ascending:
            .descending
        case .descending:
            .ascending
        }
    }
}

enum GalleryAssetSorter {
    static func sorted(
        _ items: [LightboxAsset],
        field: GallerySortField,
        direction: GallerySortDirection
    ) -> [LightboxAsset] {
        guard items.count > 1 else { return items }
        switch field {
        case .time:
            return sorted(items, keys: items.map(\.addedAt), direction: direction)
        case .size:
            return sorted(items, keys: items.map { $0.fileSize ?? 0 }, direction: direction)
        case .tag:
            return sorted(items, keys: items.map(sortableTagRank), direction: direction)
        case .fileName:
            let ranks = nameRanks(items)
            return sorted(items, keys: items.map { ranks[$0.originalName] ?? 0 }, direction: direction)
        case .dimensions:
            return sorted(items, keys: items.map(pixelCount), direction: direction)
        case .type:
            // Parsing an escaped file URL during every comparison is expensive.
            // Keep keys local to this sort so renamed/replaced files cannot reuse stale keys.
            let types = items.map(fileType)
            let ranks = localizedRanks(types)
            return sorted(items, keys: types.map { ranks[$0] ?? 0 }, direction: direction)
        }
    }

    /// Orders by keys computed once per asset (`keys[i]` belongs to `items[i]`);
    /// runs of equal keys fall back to name, then ID. Same order as comparing
    /// `key ?? name ?? id` pairwise, but localized compares happen once per
    /// distinct name instead of on every comparison, and only indices move.
    private static func sorted<Key: Comparable>(
        _ items: [LightboxAsset],
        keys: [Key],
        direction: GallerySortDirection
    ) -> [LightboxAsset] {
        let ascending = direction == .ascending
        var order = Array(items.indices)
        order.sort { ascending ? keys[$0] < keys[$1] : keys[$0] > keys[$1] }

        var runs: [Range<Int>] = []
        var runStart = 0
        while runStart < order.count {
            var runEnd = runStart + 1
            while runEnd < order.count, keys[order[runEnd]] == keys[order[runStart]] { runEnd += 1 }
            if runEnd - runStart > 1 { runs.append(runStart..<runEnd) }
            runStart = runEnd
        }
        guard !runs.isEmpty else { return order.map { items[$0] } }

        let rankByName = nameRanks(items)
        var nameRank = [Int](repeating: 0, count: items.count)
        for run in runs {
            for index in order[run] { nameRank[index] = rankByName[items[index].originalName] ?? 0 }
        }
        for run in runs {
            order[run].sort { lhs, rhs in
                if nameRank[lhs] != nameRank[rhs] {
                    return ascending ? nameRank[lhs] < nameRank[rhs] : nameRank[lhs] > nameRank[rhs]
                }
                return compareText(items[lhs].id, items[rhs].id, direction: direction) ?? false
            }
        }
        return order.map { items[$0] }
    }

    /// Ranks of every name in `items`, from a small cache: ranking thousands
    /// of names took ~35 ms, and every sort field (as a tie-break) and every
    /// rebuild of the same folder needs the same ranks. Only relative order
    /// matters, so ranks over all names also order any subset.
    private static func nameRanks(_ items: [LightboxAsset]) -> [String: Int] {
        let names = Set(items.map(\.originalName))
        let locale = Locale.current.identifier
        if let cached = NameRankCache.shared.ranks(for: names, locale: locale) { return cached }
        let ranks = localizedRanks(Array(names))
        NameRankCache.shared.store(ranks, for: names, locale: locale)
        return ranks
    }

    /// Dense ranks under `localizedStandardCompare`; values it treats as equal share a rank.
    private static func localizedRanks(_ values: [String]) -> [String: Int] {
        let unique = Set(values).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(unique.count)
        var rank = 0
        for (index, value) in unique.enumerated() {
            if index > 0, unique[index - 1].localizedStandardCompare(value) != .orderedSame { rank += 1 }
            ranks[value] = rank
        }
        return ranks
    }

    private static func compareText(
        _ lhs: String,
        _ rhs: String,
        direction: GallerySortDirection
    ) -> Bool? {
        let order = lhs.localizedStandardCompare(rhs)
        guard order != .orderedSame else { return nil }
        return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private static func sortableTagRank(_ asset: LightboxAsset) -> Int {
        firstTagRank(asset) ?? Int.max
    }

    private static func firstTagRank(_ asset: LightboxAsset) -> Int? {
        let sortedTags = MacColorTag.sort(asset.tags.filter(MacColorTag.isColorTag))
        guard let firstTag = sortedTags.first else { return nil }
        return MacColorTag.all.firstIndex { $0.name == firstTag }
    }

    private static func pixelCount(_ asset: LightboxAsset) -> CGFloat {
        guard asset.isImage, asset.metadataLoaded, asset.width > 1, asset.height > 1 else { return 0 }
        return asset.width * asset.height
    }

    private static func fileType(_ asset: LightboxAsset) -> String {
        let extensionFromURL = asset.sourceURL?.pathExtension.lowercased() ?? ""
        if !extensionFromURL.isEmpty {
            return extensionFromURL
        }

        // A string split, not a file URL: building a URL per asset resolves the
        // relative name against the working directory and dominated this sort.
        return (asset.originalName as NSString).pathExtension.lowercased()
    }
}

/// How the gallery shows a folder: the masonry grid, or Finder-style rows.
enum GalleryViewMode: String, Codable, Hashable, Sendable {
    case grid
    case list
}

enum LibraryFilter: Hashable, Sendable {
    case all
    case tag(String)
    case trash

    var identityKey: String {
        switch self {
        case .all:
            "all"
        case .tag(let tag):
            "tag:\(tag)"
        case .trash:
            "trash"
        }
    }
}

// Retain the persisted type/key while the control now selects browsing scope.
enum GalleryLayoutMode: String, Codable, Hashable, Sendable {
    case masonry
    case recursive

    var next: GalleryLayoutMode { self == .masonry ? .recursive : .masonry }
    var iconName: String { self == .masonry ? "folder" : "square.stack.3d.up" }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "masonry", "grid": self = .masonry
        case "recursive": self = .recursive
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown gallery scope")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The last few name rankings `GalleryAssetSorter` computed. Sorting also runs
/// off the main thread (search results), so access is locked.
private final class NameRankCache: @unchecked Sendable {
    static let shared = NameRankCache()
    private static let capacity = 4
    private let lock = NSLock()
    private var entries: [(names: Set<String>, locale: String, ranks: [String: Int])] = []

    func ranks(for names: Set<String>, locale: String) -> [String: Int]? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.locale == locale && $0.names == names }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.ranks
        }
    }

    func store(_ ranks: [String: Int], for names: Set<String>, locale: String) {
        lock.withLock {
            entries.removeAll { $0.locale == locale && $0.names == names }
            entries.append((names, locale, ranks))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }
}
