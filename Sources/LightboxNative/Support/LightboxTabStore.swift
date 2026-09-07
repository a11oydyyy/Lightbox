import Foundation

enum LightboxTabStore {
    private static let tabsKey = "Lightbox.full.tabs.v1"

    static func load(
        sources: [LibrarySource],
        defaults: UserDefaults = .standard
    ) -> (tabs: [LightboxTab], activeTabID: UUID)? {
        guard let data = defaults.data(forKey: tabsKey),
              let session = try? JSONDecoder().decode(TabSessionState.self, from: data)
        else {
            return nil
        }

        let tabs = session.tabs.map { $0.makeTab(resolvingAgainst: sources) }
        guard !tabs.isEmpty else { return nil }
        let activeTabID = tabs.contains(where: { $0.id == session.activeTabID })
            ? session.activeTabID
            : tabs[0].id
        return (tabs, activeTabID)
    }

    static func save(
        tabs: [LightboxTab],
        activeTabID: UUID,
        defaults: UserDefaults = .standard
    ) {
        guard !tabs.isEmpty else { return }
        let session = TabSessionState(
            tabs: tabs.map(TabSession.init),
            activeTabID: tabs.contains(where: { $0.id == activeTabID }) ? activeTabID : tabs[0].id
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: tabsKey)
    }
}

private struct TabSessionState: Codable {
    var tabs: [TabSession]
    var activeTabID: UUID
}

private struct TabSession: Codable {
    var id: UUID
    var source: LibrarySource
    var folderPath: String
    var isStartPage: Bool?
    var backHistory: [TabLocationSession]
    var forwardHistory: [TabLocationSession]
    var searchText: String
    var filter: TabFilterSession
    var sortField: GallerySortField
    var sortDirection: GallerySortDirection
    var layoutMode: GalleryLayoutMode
    var thumbnailWidth: CGFloat
    var scrollAnchorAssetID: LightboxAsset.ID?

    init(_ tab: LightboxTab) {
        id = tab.id
        source = tab.source
        isStartPage = tab.isStartPage
        folderPath = tab.folderURL.standardizedFileURL.path
        backHistory = tab.backHistory.map(TabLocationSession.init)
        forwardHistory = tab.forwardHistory.map(TabLocationSession.init)
        searchText = tab.searchText
        filter = TabFilterSession(tab.filter)
        sortField = tab.sortField
        sortDirection = tab.sortDirection
        layoutMode = tab.layoutMode
        thumbnailWidth = tab.thumbnailWidth
        scrollAnchorAssetID = tab.scrollAnchorAssetID
    }

    func makeTab(resolvingAgainst sources: [LibrarySource]) -> LightboxTab {
        let resolvedSource = sources.first {
            $0.id == source.id || $0.rootURL.standardizedFileURL.path == source.rootURL.standardizedFileURL.path
        } ?? source
        return LightboxTab(
            id: id,
            source: resolvedSource,
            folderURL: URL(fileURLWithPath: folderPath, isDirectory: true),
            isStartPage: isStartPage ?? false,
            backHistory: backHistory.map { $0.makeLocation(resolvingAgainst: sources) },
            forwardHistory: forwardHistory.map { $0.makeLocation(resolvingAgainst: sources) },
            searchText: searchText,
            filter: filter.value,
            sortField: sortField,
            sortDirection: sortDirection,
            layoutMode: layoutMode,
            thumbnailWidth: GalleryThumbnailSizing.clampedStoredWidth(thumbnailWidth),
            scrollAnchorAssetID: scrollAnchorAssetID,
            preservesUnavailableFolder: true
        )
    }
}

private struct TabLocationSession: Codable {
    var source: LibrarySource
    var folderPath: String
    var isStartPage: Bool?
    var filter: TabFilterSession

    init(_ location: LightboxTabLocation) {
        source = location.source
        isStartPage = location.isStartPage
        folderPath = location.folderURL.standardizedFileURL.path
        filter = TabFilterSession(location.filter)
    }

    func makeLocation(resolvingAgainst sources: [LibrarySource]) -> LightboxTabLocation {
        let resolvedSource = sources.first {
            $0.id == source.id || $0.rootURL.standardizedFileURL.path == source.rootURL.standardizedFileURL.path
        } ?? source
        return LightboxTabLocation(
            source: resolvedSource,
            folderURL: URL(fileURLWithPath: folderPath, isDirectory: true),
            filter: filter.value,
            isStartPage: isStartPage ?? false
        )
    }
}

private struct TabFilterSession: Codable {
    enum Kind: String, Codable {
        case all
        case tag
        case trash
    }

    var kind: Kind
    var tag: String?

    init(_ filter: LibraryFilter) {
        switch filter {
        case .all:
            kind = .all
            tag = nil
        case .tag(let tag):
            kind = .tag
            self.tag = tag
        case .trash:
            kind = .trash
            tag = nil
        }
    }

    var value: LibraryFilter {
        switch kind {
        case .all:
            .all
        case .tag:
            tag.map(LibraryFilter.tag) ?? .all
        case .trash:
            .trash
        }
    }
}
