import Foundation

/// What the gallery shows for a folder's contents: the images and folders
/// that pass the filter and search, in sort order, and the Finder colors in
/// use. Pure; `AppState` keeps the results and publishes them.
enum GalleryContentFilter {
    /// A sorted, unfiltered copy of a source, reused while only the filter or
    /// search changes: filtering keeps sort order, so it need not sort again.
    struct SortedSource: Equatable {
        var source: [LightboxAsset]
        var field: GallerySortField
        var direction: GallerySortDirection
        var locale: String
        var assets: [LightboxAsset]
    }

    /// The images to show, and the sorted source to keep for next time (nil
    /// when this result cannot serve as one).
    static func visibleAssets(
        from source: [LightboxAsset],
        filter: LibraryFilter,
        attributes: GalleryAttributeFilter = GalleryAttributeFilter(),
        query: LightboxSearchQuery,
        field: GallerySortField,
        direction: GallerySortDirection,
        locale: String = Locale.current.identifier,
        reusing sorted: SortedSource?
    ) -> (assets: [LightboxAsset], sorted: SortedSource?) {
        let reusesSort = filter != .trash && sorted?.field == field && sorted?.direction == direction
            && sorted?.locale == locale && sorted?.source == source
        let candidates = reusesSort ? (sorted?.assets ?? source) : source
        let filtered: [LightboxAsset] = switch filter {
        case .all:
            candidates.filter { !$0.isDeleted }
        case .tag(let tag):
            candidates.filter { !$0.isDeleted && $0.tags.contains(tag) }
        case .trash:
            candidates.filter(\.isDeleted)
        }
        let attributeMatches = attributes.isActive && filter != .trash
            ? filtered.filter(attributes.matcher()) : filtered
        let matches = query.isEmpty ? attributeMatches : attributeMatches.filter(query.matches)
        let ordered = reusesSort ? matches : GalleryAssetSorter.sorted(matches, field: field, direction: direction)
        let keeps = filter == .all && query.isEmpty && !attributes.isActive
        return (ordered, keeps ? SortedSource(source: source, field: field, direction: direction, locale: locale, assets: ordered) : nil)
    }

    /// The folders to show: none in the trash; with a search, those whose
    /// names match (from the search's own folders when it has them).
    static func visibleFolders(
        folders: [LibraryFolderEntry],
        searchFolders: [LibraryFolderEntry]?,
        query: LightboxSearchQuery,
        hasSearchQuery: Bool,
        isViewingTrash: Bool,
        field: GallerySortField,
        direction: GallerySortDirection
    ) -> [LibraryFolderEntry] {
        guard !isViewingTrash else { return [] }
        let shown: [LibraryFolderEntry]
        if !hasSearchQuery || query.isEmpty {
            shown = folders
        } else {
            shown = (searchFolders ?? folders).filter(query.matches)
        }
        return LibraryFolderEntrySorter.sorted(shown, field: field, direction: direction)
    }

    /// The Finder colors used by images that are not in the trash, in Finder's order.
    static func colorTags(in assets: [LightboxAsset]) -> [MacColorTag] {
        let names = Set(assets.lazy.filter { !$0.isDeleted }.flatMap(\.tags))
        return MacColorTag.all.filter { names.contains($0.name) }
    }
}
