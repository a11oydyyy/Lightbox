import Foundation

struct LightboxTabLocation: Equatable, Sendable {
    var source: LibrarySource
    var folderURL: URL
    var filter: LibraryFilter
    var isStartPage: Bool = false
}

struct LightboxTab: Identifiable, Equatable, Sendable {
    var id: UUID
    var source: LibrarySource
    var folderURL: URL
    var backHistory: [LightboxTabLocation]
    var forwardHistory: [LightboxTabLocation]
    var searchText: String
    var filter: LibraryFilter
    var isStartPage: Bool = false
    var sortField: GallerySortField
    var sortDirection: GallerySortDirection
    var layoutMode: GalleryLayoutMode
    var thumbnailWidth: CGFloat
    var selectedAssetIDs: Set<LightboxAsset.ID>
    var selectedAssetID: LightboxAsset.ID?
    var scrollAnchorAssetID: LightboxAsset.ID?
    var trashAccessDenied: Bool
    var preservesUnavailableFolder: Bool

    init(
        id: UUID = UUID(),
        source: LibrarySource,
        folderURL: URL,
        isStartPage: Bool = false,
        backHistory: [LightboxTabLocation] = [],
        forwardHistory: [LightboxTabLocation] = [],
        searchText: String = "",
        filter: LibraryFilter = .all,
        sortField: GallerySortField = .time,
        sortDirection: GallerySortDirection = .descending,
        layoutMode: GalleryLayoutMode = .masonry,
        thumbnailWidth: CGFloat = 206,
        selectedAssetIDs: Set<LightboxAsset.ID> = [],
        selectedAssetID: LightboxAsset.ID? = nil,
        scrollAnchorAssetID: LightboxAsset.ID? = nil,
        trashAccessDenied: Bool = false,
        preservesUnavailableFolder: Bool = false
    ) {
        self.isStartPage = isStartPage
        self.id = id
        self.source = source
        self.folderURL = folderURL.standardizedFileURL
        self.backHistory = backHistory
        self.forwardHistory = forwardHistory
        self.searchText = searchText
        self.filter = filter
        self.sortField = sortField
        self.sortDirection = sortDirection
        self.layoutMode = layoutMode
        self.thumbnailWidth = thumbnailWidth
        self.selectedAssetIDs = selectedAssetIDs
        self.selectedAssetID = selectedAssetID
        self.scrollAnchorAssetID = scrollAnchorAssetID
        self.trashAccessDenied = trashAccessDenied
        self.preservesUnavailableFolder = preservesUnavailableFolder
    }
}
