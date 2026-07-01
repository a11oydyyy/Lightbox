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
    var fileSize: Int64?
    var palette: MockPalette
    var deletedAt: Date?
    var metadataLoaded: Bool

    init(
        id: String? = nil,
        originalName: String,
        width: CGFloat,
        height: CGFloat,
        tags: [String],
        sourceURL: URL? = nil,
        addedAt: Date,
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
        self.fileSize = fileSize
        self.palette = palette
        self.deletedAt = deletedAt
        self.metadataLoaded = metadataLoaded
    }

    var aspectRatio: CGFloat {
        max(0.35, width / max(1, height))
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    static func stableID(originalName: String, sourceURL: URL?) -> String {
        if let sourceURL {
            return "file:\(sourceURL.standardizedFileURL.path)"
        }

        return "memory:\(originalName)"
    }
}

enum GallerySortField: String, CaseIterable, Hashable {
    case time
    case size
    case tag
    case fileName
    case type
}

enum GallerySortDirection: String, CaseIterable, Hashable {
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
        items.sorted { lhs, rhs in
            switch field {
            case .time:
                compare(lhs.addedAt, rhs.addedAt, direction: direction) ?? tieBreak(lhs, rhs)
            case .size:
                compare(lhs.fileSize ?? 0, rhs.fileSize ?? 0, direction: direction) ?? tieBreak(lhs, rhs)
            case .tag:
                compareTag(lhs, rhs, direction: direction) ?? tieBreak(lhs, rhs)
            case .fileName:
                compareText(lhs.originalName, rhs.originalName, direction: direction) ?? tieBreak(lhs, rhs)
            case .type:
                compareText(fileType(lhs), fileType(rhs), direction: direction) ?? tieBreak(lhs, rhs)
            }
        }
    }

    private static func compare<T: Comparable>(
        _ lhs: T,
        _ rhs: T,
        direction: GallerySortDirection
    ) -> Bool? {
        guard lhs != rhs else { return nil }
        return direction == .ascending ? lhs < rhs : lhs > rhs
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

    private static func compareTag(
        _ lhs: LightboxAsset,
        _ rhs: LightboxAsset,
        direction: GallerySortDirection
    ) -> Bool? {
        let lhsRank = sortableTagRank(lhs)
        let rhsRank = sortableTagRank(rhs)
        guard lhsRank != rhsRank else { return nil }
        return direction == .ascending ? lhsRank < rhsRank : lhsRank > rhsRank
    }

    private static func sortableTagRank(_ asset: LightboxAsset) -> Int {
        firstTagRank(asset) ?? Int.max
    }

    private static func firstTagRank(_ asset: LightboxAsset) -> Int? {
        let sortedTags = MacColorTag.sort(asset.tags.filter(MacColorTag.isColorTag))
        guard let firstTag = sortedTags.first else { return nil }
        return MacColorTag.all.firstIndex { $0.name == firstTag }
    }

    private static func fileType(_ asset: LightboxAsset) -> String {
        let extensionFromURL = asset.sourceURL?.pathExtension.lowercased() ?? ""
        if !extensionFromURL.isEmpty {
            return extensionFromURL
        }

        return URL(fileURLWithPath: asset.originalName).pathExtension.lowercased()
    }

    private static func tieBreak(_ lhs: LightboxAsset, _ rhs: LightboxAsset) -> Bool {
        lhs.originalName.localizedStandardCompare(rhs.originalName) == .orderedAscending
    }
}

enum LibraryFilter: Hashable {
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

enum GalleryLayoutMode: String, Hashable {
    case masonry
    case grid

    var next: GalleryLayoutMode {
        switch self {
        case .masonry:
            .grid
        case .grid:
            .masonry
        }
    }

    var iconName: String {
        switch self {
        case .masonry:
            "rectangle.grid.2x2"
        case .grid:
            "square.grid.3x3"
        }
    }

}

struct ImportProgress: Equatable {
    var processed: Int
    var total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }
}
