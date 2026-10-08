import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct SearchAssetGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var assets: [LightboxAsset]
}

private struct RecursiveSearchScope: Equatable {
    var sourceID: LibrarySource.ID
    var folderPath: String
    var showsHiddenItems: Bool
}

private struct SourceStorageClassification: Equatable {
    var source: LibrarySource
    var conservative: Bool
}

private struct LibraryMonitorContext: Equatable {
    var folderURL: URL
    var recursive: Bool
}

private struct TabContentSnapshot {
    var tab: LightboxTab
    var showsHiddenItems: Bool
    var assets: [LightboxAsset]
    var folders: [LibraryFolderEntry]
    var searchAssets: [LightboxAsset]?
    var searchFolders: [LibraryFolderEntry]?
    var searchStatus: LightboxSearchStatus?
    var activeAssets: [LightboxAsset]
    var activeIDs: Set<LightboxAsset.ID>
    var activeIDList: [LightboxAsset.ID]
    var groups: [SearchAssetGroup]
    var activeFolders: [LibraryFolderEntry]
    var colorTags: [MacColorTag]

    var assetCount: Int { assets.count + (searchAssets?.count ?? 0) }
}

private enum TagMutationAction: Equatable, Sendable {
    case add
    case toggle
}

private struct TagMutationRequest: Sendable {
    var tag: String
    var assets: [LightboxAsset]
    var action: TagMutationAction
    var originTabID: UUID? = nil
    var originFilter: LibraryFilter? = nil
    var originVisibleAssetIDs: Set<LightboxAsset.ID> = []
    var originFolderPath: String? = nil
    var originSearchText: String? = nil
}

private struct TagMutationWrite: Sendable {
    var id: LightboxAsset.ID
    var url: URL?
    var tags: [String]
}

struct AssetMetadataRefreshPolicy: Equatable {
    static let externalAssetTagLimit = 12
    static let localStartDelayMilliseconds = 650
    static let externalStartDelayMilliseconds = 1_600

    var usesConservativeExternalLoading: Bool
    var requiresCompleteAssetTags = false
    var isLocalVolume = false

    func dimensionLimit(assetCount: Int) -> Int {
        assetCount
    }

    func tagLimit(assetCount: Int) -> Int {
        if !usesConservativeExternalLoading || requiresCompleteAssetTags {
            return assetCount
        }
        return min(assetCount, Self.externalAssetTagLimit)
    }

    var startDelayMilliseconds: Int {
        if isLocalVolume { return 100 }
        return usesConservativeExternalLoading ? Self.externalStartDelayMilliseconds : Self.localStartDelayMilliseconds
    }
}

private struct SidebarVolumeObserverToken: @unchecked Sendable {
    var value: NSObjectProtocol
}

struct LibraryRefreshPolicy: Equatable {
    static let externalCachedSnapshotScanDelayMilliseconds = 1_200

    var usesConservativeExternalLoading: Bool
    var hasCachedVisibleSnapshot: Bool

    var scanStartDelayMilliseconds: Int {
        usesConservativeExternalLoading && hasCachedVisibleSnapshot ? Self.externalCachedSnapshotScanDelayMilliseconds : 0
    }
}

@MainActor
final class AppState: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "LibraryLoading")
    nonisolated private static let comparisonLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Comparison")
    nonisolated private static let previewLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Preview")
    nonisolated private static let searchMetadataRefreshLimit = 240
    @Published var sidebarCollapsed = LightboxSettingsStore.defaultSidebarCollapsed {
        didSet {
            LightboxSettingsStore.saveSidebarCollapsed(sidebarCollapsed)
        }
    }
    @Published var sidebarWidth: CGFloat = LightboxSettingsStore.defaultSidebarWidth {
        didSet {
            let clamped = LightboxSettingsStore.clampSidebarWidth(sidebarWidth)
            if sidebarWidth != clamped {
                sidebarWidth = clamped
            }
            LightboxSettingsStore.saveSidebarWidth(clamped)
        }
    }
    @Published var sidebarVisibleLocationIDs: Set<SidebarLocationID> = LightboxSettingsStore.defaultSidebarLocationIDs {
        didSet {
            LightboxSettingsStore.saveSidebarVisibleLocationIDs(sidebarVisibleLocationIDs)
            refreshSidebarDestinations()
        }
    }
    @Published private(set) var sidebarLocations: [SidebarLocationID] = []
    @Published private(set) var sidebarLocationDirectories: [SidebarLocationID: SidebarDirectoryIdentity] = [:]
    @Published private(set) var sidebarVolumes: [SidebarVolume] = []
    @Published var showFolderCards = LightboxSettingsStore.defaultShowFolderCards {
        didSet {
            LightboxSettingsStore.saveShowFolderCards(showFolderCards)
        }
    }
    @Published var showsHiddenItems = LightboxSettingsStore.defaultShowsHiddenItems {
        didSet {
            guard showsHiddenItems != oldValue else { return }
            LightboxSettingsStore.saveShowsHiddenItems(showsHiddenItems)
            refreshLibrary()
            scheduleSearch()
        }
    }
    @Published var selectedFilter: LibraryFilter = .all {
        didSet {
            guard selectedFilter != oldValue else { return }
            guard !isApplyingTabState else { return }
            if selectedFilter == .trash || oldValue == .trash {
                restoreFolderSort()
                cancelPreviewDimensionResolution(clearPendingStep: true)
            }
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
            clearSelection()
            restartLibraryMonitor()
            if case .tag = selectedFilter {
                startCompleteAssetTagRefresh()
            }
            if selectedFilter == .trash || oldValue == .trash {
                refreshLibrary()
            }
            captureActiveTabState()
        }
    }
    @Published var galleryLayoutMode: GalleryLayoutMode = .masonry {
        didSet {
            guard galleryLayoutMode != oldValue, !isApplyingTabState else { return }
            clearSelection()
            scheduleSearch()
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
            restartLibraryMonitor()
            captureActiveTabState()
        }
    }
    @Published var thumbnailWidth: CGFloat = 206 {
        didSet {
            guard thumbnailWidth != oldValue, !isApplyingTabState else { return }
            captureActiveTabState()
        }
    }
    @Published var isScalingThumbnails = false
    @Published var assets: [LightboxAsset] = [] {
        didSet {
            guard !isApplyingTabState, !isApplyingSearchMetadata else { return }
            rebuildLibraryColorTags()
            rebuildActiveAssets()
        }
    }
    @Published var sources: [LibrarySource] = []
    @Published private(set) var tabs: [LightboxTab] = []
    @Published private(set) var activeTabID = UUID()
    @Published private(set) var scrollRestoreGeneration = 0
    @Published var selectedSourceID: LibrarySource.ID = LibrarySource.defaultStartupSource().id
    @Published private var temporarySource: LibrarySource?
    @Published var currentFolderURL: URL = LibrarySource.defaultStartupSource().rootURL {
        didSet {
            guard currentFolderURL.standardizedFileURL != oldValue.standardizedFileURL,
                  !isApplyingTabState else { return }
            cancelPendingFolderPath()
            restoreFolderSort()
        }
    }
    @Published var folderEntries: [LibraryFolderEntry] = [] {
        didSet {
            guard !isApplyingTabState else { return }
            rebuildActiveFolderEntries()
        }
    }
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            guard !isApplyingTabState else { return }
            scheduleSearch()
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
            captureActiveTabState()
        }
    }
    @Published private(set) var searchStatus: LightboxSearchStatus?
    @Published private var searchResultFolderEntries: [LibraryFolderEntry]? {
        didSet {
            guard !isApplyingTabState else { return }
            rebuildActiveFolderEntries()
        }
    }
    @Published private(set) var searchFocusGeneration = 0
    @Published private(set) var goToFolderFocusGeneration = 0
    @Published var sortField: GallerySortField = .time {
        didSet {
            guard sortField != oldValue, !isApplyingTabState, !isRestoringFolderSort else { return }
            saveFolderSort()
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
            captureActiveTabState()
        }
    }
    @Published var sortDirection: GallerySortDirection = .descending {
        didSet {
            guard sortDirection != oldValue, !isApplyingTabState, !isRestoringFolderSort else { return }
            saveFolderSort()
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
            captureActiveTabState()
        }
    }
    @Published var selectedAssetIDs: Set<LightboxAsset.ID> = []
    @Published var selectedGalleryFolderID: LibraryFolderEntry.ID?
    @Published private(set) var galleryKeyboardScrollGeneration = 0
    @Published var galleryKeyboardFocusID: LightboxAsset.ID?
    @Published var selectedAssetID: LightboxAsset.ID?
    @Published var previewAssetID: LightboxAsset.ID?
    @Published var previewSourceHiddenAssetID: LightboxAsset.ID?
    @Published var previewSourceFrame: CGRect?
    @Published var previewSessionID = UUID()
    @Published var previewStepDirection: PreviewDirection?
    @Published private(set) var previewInteractionLayerReady = false
    @Published var comparisonAssets: [LightboxAsset] = []
    @Published var compareTrayAssets: [LightboxAsset] = []
    @Published var compareTrayPulseID: LightboxAsset.ID?
    @Published var compareTrayRejectGeneration = 0
    @Published private(set) var fileTransferProgress: FileTransferProgress?
    @Published private var previewPhase: PreviewPhase = .closed
    @Published var libraryLoadingStatus: LibraryLoadingStatus?
    @Published var trashAccessDenied = false
    @Published var colorMode: LightboxColorMode = .system {
        didSet {
            LightboxSettingsStore.saveColorMode(colorMode)
        }
    }
    let glassOpacity = LightboxSettingsStore.defaultGlassOpacity
    @Published var appLanguage: LightboxLanguage = .english {
        didSet {
            LightboxSettingsStore.saveLanguage(appLanguage)
        }
    }

    private var previewOpenTask: Task<Void, Never>?
    private var previewCloseTask: Task<Void, Never>?
    private var previewSourceRevealTask: Task<Void, Never>?
    private var previewDimensionTask: Task<Void, Never>?
    private var previewDimensionRequestID: UUID?
    private var previewKeyboardFocusSessionID: UUID?
    private var trashMoveTask: Task<Void, Never>?
    private var trashMovingAssetIDs: Set<LightboxAsset.ID> = []
    private var queuedTrashAssets: [LightboxAsset] = []
    private var tagMutationTask: Task<Void, Never>?
    private var queuedTagMutations: [TagMutationRequest] = []
    private var refreshTask: Task<Void, Never>?
    private var libraryLoadTask: Task<Void, Never>?
    private var assetMetadataTask: Task<Void, Never>?
    private var indexWriteTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var isApplyingSearchMetadata = false
    private var recursiveSearchScope: RecursiveSearchScope?
    private var tabPersistenceTask: Task<Void, Never>?
    private var fileTransferTask: Task<Void, Never>?
    private var fileTransferDismissTask: Task<Void, Never>?
    private var tabDragHoverTask: Task<Void, Never>?
    private var sharingPicker: NSSharingServicePicker?
    private var fileActionTask: Task<Void, Never>?
    private var folderPathTask: Task<FolderPathOpenResult, Never>?
    private var folderPathRequestID: UUID?
    private var pendingPinTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var sidebarDestinationTask: Task<Void, Never>?
    private var refreshSerial = 0
    private var libraryDirectoryMonitor: DirectoryChangeMonitor?
    private var libraryMonitorContext: LibraryMonitorContext?
    @Published private var sourceStorageClassification: SourceStorageClassification?
    private let trashDirectoryMonitor: DirectoryChangeMonitor
    private let indexDatabaseURL: URL
    private let sourceIndexWriter: SourceIndexWriter
    let sidebarNavigation: SidebarNavigationState
    private let libraryDefaults: UserDefaults
    private var selectionAnchorID: LightboxAsset.ID?
    @Published private var cachedActiveAssets: [LightboxAsset] = []
    private var cachedActiveAssetIDs: Set<LightboxAsset.ID> = []
    private var cachedActiveAssetIDList: [LightboxAsset.ID] = []
    private var cachedSearchAssetGroups: [SearchAssetGroup] = []
    private var groupFolderIdentities: [URL: (path: String, title: String)] = [:]
    private var groupFolderSources: [LibrarySource] = []
    private var groupFolderScope: URL?
    private var sortedUnfilteredSnapshot: (
        source: [LightboxAsset], field: GallerySortField, direction: GallerySortDirection,
        locale: String, assets: [LightboxAsset]
    )?


    private(set) var activeAssetsRevision = 0
    @Published private var cachedActiveFolderEntries: [LibraryFolderEntry] = []
    @Published private var cachedLibraryColorTags: [MacColorTag] = []
    private var searchResultAssets: [LightboxAsset]?
    private var previewAssetSnapshot: LightboxAsset?
    private var pendingPreviewStepAssetID: LightboxAsset.ID?
    private var storedPreviewSpaceAssetFrames: [LightboxAsset.ID: CGRect] = [:]
    private var previewSpaceAssetFrameProvider: (() -> [LightboxAsset.ID: CGRect])?
    private var previewSpaceAssetFrames: [LightboxAsset.ID: CGRect] {
        previewSpaceAssetFrameProvider?() ?? storedPreviewSpaceAssetFrames
    }
    private var compareTrayPulseTask: Task<Void, Never>?
    private var compareTrayDragID: LightboxAsset.ID?
    private var tabDragID: UUID?
    private var fileTransferQueue: [FileTransferRequest] = []
    private var fileTransferFailureCount = 0
    private var fileTransferFirstFailureName: String?
    private var isApplyingTabState = false
    private var tabContentSnapshots: [UUID: TabContentSnapshot] = [:]
    private var tabContentRecency: [UUID] = []
    private var isPerformingHistoryNavigation = false
    private var isRestoringFolderSort = false
    private var currentScrollAnchorAssetID: LightboxAsset.ID?
    private var preservesUnavailableCurrentFolder = false
    private let compareTrayLimit = 8
    private var sidebarVolumeObserverTokens: [SidebarVolumeObserverToken] = []
    private let previewDimensionProbe: @Sendable (URL) -> CGSize?
    private let searchDimensionProbe: @Sendable (URL) -> CGSize?
    private let directoryProbe: @Sendable (URL) -> Bool
    private let storageClassifier: @Sendable (LibrarySource) -> Bool
    private let directoryMonitorFactory: @Sendable (URL, Bool) -> DirectoryChangeMonitor
    private let sidebarDestinationLoader: @Sendable (Set<SidebarLocationID>) -> SidebarDestinationSnapshot
    private let systemTrashMover: @Sendable (URL) -> Bool
    private let finderTagWriter: @Sendable ([String], URL) -> Bool
    private let compareTrayAssetLoader: @Sendable (URL, CGSize, MockPalette) -> LightboxAsset
    private let fileTransferExecutor: @Sendable (
        FileTransferRequest,
        @escaping @Sendable (FileTransferProgressUpdate) -> Void
    ) -> FileTransferResult

    init(
        indexDatabaseURL: URL = LightboxLibraryStore.indexDatabaseURL,
        libraryDefaults: UserDefaults = .standard,
        previewDimensionProbe: @escaping @Sendable (URL) -> CGSize? = {
            ImageProbe.dimensions(for: $0)
        },
        searchDimensionProbe: @escaping @Sendable (URL) -> CGSize? = {
            ImageProbe.dimensions(for: $0)
        },
        directoryProbe: @escaping @Sendable (URL) -> Bool = DirectoryAccessResolver.isDirectory,
        storageClassifier: @escaping @Sendable (LibrarySource) -> Bool = { $0.usesConservativeExternalLoading },
        directoryMonitorFactory: @escaping @Sendable (URL, Bool) -> DirectoryChangeMonitor = {
            DirectoryChangeMonitor(url: $0, recursive: $1)
        },
        sidebarDestinationLoader: @escaping @Sendable (Set<SidebarLocationID>) -> SidebarDestinationSnapshot = {
            SidebarDestinationSnapshot.load(visibleLocationIDs: $0)
        },
        systemTrashMover: @escaping @Sendable (URL) -> Bool = {
            LightboxLibraryStore.moveToSystemTrash($0)
        },
        finderTagWriter: @escaping @Sendable ([String], URL) -> Bool = {
            FinderTagStore.setColorTags($0, for: $1)
        },
        compareTrayAssetLoader: @escaping @Sendable (URL, CGSize, MockPalette) -> LightboxAsset = { url, fallbackSize, palette in
            let size = ImageProbe.dimensions(for: url) ?? fallbackSize
            return LightboxAsset(
                originalName: url.lastPathComponent,
                width: size.width,
                height: size.height,
                tags: FinderTagStore.colorTags(for: url),
                sourceURL: url,
                addedAt: LocalImageSource.addedDate(for: url) ?? .now,
                contentModifiedAt: LocalImageSource.contentModifiedDate(for: url),
                fileSize: LocalImageSource.fileSize(for: url),
                palette: palette,
                metadataLoaded: true
            )
        },
        fileTransferExecutor: @escaping @Sendable (
            FileTransferRequest,
            @escaping @Sendable (FileTransferProgressUpdate) -> Void
        ) -> FileTransferResult = { request, progress in
            FileTransferService.perform(request, progress: progress)
        }
    ) {
        self.indexDatabaseURL = indexDatabaseURL
        sourceIndexWriter = SourceIndexWriter(databaseURL: indexDatabaseURL)
        self.libraryDefaults = libraryDefaults
        self.sidebarNavigation = SidebarNavigationState(defaults: libraryDefaults)
        self.previewDimensionProbe = previewDimensionProbe
        self.searchDimensionProbe = searchDimensionProbe
        self.directoryProbe = directoryProbe
        self.storageClassifier = storageClassifier
        self.directoryMonitorFactory = directoryMonitorFactory
        self.sidebarDestinationLoader = sidebarDestinationLoader
        self.systemTrashMover = systemTrashMover
        self.finderTagWriter = finderTagWriter
        self.compareTrayAssetLoader = compareTrayAssetLoader
        self.fileTransferExecutor = fileTransferExecutor
        ImageCache.shared.removeMemoryObjects(reason: "app-init")
        colorMode = LightboxSettingsStore.loadColorMode()
        appLanguage = LightboxSettingsStore.loadLanguage()
        sidebarCollapsed = LightboxSettingsStore.loadSidebarCollapsed()
        sidebarWidth = LightboxSettingsStore.loadSidebarWidth()
        sidebarVisibleLocationIDs = LightboxSettingsStore.loadSidebarVisibleLocationIDs()
        showFolderCards = LightboxSettingsStore.loadShowFolderCards()
        showsHiddenItems = LightboxSettingsStore.loadShowsHiddenItems()
        trashDirectoryMonitor = DirectoryChangeMonitor(url: LightboxLibraryStore.primarySystemTrashFolder)
        let loadedSources = LibrarySourceStore.loadSources(defaults: libraryDefaults)
        let fallbackSource = LibrarySource.defaultStartupSource()
        var initialTabs: [LightboxTab]
        var initialActiveTabID: UUID
        var resolvedSource: LibrarySource
        var restoredTemporarySource: LibrarySource?
        var initialFolderURL: URL

        if let restored = LightboxTabStore.load(sources: loadedSources, defaults: libraryDefaults),
           let activeTab = restored.tabs.first(where: { $0.id == restored.activeTabID }) {
            initialTabs = restored.tabs
            initialActiveTabID = activeTab.id
            resolvedSource = activeTab.source
            initialFolderURL = activeTab.folderURL
        } else {
            let savedSourceID = LibrarySourceStore.selectedSourceID(
                default: fallbackSource.id,
                defaults: libraryDefaults
            )
            resolvedSource = loadedSources.first { $0.id == savedSourceID } ?? fallbackSource
            initialFolderURL = resolvedSource.rootURL
            var restoredLegacySession = false

            if let lastSession = LibrarySourceStore.loadLastSession(defaults: libraryDefaults) {
                if let matchedSource = loadedSources.first(where: {
                    $0.id == lastSession.sourceID ||
                    $0.rootURL.standardizedFileURL.path == lastSession.sourceRootURL.path
                }) {
                    resolvedSource = matchedSource
                    initialFolderURL = lastSession.folderURL
                    restoredLegacySession = true
                } else if lastSession.sourceKind == .external {
                    let temporary = LibrarySource(
                        id: lastSession.sourceID,
                        name: lastSession.sourceName,
                        rootURL: lastSession.sourceRootURL,
                        kind: .external
                    )
                    restoredTemporarySource = temporary
                    resolvedSource = temporary
                    initialFolderURL = lastSession.folderURL
                    restoredLegacySession = true
                }
            }

            let initialTab = LightboxTab(
                source: resolvedSource,
                folderURL: initialFolderURL,
                preservesUnavailableFolder: restoredLegacySession
            )
            initialTabs = [initialTab]
            initialActiveTabID = initialTab.id
        }

        let activeInitialTab = initialTabs.first(where: { $0.id == initialActiveTabID }) ?? initialTabs[0]
        // Restore the whole tab before observers start searches or monitors.
        isApplyingTabState = true
        recentFolderURLs = (libraryDefaults.stringArray(forKey: "Lightbox.recentFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        sources = loadedSources
        if loadedSources.contains(where: { sourceMatches($0, resolvedSource) }) {
            temporarySource = restoredTemporarySource
        } else {
            temporarySource = restoredTemporarySource ?? resolvedSource
        }
        tabs = initialTabs
        activeTabID = activeInitialTab.id
        selectedSourceID = resolvedSource.id
        currentFolderURL = initialFolderURL
        selectedFilter = activeInitialTab.filter
        searchText = activeInitialTab.searchText
        sortField = activeInitialTab.sortField
        sortDirection = activeInitialTab.sortDirection
        restoreFolderSort(resetUnconfigured: false)
        galleryLayoutMode = activeInitialTab.layoutMode
        thumbnailWidth = activeInitialTab.thumbnailWidth
        currentScrollAnchorAssetID = activeInitialTab.scrollAnchorAssetID
        preservesUnavailableCurrentFolder = activeInitialTab.preservesUnavailableFolder
        scrollRestoreGeneration = 1
        isApplyingTabState = false
        LibrarySourceStore.saveSelectedSourceID(resolvedSource.id, defaults: libraryDefaults)
        saveCurrentFolderSession()
        persistTabsImmediately()
        refreshSidebarDestinations()
        startSidebarVolumeMonitoring()
        refreshLibrary()
        restartLibraryMonitor()
        trashDirectoryMonitor.start { [weak self] in
            self?.scheduleLibraryRefresh()
        }
    }

    deinit {
        libraryDirectoryMonitor?.stop()
        trashDirectoryMonitor.stop()
        refreshTask?.cancel()
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        previewDimensionTask?.cancel()
        trashMoveTask?.cancel()
        tagMutationTask?.cancel()
        libraryLoadTask?.cancel()
        assetMetadataTask?.cancel()
        indexWriteTask?.cancel()
        searchTask?.cancel()
        tabPersistenceTask?.cancel()
        fileTransferTask?.cancel()
        fileActionTask?.cancel()
        folderPathTask?.cancel()
        sidebarDestinationTask?.cancel()
        for pending in pendingPinTasks.values { pending.task.cancel() }
        fileTransferDismissTask?.cancel()
        tabDragHoverTask?.cancel()
        compareTrayPulseTask?.cancel()
        for token in sidebarVolumeObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token.value)
        }
    }

    var activeTab: LightboxTab? {
        tabs.first { $0.id == activeTabID }
    }

    var canGoBack: Bool {
        activeTab?.backHistory.isEmpty == false
    }

    var canGoForward: Bool {
        activeTab?.forwardHistory.isEmpty == false
    }

    var activeTabScrollAnchorAssetID: LightboxAsset.ID? {
        currentScrollAnchorAssetID
    }

    func tabTitle(_ tab: LightboxTab) -> String {
        if tab.isStartPage { return localized(.newTab) }
        if tab.filter == .trash {
            return localized(.trash)
        }

        let folderName = tab.folderURL.lastPathComponent
        return folderName.isEmpty ? tab.source.displayName : folderName
    }

    func tabPath(_ tab: LightboxTab) -> String {
        if tab.isStartPage { return localized(.newTab) }
        return tab.filter == .trash
            ? LightboxLibraryStore.primarySystemTrashFolder.path
            : tab.folderURL.standardizedFileURL.path
    }

    func updateActiveTabScrollAnchor(_ assetID: LightboxAsset.ID?) {
        guard currentScrollAnchorAssetID != assetID else { return }
        currentScrollAnchorAssetID = assetID
        // Scroll position is bookkeeping, not a tab presentation change.
        // Publishing tabs here invalidates every AppState observer while scrolling.
        scheduleTabPersistence()
    }

    var isShowingStartPage: Bool { activeTab?.isStartPage == true }
    @Published private(set) var recentFolderURLs: [URL] = []

    func newTab() {
        captureActiveTabState()
        guard let index = activeTabIndex else { return }
        let current = tabs[index]
        let source = LibrarySource.defaultStartupSource()
        let tab = LightboxTab(
            source: source, folderURL: source.rootURL, isStartPage: true,
            sortField: current.sortField, sortDirection: current.sortDirection,
            layoutMode: current.layoutMode, thumbnailWidth: current.thumbnailWidth
        )
        tabs.insert(tab, at: max(index + 1, tabs.filter(\.isPinned).count))
        activateTab(tab.id, capturingCurrent: false)
    }

    func selectTab(_ tabID: UUID) {
        activateTab(tabID, capturingCurrent: true)
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let index = activeTabIndex else { return }
        let previousIndex = index == 0 ? tabs.count - 1 : index - 1
        selectTab(tabs[previousIndex].id)
    }

    func selectNextTab() {
        guard tabs.count > 1, let index = activeTabIndex else { return }
        selectTab(tabs[(index + 1) % tabs.count].id)
    }

    func selectTab(atShortcutIndex shortcutIndex: Int) {
        guard !tabs.isEmpty else { return }
        let index = shortcutIndex == 9 ? tabs.count - 1 : shortcutIndex - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func closeActiveTab() {
        closeTab(activeTabID)
    }

    func duplicateTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        captureActiveTabState()
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var duplicate = tabs[index]
        duplicate.id = UUID()
        duplicate.isPinned = false
        duplicate.selectedAssetIDs = []
        duplicate.selectedAssetID = nil
        tabs.insert(duplicate, at: max(index + 1, tabs.filter(\.isPinned).count))
        activateTab(duplicate.id, capturingCurrent: false)
    }

    func canCloseTabsAfter(_ tabID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        return tabs.dropFirst(index + 1).contains { !$0.isPinned }
    }

    func canCloseOtherTabs(keeping tabID: UUID) -> Bool {
        tabs.contains { $0.id != tabID && !$0.isPinned }
    }

    func toggleTabPinned(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        captureActiveTabState()
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var tab = tabs.remove(at: index)
        tab.isPinned.toggle()
        tabs.insert(tab, at: tabs.filter(\.isPinned).count)
        persistTabsImmediately()
    }

    func closeOtherTabs(keeping tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        closeTabs(Set(tabs.filter { $0.id != tabID && !$0.isPinned }.map(\.id)), keeping: tabID)
    }

    func closeTabsAfter(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        closeTabs(Set(tabs.dropFirst(index + 1).filter { !$0.isPinned }.map(\.id)), keeping: tabID)
    }

    private func closeTabs(_ tabIDs: Set<UUID>, keeping tabID: UUID) {
        guard !tabIDs.isEmpty else { return }
        captureActiveTabState()
        let closesActiveTab = tabIDs.contains(activeTabID)
        tabs.removeAll { tabIDs.contains($0.id) }
        for id in tabIDs { tabContentSnapshots.removeValue(forKey: id) }
        tabContentRecency.removeAll { tabIDs.contains($0) }
        if closesActiveTab {
            activateTab(tabID, capturingCurrent: false)
        } else {
            persistTabsImmediately()
        }
    }

    func copyTabPathToClipboard(_ tabID: UUID) {
        captureActiveTabState()
        guard let tab = tabs.first(where: { $0.id == tabID }), !tab.isStartPage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tabPath(tab), forType: .string)
    }

    func revealTabInFinder(_ tabID: UUID) {
        captureActiveTabState()
        guard let tab = tabs.first(where: { $0.id == tabID }), !tab.isStartPage else { return }
        revealSidebarURLInFinder(tab.filter == .trash ? LightboxLibraryStore.primarySystemTrashFolder : tab.folderURL)
    }

    func closeTab(_ tabID: UUID) {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabContentSnapshots.removeValue(forKey: tabID)
        tabContentRecency.removeAll { $0 == tabID }

        if tabs.count == 1 {
            captureActiveTabState()
            let source = LibrarySource.defaultStartupSource()
            let resetTab = LightboxTab(source: source, folderURL: source.rootURL, isStartPage: true)
            tabs = [resetTab]
            activateTab(resetTab.id, capturingCurrent: false)
            return
        }

        let closesActiveTab = tabID == activeTabID
        if closesActiveTab {
            captureActiveTabState()
        }
        tabs.remove(at: closingIndex)

        if closesActiveTab {
            let replacementIndex = min(closingIndex, tabs.count - 1)
            activateTab(tabs[replacementIndex].id, capturingCurrent: false)
        } else {
            persistTabsImmediately()
        }
    }

    func reorderTabs(_ ids: [UUID], before target: UUID?) {
        let next = SidebarOrder.moving(ids, before: target, in: tabs)
        // Pinned tabs remain a leading group, including when dropped at the end.
        let grouped = next.filter(\.isPinned) + next.filter { !$0.isPinned }
        guard grouped.map(\.id) != tabs.map(\.id) else { return }
        tabs = grouped
        persistTabsImmediately()
    }

    var isRefreshingGallery: Bool {
        libraryLoadingStatus != nil || searchStatus?.isSearching == true
    }

    func refreshGalleryFromGesture() {
        guard !isShowingStartPage, !hasActiveOverlay, !isRefreshingGallery else { return }
        refreshLibrary(preservingVisibleSnapshot: true)
    }

    func beginTabDrag(_ tabID: UUID) {
        tabDragID = tabID
    }

    func moveDraggedTab(before targetID: UUID) {
        guard let tabDragID,
              tabDragID != targetID,
              let fromIndex = tabs.firstIndex(where: { $0.id == tabDragID }),
              let toIndex = tabs.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        guard tabs[fromIndex].isPinned == tabs[toIndex].isPinned else { return }

        let tab = tabs.remove(at: fromIndex)
        let insertionIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        tabs.insert(tab, at: insertionIndex)
        persistTabsImmediately()
    }

    func endTabDrag() {
        tabDragID = nil
    }

    func dragSourceURLs(for asset: LightboxAsset) -> [URL] {
        let targets: [LightboxAsset]
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            targets = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        } else {
            targets = [asset]
        }

        return targets.compactMap { target in
            guard !target.isDeleted, let sourceURL = target.sourceURL else {
                return nil
            }
            return sourceURL.standardizedFileURL
        }
    }

    func canReceiveFileDrop(on tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return !tab.isStartPage && tab.filter != .trash
    }

    @discardableResult
    func enqueueFileTransfer(
        sourceURLs: [URL],
        to tabID: UUID,
        operation: FileTransferOperation
    ) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              !tab.isStartPage, tab.filter != .trash
        else {
            return false
        }

        var seenPaths = Set<String>()
        let urls = sourceURLs.compactMap { url -> URL? in
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL,
                  seenPaths.insert(standardized.path).inserted
            else {
                return nil
            }
            return standardized
        }
        guard !urls.isEmpty else { return false }

        if fileTransferTask == nil,
           fileTransferQueue.isEmpty,
           fileTransferProgress?.phase != .failed {
            fileTransferFailureCount = 0
            fileTransferFirstFailureName = nil
        }
        fileTransferDismissTask?.cancel()
        fileTransferDismissTask = nil
        fileTransferQueue.append(
            FileTransferRequest(
                sourceURLs: urls,
                destinationFolderURL: tab.folderURL,
                operation: operation
            )
        )
        startNextFileTransferIfNeeded()
        return true
    }

    func scheduleTabActivationForAssetDrag(_ tabID: UUID) {
        guard tabID != activeTabID, canReceiveFileDrop(on: tabID) else { return }
        tabDragHoverTask?.cancel()
        tabDragHoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            self?.selectTab(tabID)
        }
    }

    func cancelTabActivationForAssetDrag() {
        tabDragHoverTask?.cancel()
        tabDragHoverTask = nil
    }

    func cancelFileTransfer() {
        fileTransferQueue = []
        fileTransferTask?.cancel()
    }

    func fileTransferStatusText(_ progress: FileTransferProgress) -> String {
        switch progress.phase {
        case .active:
            let action = localized(progress.operation == .copy ? .copyingFiles : .movingFiles)
            return "\(action) \(min(progress.completedCount, progress.totalCount))/\(progress.totalCount)"
        case .completed:
            return localized(.fileTransferComplete)
        case .failed:
            return "\(localized(.fileTransferFailed)) (\(progress.failedCount))"
        case .cancelled:
            return localized(.fileTransferCancelled)
        }
    }

    private func startNextFileTransferIfNeeded() {
        guard fileTransferTask == nil, !fileTransferQueue.isEmpty else { return }
        let request = fileTransferQueue.removeFirst()
        fileTransferProgress = FileTransferProgress(
            requestID: request.id,
            operation: request.operation,
            phase: .active,
            completedCount: 0,
            totalCount: request.sourceURLs.count,
            failedCount: fileTransferFailureCount,
            currentName: request.sourceURLs.first?.lastPathComponent ?? ""
        )

        let executor = fileTransferExecutor
        let progressHandler: @Sendable (FileTransferProgressUpdate) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.applyFileTransferProgress(update, requestID: request.id)
            }
        }
        fileTransferTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = executor(request, progressHandler)
            await self?.finishFileTransfer(result)
        }
    }

    private func applyFileTransferProgress(_ update: FileTransferProgressUpdate, requestID: UUID) {
        guard fileTransferProgress?.requestID == requestID,
              fileTransferProgress?.phase == .active
        else {
            return
        }
        fileTransferProgress?.completedCount = update.completedCount
        fileTransferProgress?.totalCount = update.totalCount
        fileTransferProgress?.currentName = update.currentName
    }

    private func finishFileTransfer(_ result: FileTransferResult) {
        guard fileTransferProgress?.requestID == result.requestID else {
            fileTransferTask = nil
            startNextFileTransferIfNeeded()
            return
        }

        applyFileTransferResult(result)
        fileTransferFailureCount += result.failures.count
        if fileTransferFirstFailureName == nil, let firstFailure = result.failures.first {
            fileTransferFirstFailureName = firstFailure.sourceURL.lastPathComponent
        }
        fileTransferProgress?.completedCount = result.successes.count + result.failures.count
        fileTransferProgress?.failedCount = fileTransferFailureCount
        if result.wasCancelled {
            if fileTransferFailureCount == 0 {
                fileTransferProgress?.phase = .cancelled
            } else {
                fileTransferProgress?.phase = .failed
                fileTransferProgress?.currentName = fileTransferFirstFailureName ?? ""
            }
        }
        fileTransferTask = nil

        if !fileTransferQueue.isEmpty {
            startNextFileTransferIfNeeded()
            return
        }

        if !result.wasCancelled {
            if fileTransferFailureCount == 0 {
                fileTransferProgress?.phase = .completed
            } else {
                fileTransferProgress?.phase = .failed
                fileTransferProgress?.currentName = fileTransferFirstFailureName ?? ""
            }
        }

        if fileTransferFailureCount == 0, !result.wasCancelled {
            let requestID = result.requestID
            fileTransferDismissTask?.cancel()
            fileTransferDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled, self?.fileTransferProgress?.requestID == requestID else { return }
                self?.fileTransferProgress = nil
            }
        }
    }

    func dismissFileTransferStatus() {
        guard fileTransferProgress?.phase != .active else { return }
        fileTransferDismissTask?.cancel()
        fileTransferDismissTask = nil
        fileTransferProgress = nil
        fileTransferFailureCount = 0
        fileTransferFirstFailureName = nil
    }

    private func applyFileTransferResult(_ result: FileTransferResult) {
        let committedFailureDestinations = result.failures.compactMap(\.committedDestinationURL)
        guard !result.successes.isEmpty || !committedFailureDestinations.isEmpty else { return }
        let effectiveMoves = result.operation == .move
            ? result.successes.filter {
                $0.sourceURL.standardizedFileURL.path != $0.destinationURL.standardizedFileURL.path
            }
            : []
        let movedSourcePaths = result.operation == .move
            ? Set(effectiveMoves.map { $0.sourceURL.standardizedFileURL.path })
            : []
        let affectedFolderPaths = Set(
            result.successes.flatMap { success in
                var paths = [success.destinationURL.deletingLastPathComponent().standardizedFileURL.path]
                if result.operation == .move {
                    paths.append(success.sourceURL.deletingLastPathComponent().standardizedFileURL.path)
                }
                return paths
            } + committedFailureDestinations.map {
                $0.deletingLastPathComponent().standardizedFileURL.path
            }
        )

        if !movedSourcePaths.isEmpty {
            for index in tabs.indices {
                tabs[index].selectedAssetIDs = tabs[index].selectedAssetIDs.filter { assetID in
                    !movedSourcePaths.contains(Self.sourcePath(fromAssetID: assetID) ?? "")
                }
                if let selectedID = tabs[index].selectedAssetID,
                   movedSourcePaths.contains(Self.sourcePath(fromAssetID: selectedID) ?? "") {
                    tabs[index].selectedAssetID = nil
                }
            }

            assets.removeAll { asset in
                asset.sourceURL.map { movedSourcePaths.contains($0.standardizedFileURL.path) } == true
            }
            searchResultAssets?.removeAll { asset in
                asset.sourceURL.map { movedSourcePaths.contains($0.standardizedFileURL.path) } == true
            }
            selectedAssetIDs = selectedAssetIDs.filter { assetID in
                !movedSourcePaths.contains(Self.sourcePath(fromAssetID: assetID) ?? "")
            }
            if let selectedAssetID,
               movedSourcePaths.contains(Self.sourcePath(fromAssetID: selectedAssetID) ?? "") {
                self.selectedAssetID = firstVisibleID(in: selectedAssetIDs)
            }
            updateCompareTrayAfterMove(effectiveMoves)
            rebuildActiveAssets()
        }

        ImageCache.shared.removeThumbnailMemoryObjects(reason: "file-transfer")
        captureActiveTabState()
        if affectedFolderPaths.contains(currentFolderURL.standardizedFileURL.path) {
            scheduleLibraryRefresh()
        }
    }

    private func updateCompareTrayAfterMove(_ successes: [FileTransferSuccess]) {
        let destinationsBySourcePath = Dictionary(
            uniqueKeysWithValues: successes.map {
                ($0.sourceURL.standardizedFileURL.path, $0.destinationURL.standardizedFileURL)
            }
        )
        compareTrayAssets = compareTrayAssets.map { asset in
            guard let sourceURL = asset.sourceURL,
                  let destinationURL = destinationsBySourcePath[sourceURL.standardizedFileURL.path]
            else {
                return asset
            }
            return LightboxAsset(
                originalName: destinationURL.lastPathComponent,
                width: asset.width,
                height: asset.height,
                tags: asset.tags,
                sourceURL: destinationURL,
                addedAt: asset.addedAt,
                contentModifiedAt: asset.contentModifiedAt,
                fileSize: asset.fileSize,
                palette: asset.palette,
                metadataLoaded: asset.metadataLoaded
            )
        }
    }

    private static func sourcePath(fromAssetID assetID: LightboxAsset.ID) -> String? {
        guard assetID.hasPrefix("file:") else { return nil }
        return String(assetID.dropFirst("file:".count))
    }

    func goBack() {
        guard let index = activeTabIndex, let destination = tabs[index].backHistory.popLast() else { return }
        if let currentLocation {
            tabs[index].forwardHistory.append(currentLocation)
        }
        performHistoryNavigation(to: destination)
    }

    func goForward() {
        guard let index = activeTabIndex, let destination = tabs[index].forwardHistory.popLast() else { return }
        if let currentLocation {
            tabs[index].backHistory.append(currentLocation)
        }
        performHistoryNavigation(to: destination)
    }

    func openFolderInNewTab(_ folder: LibraryFolderEntry) {
        cancelPendingFolderPath()
        let standardizedURL = folder.url.standardizedFileURL
        let source = sources.first { $0.id == folder.sourceID }
            ?? (selectedSource?.id == folder.sourceID ? selectedSource : nil)
            ?? bestSource(containing: standardizedURL)
            ?? LibrarySourceStore.makeExternalSource(rootURL: standardizedURL)
        insertAndActivateTab(source: source, folderURL: standardizedURL, filter: .all)
    }

    func openSidebarFolderInNewTab(_ url: URL) {
        cancelPendingFolderPath()
        let standardizedURL = url.standardizedFileURL
        let source = bestSource(containing: standardizedURL)
            ?? LibrarySourceStore.makeExternalSource(rootURL: standardizedURL)
        sourceIndexWriter.upsertSource(source)
        insertAndActivateTab(source: source, folderURL: standardizedURL, filter: .all)
    }

    func openTrashInNewTab() {
        guard let source = selectedSource else { return }
        insertAndActivateTab(source: source, folderURL: currentFolderURL, filter: .trash)
    }

    private var activeTabIndex: Int? {
        tabs.firstIndex { $0.id == activeTabID }
    }

    private var currentLocation: LightboxTabLocation? {
        guard let source = selectedSource else { return nil }
        return LightboxTabLocation(source: source, folderURL: currentFolderURL, filter: selectedFilter, isStartPage: isShowingStartPage)
    }

    private func activateTab(_ tabID: UUID, capturingCurrent: Bool) {
        guard tabID != activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID })
        else {
            if tabID == activeTabID {
                persistTabsImmediately()
            }
            return
        }

        if capturingCurrent {
            captureActiveTabState()
        }
        cacheActiveTabContent()
        closeOverlaysForTabSwitch()
        suspendActiveTabWork()
        applyTab(at: index)
    }

    private func applyTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        cancelPendingFolderPath()
        let startedAt = Date()
        let tab = tabs[index]
        let resolvedSource = sources.first { sourceMatches($0, tab.source) } ?? tab.source

        isApplyingTabState = true
        activeTabID = tab.id
        selectedGalleryFolderID = nil
        galleryKeyboardFocusID = nil
        tabs[index].source = resolvedSource
        temporarySource = sources.contains(where: { sourceMatches($0, resolvedSource) }) ? nil : resolvedSource
        selectedSourceID = resolvedSource.id
        currentFolderURL = tab.folderURL
        selectedFilter = tab.filter
        searchText = tab.searchText
        sortField = tab.sortField
        sortDirection = tab.sortDirection
        restoreFolderSort(resetUnconfigured: false)
        galleryLayoutMode = tab.layoutMode
        thumbnailWidth = tab.thumbnailWidth
        assets = []
        folderEntries = []
        searchResultAssets = nil
        searchResultFolderEntries = nil
        searchStatus = nil
        selectedAssetIDs = tab.selectedAssetIDs
        selectedAssetID = tab.selectedAssetID
        trashAccessDenied = tab.trashAccessDenied
        currentScrollAnchorAssetID = tab.scrollAnchorAssetID
        preservesUnavailableCurrentFolder = tab.preservesUnavailableFolder
        let restoredContent = restoreTabContent(tab)
        isApplyingTabState = false

        if !restoredContent {
            rebuildLibraryColorTags()
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
        }
        selectionAnchorID = tab.selectedAssetID ?? firstVisibleID(in: tab.selectedAssetIDs)
        scrollRestoreGeneration += 1
        LibrarySourceStore.saveSelectedSourceID(resolvedSource.id, defaults: libraryDefaults)
        saveCurrentFolderSession()
        persistTabsImmediately()
        restartLibraryMonitor()
        refreshLibrary(preservingVisibleSnapshot: restoredContent)
        Self.logger.info("tab applied cached=\(restoredContent) assets=\(self.cachedActiveAssets.count) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
    }

    private func cacheActiveTabContent() {
        let openIDs = Set(tabs.map(\.id))
        tabContentSnapshots = tabContentSnapshots.filter { openIDs.contains($0.key) }
        tabContentRecency.removeAll { !openIDs.contains($0) }
        guard let index = activeTabIndex, !isShowingStartPage, !isViewingTrash,
              libraryLoadingStatus == nil, searchStatus?.isSearching != true,
              !usesRecursiveResults || searchResultAssets != nil else { return }
        let snapshot = TabContentSnapshot(
            tab: tabs[index], showsHiddenItems: showsHiddenItems,
            assets: assets, folders: folderEntries,
            searchAssets: searchResultAssets, searchFolders: searchResultFolderEntries,
            searchStatus: searchStatus, activeAssets: cachedActiveAssets,
            activeIDs: cachedActiveAssetIDs, activeIDList: cachedActiveAssetIDList,
            groups: cachedSearchAssetGroups, activeFolders: cachedActiveFolderEntries,
            colorTags: cachedLibraryColorTags
        )
        // Retain metadata, not decoded pixels; bound both tab count and library size.
        guard snapshot.assetCount <= 50_000 else { return }
        tabContentSnapshots[activeTabID] = snapshot
        tabContentRecency.removeAll { $0 == activeTabID }
        tabContentRecency.append(activeTabID)
        while tabContentRecency.count > 3 || tabContentSnapshots.values.reduce(0, { $0 + $1.assetCount }) > 50_000 {
            tabContentSnapshots.removeValue(forKey: tabContentRecency.removeFirst())
        }
    }

    private func restoreTabContent(_ tab: LightboxTab) -> Bool {
        guard let snapshot = tabContentSnapshots[tab.id],
              snapshot.tab.source.id == selectedSourceID,
              snapshot.tab.folderURL == currentFolderURL,
              snapshot.tab.searchText == searchText,
              snapshot.tab.filter == selectedFilter,
              snapshot.tab.sortField == sortField,
              snapshot.tab.sortDirection == sortDirection,
              snapshot.tab.layoutMode == galleryLayoutMode,
              snapshot.showsHiddenItems == showsHiddenItems else { return false }
        assets = snapshot.assets
        folderEntries = snapshot.folders
        searchResultAssets = snapshot.searchAssets
        searchResultFolderEntries = snapshot.searchFolders
        searchStatus = snapshot.searchStatus
        cachedActiveAssetIDs = snapshot.activeIDs
        cachedActiveAssetIDList = snapshot.activeIDList
        cachedSearchAssetGroups = snapshot.groups
        cachedActiveFolderEntries = snapshot.activeFolders
        cachedLibraryColorTags = snapshot.colorTags
        activeAssetsRevision &+= 1
        cachedActiveAssets = snapshot.activeAssets
        return true
    }

    private func insertAndActivateTab(
        source: LibrarySource,
        folderURL: URL,
        filter: LibraryFilter
    ) {
        captureActiveTabState()
        let insertionIndex = (activeTabIndex ?? max(0, tabs.count - 1)) + 1
        let tab = LightboxTab(
            source: source,
            folderURL: folderURL,
            filter: filter,
            sortField: .time,
            sortDirection: .descending,
            layoutMode: galleryLayoutMode,
            thumbnailWidth: thumbnailWidth
        )
        tabs.insert(tab, at: min(max(insertionIndex, tabs.filter(\.isPinned).count), tabs.count))
        activateTab(tab.id, capturingCurrent: false)
    }

    private func captureActiveTabState() {
        guard !isApplyingTabState,
              let index = activeTabIndex,
              let source = selectedSource
        else {
            return
        }

        var snapshot = tabs[index]
        snapshot.source = source
        snapshot.folderURL = currentFolderURL.standardizedFileURL
        snapshot.searchText = searchText
        snapshot.filter = selectedFilter
        snapshot.sortField = sortField
        snapshot.sortDirection = sortDirection
        snapshot.layoutMode = galleryLayoutMode
        snapshot.thumbnailWidth = thumbnailWidth
        snapshot.selectedAssetIDs = selectedAssetIDs
        snapshot.selectedAssetID = selectedAssetID
        snapshot.scrollAnchorAssetID = currentScrollAnchorAssetID
        snapshot.trashAccessDenied = trashAccessDenied
        snapshot.preservesUnavailableFolder = preservesUnavailableCurrentFolder
        guard snapshot != tabs[index] else { return }
        tabs[index] = snapshot
        scheduleTabPersistence()
    }

    private func recordNavigation(
        to source: LibrarySource,
        folderURL: URL,
        filter: LibraryFilter
    ) {
        guard !isApplyingTabState,
              !isPerformingHistoryNavigation,
              let index = activeTabIndex,
              let currentLocation
        else {
            return
        }

        let destinationPath = folderURL.standardizedFileURL.path
        guard currentLocation.source.id != source.id
                || currentLocation.folderURL.standardizedFileURL.path != destinationPath
                || currentLocation.filter != filter
                || currentLocation.isStartPage
        else {
            return
        }

        tabs[index].backHistory.append(currentLocation)
        tabs[index].forwardHistory = []
        scheduleTabPersistence()
    }

    private func performHistoryNavigation(to destination: LightboxTabLocation) {
        cancelPendingFolderPath()
        closeOverlaysForTabSwitch()
        isPerformingHistoryNavigation = true
        isApplyingTabState = true
        clearContentForFolderNavigation()

        if let index = activeTabIndex { tabs[index].isStartPage = destination.isStartPage }
        selectedGalleryFolderID = nil
        galleryKeyboardFocusID = nil
        let resolvedSource = sources.first { sourceMatches($0, destination.source) } ?? destination.source
        temporarySource = sources.contains(where: { sourceMatches($0, resolvedSource) }) ? nil : resolvedSource
        selectedSourceID = resolvedSource.id
        currentFolderURL = destination.folderURL.standardizedFileURL
        selectedFilter = destination.filter
        restoreFolderSort()
        searchText = ""
        selectedAssetIDs = []
        selectedAssetID = nil
        selectionAnchorID = nil
        searchResultAssets = nil
        searchResultFolderEntries = nil
        searchStatus = nil
        currentScrollAnchorAssetID = nil
        preservesUnavailableCurrentFolder = true
        isApplyingTabState = false
        rebuildLibraryColorTags()
        rebuildActiveAssets()
        rebuildActiveFolderEntries()
        scrollRestoreGeneration += 1
        LibrarySourceStore.saveSelectedSourceID(resolvedSource.id, defaults: libraryDefaults)
        saveCurrentFolderSession()
        persistTabsImmediately()
        isPerformingHistoryNavigation = false
        ImageCache.shared.removeThumbnailMemoryObjects(reason: "history-navigation")
        restartLibraryMonitor()
        refreshLibrary()
    }

    private func resetScrollForNavigation() {
        currentScrollAnchorAssetID = nil
        scrollRestoreGeneration += 1
    }

    private func closeOverlaysForTabSwitch() {
        if isPreviewPresented {
            closePreview()
        }
        if isComparing {
            closeComparison()
        }
    }

    private func suspendActiveTabWork() {
        refreshTask?.cancel()
        refreshTask = nil
        libraryLoadTask?.cancel()
        libraryLoadTask = nil
        assetMetadataTask?.cancel()
        assetMetadataTask = nil
        indexWriteTask?.cancel()
        indexWriteTask = nil
        searchTask?.cancel()
        searchGeneration &+= 1
        searchTask = nil
        recursiveSearchScope = nil
        libraryDirectoryMonitor?.stop()
        libraryDirectoryMonitor = nil
        libraryLoadingStatus = nil
        refreshSerial += 1
        ImageCache.shared.cancelOutstandingRequests(reason: "switch-tab")
    }

    private var folderSortPreferenceKey: String {
        let location = isViewingTrash ? "trash" : "folder:" + currentFolderURL.standardizedFileURL.path
        return "Lightbox.folderSort.v1." + location
    }

    private func saveFolderSort() {
        guard !isShowingStartPage else { return }
        libraryDefaults.set(["field": sortField.rawValue, "direction": sortDirection.rawValue],
                            forKey: folderSortPreferenceKey)
    }

    private func restoreFolderSort(resetUnconfigured: Bool = true) {
        guard !isShowingStartPage else { return }
        let saved = libraryDefaults.object(forKey: folderSortPreferenceKey) as? [String: String]
        let field = saved?["field"].flatMap(GallerySortField.init(rawValue:))
        let direction = saved?["direction"].flatMap(GallerySortDirection.init(rawValue:))
        guard resetUnconfigured || (field != nil && direction != nil) else { return }
        isRestoringFolderSort = true
        sortField = field ?? .time
        sortDirection = direction ?? .descending
        isRestoringFolderSort = false
        if !isApplyingTabState {
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
        }
    }

    private func scheduleTabPersistence() {
        guard !tabs.isEmpty else { return }
        tabPersistenceTask?.cancel()
        tabPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.persistTabsImmediately()
        }
    }

    private func persistTabsImmediately() {
        guard !tabs.isEmpty else { return }
        tabPersistenceTask?.cancel()
        tabPersistenceTask = nil
        var snapshot = tabs
        if let index = activeTabIndex {
            snapshot[index].scrollAnchorAssetID = currentScrollAnchorAssetID
            snapshot[index].sortField = sortField
            snapshot[index].sortDirection = sortDirection
        }
        LightboxTabStore.save(tabs: snapshot, activeTabID: activeTabID, defaults: libraryDefaults)
    }

    var activeAssets: [LightboxAsset] {
        cachedActiveAssets
    }

    var isViewingTrash: Bool {
        selectedFilter == .trash
    }

    var includesSubfolders: Bool { galleryLayoutMode == .recursive && !isViewingTrash }
    var usesRecursiveResults: Bool { !isViewingTrash && (hasSearchQuery || includesSubfolders) }

    var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeFolderEntries: [LibraryFolderEntry] {
        cachedActiveFolderEntries
    }

    var searchAssetGroups: [SearchAssetGroup] {
        cachedSearchAssetGroups
    }

    var activeAssetIDs: Set<LightboxAsset.ID> { cachedActiveAssetIDs }
    var activeAssetIDList: [LightboxAsset.ID] { cachedActiveAssetIDList }

    private func makeSearchAssetGroups(for activeAssets: [LightboxAsset]) -> [SearchAssetGroup] {
        var grouped: [(path: String, title: String, assets: [LightboxAsset])] = []
        var indexByPath: [String: Int] = [:]
        let fallbackFolder = currentFolderURL
        let sourceContext = sources + [temporarySource].compactMap { $0 }
        if groupFolderSources != sourceContext || groupFolderScope != fallbackFolder {
            groupFolderIdentities.removeAll(keepingCapacity: true)
            groupFolderSources = sourceContext
            groupFolderScope = fallbackFolder
        }
        let sourceRoots = sourceContext.map { (source: $0, path: $0.rootURL.standardizedFileURL.path) }
        var lastParent: URL?
        var lastIdentity: (path: String, title: String)?
        for asset in activeAssets {
            let parent = asset.sourceURL?.deletingLastPathComponent() ?? fallbackFolder
            let identity: (path: String, title: String)
            if parent == lastParent, let lastIdentity {
                identity = lastIdentity
            } else if let cached = groupFolderIdentities[parent] {
                identity = cached
            } else {
                let folder = parent.standardizedFileURL
                let path = folder.path
                identity = (path, searchGroupTitle(for: folder, path: path, sourceRoots: sourceRoots))
                // Keep identity metadata through empty filters, but do not retain
                // every directory ever visited in a long-lived application.
                if groupFolderIdentities.count >= 8_192 { groupFolderIdentities.removeAll(keepingCapacity: true) }
                groupFolderIdentities[parent] = identity
            }
            lastParent = parent
            lastIdentity = identity
            if let index = indexByPath[identity.path] {
                grouped[index].assets.append(asset)
            } else {
                indexByPath[identity.path] = grouped.count
                grouped.append((identity.path, identity.title, [asset]))
            }
        }
        return grouped.map { SearchAssetGroup(id: $0.path, title: $0.title, assets: $0.assets) }
    }

    func focusSearch() {
        guard !isShowingStartPage else { return }
        galleryKeyboardFocusID = nil
        searchFocusGeneration += 1
    }

    func focusGoToFolder() {
        galleryKeyboardFocusID = nil
        goToFolderFocusGeneration += 1
    }

    nonisolated static func resolvedFolderURL(
        from rawPath: String,
        relativeTo baseURL: URL,
        directoryProbe: @escaping @Sendable (URL) -> Bool = DirectoryAccessResolver.isDirectory
    ) async -> URL? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let candidateURL: URL
        if trimmedPath.lowercased().hasPrefix("file://"),
           let fileURL = URL(string: trimmedPath),
           fileURL.isFileURL {
            candidateURL = fileURL
        } else {
            let expandedPath = (trimmedPath as NSString).expandingTildeInPath
            if (expandedPath as NSString).isAbsolutePath {
                candidateURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
            } else {
                candidateURL = baseURL.appendingPathComponent(expandedPath, isDirectory: true)
            }
        }

        let standardizedURL = candidateURL.standardizedFileURL
        guard (try? await DirectoryAccessResolver.existingDirectory(standardizedURL, probe: directoryProbe)) == true else {
            return nil
        }
        return standardizedURL
    }

    @discardableResult
    func openFolderPath(_ rawPath: String) async -> FolderPathOpenResult {
        cancelPendingFolderPath()
        let requestID = UUID()
        folderPathRequestID = requestID
        let tabID = activeTabID
        let baseURL = currentFolderURL
        let sourceID = selectedSourceID
        let probe = directoryProbe
        let task = Task<FolderPathOpenResult, Never> { @MainActor [weak self] in
            let folderURL = await Self.resolvedFolderURL(from: rawPath, relativeTo: baseURL, directoryProbe: probe)
            guard let self, !Task.isCancelled, self.folderPathRequestID == requestID,
                  self.activeTabID == tabID, self.currentFolderURL == baseURL,
                  self.selectedSourceID == sourceID else { return .cancelled }
            self.folderPathRequestID = nil
            self.folderPathTask = nil
            guard let folderURL else { return .unavailable }
            let source = self.bestSource(containing: folderURL)
                ?? LibrarySourceStore.makeExternalSource(rootURL: folderURL)
            self.sourceIndexWriter.upsertSource(source)
            self.activateSource(source, initialFolderURL: folderURL)
            return .opened
        }
        folderPathTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelPendingFolderPath() {
        folderPathRequestID = nil
        folderPathTask?.cancel()
        folderPathTask = nil
    }

    private func searchGroupTitle(
        for folderURL: URL, path: String, sourceRoots: [(source: LibrarySource, path: String)]
    ) -> String {
        if let root = sourceRoots.filter({ path == $0.path || path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) {
            return path == root.path ? root.source.displayName : String(path.dropFirst(root.path.count + 1))
        }
        return folderURL.lastPathComponent.isEmpty ? path : folderURL.lastPathComponent
    }

    var selectedSource: LibrarySource? {
        if let temporarySource, temporarySource.id == selectedSourceID {
            return temporarySource
        }

        return sources.first { $0.id == selectedSourceID }
    }

    var selectedSourceUsesConservativeExternalLoading: Bool {
        guard let source = selectedSource, !source.isLocalLibrary else { return false }
        guard sourceStorageClassification?.source == source else { return true }
        return sourceStorageClassification?.conservative ?? true
    }

    var sourceMenuSources: [LibrarySource] {
        var menuSources = sources.filter { !$0.isLocalLibrary }
        if let selectedSource,
           !selectedSource.isLocalLibrary,
           !menuSources.contains(where: { sourceMatches($0, selectedSource) }) {
            menuSources.append(selectedSource)
        }
        return menuSources
    }

    var pinnedSidebarSources: [LibrarySource] {
        sources.filter { !$0.isLocalLibrary }
    }

    private func refreshSidebarDestinations() {
        sidebarDestinationTask?.cancel()
        let visibleIDs = sidebarVisibleLocationIDs
        let loader = sidebarDestinationLoader
        let worker = Task.detached(priority: .utility) { loader(visibleIDs) }
        sidebarDestinationTask = Task { @MainActor [weak self] in
            let snapshot = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.sidebarVisibleLocationIDs == visibleIDs else { return }
            self.sidebarLocationDirectories = snapshot.locationDirectories
            self.sidebarLocations = snapshot.locations
            self.sidebarVolumes = snapshot.volumes
        }
    }

    private func startSidebarVolumeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshSidebarDestinations()
                }
            }
            sidebarVolumeObserverTokens.append(SidebarVolumeObserverToken(value: token))
        }
    }

    func isSourcePinned(_ source: LibrarySource) -> Bool {
        sources.contains {
            !$0.isLocalLibrary && sourceMatches($0, source)
        }
    }

    var currentPathTitle: String {
        if isViewingTrash {
            return localized(.trash)
        }

        return currentFolderFilterTitle
    }

    var navigationActivityText: String? {
        guard !isShowingStartPage else { return nil }
        if let status = searchStatus, status.isSearching || status.isLoadingMetadata {
            return LightboxLocalization.searchProgress(status, recursive: includesSubfolders, language: appLanguage)
        }
        if let status = libraryLoadingStatus {
            return loadingStatusText(status)
        }
        return nil
    }

    var currentFolderFilterTitle: String {
        guard let selectedSource else {
            return "Lightbox"
        }

        let relativePath = currentFolderURL.relativePath(from: selectedSource.rootURL)
        return relativePath.isEmpty ? selectedSource.displayName : currentFolderURL.lastPathComponent
    }

    var currentFolderSegmentTitle: String {
        let folderName = currentFolderURL.lastPathComponent
        if !folderName.isEmpty {
            return folderName
        }

        return selectedSource?.displayName ?? "Lightbox"
    }

    var currentPathForCopy: String {
        if isViewingTrash {
            return LightboxLibraryStore.primarySystemTrashFolder.path
        }

        return currentFolderURL.standardizedFileURL.path
    }

    var breadcrumbs: [PathBreadcrumb] {
        guard !isViewingTrash else {
            return []
        }

        var breadcrumbs: [PathBreadcrumb] = []
        var path = ""
        for (index, component) in currentFolderURL.standardizedFileURL.pathComponents.enumerated() {
            if index == 0 {
                path = component
                breadcrumbs.append(PathBreadcrumb(title: volumeTitle(), url: URL(fileURLWithPath: path, isDirectory: true)))
                continue
            }

            path = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(component, isDirectory: true)
                .path
            breadcrumbs.append(PathBreadcrumb(title: component, url: URL(fileURLWithPath: path, isDirectory: true)))
        }

        return breadcrumbs
    }

    var canOpenParentFolder: Bool {
        guard !isShowingStartPage else { return false }
        guard !isViewingTrash else { return false }
        let currentPath = currentFolderURL.standardizedFileURL.path
        let parentPath = currentFolderURL.deletingLastPathComponent().standardizedFileURL.path
        return currentPath != parentPath
    }

    var canPinCurrentPath: Bool {
        guard !isShowingStartPage else { return false }
        guard !isViewingTrash else { return false }
        let currentPath = currentFolderURL.standardizedFileURL.path
        return !sources.contains {
            $0.rootURL.standardizedFileURL.path == currentPath
        }
    }

    func openParentFolder() {
        guard canOpenParentFolder else { return }
        openFolderURL(currentFolderURL.deletingLastPathComponent())
    }

    private func volumeTitle() -> String {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let volumeName = (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
        if !volumeName.isEmpty {
            return volumeName
        }

        return "Macintosh HD"
    }

    var trashedAssets: [LightboxAsset] {
        assets.filter(\.isDeleted)
    }

    var tags: [String] {
        MacColorTag.sort(Array(Set(assets.flatMap(\.tags))))
    }

    var libraryTags: [String] {
        MacColorTag.sort(Array(Set(assets.filter { !$0.isDeleted }.flatMap(\.tags))))
    }

    var libraryColorTags: [MacColorTag] {
        cachedLibraryColorTags
    }

    var selectedAsset: LightboxAsset? {
        guard let selectedAssetID else { return activeAssets.first }
        return assetForCurrentPresentation(selectedAssetID)
    }

    var explicitlySelectedAsset: LightboxAsset? {
        guard let selectedAssetID else { return nil }
        return assetForCurrentPresentation(selectedAssetID)
    }

    var canMoveSelectionToTrash: Bool {
        if !selectedAssetIDs.isEmpty {
            return activeAssets.contains { asset in
                selectedAssetIDs.contains(asset.id) && !asset.isDeleted && asset.sourceURL != nil
            }
        }

        guard let asset = explicitlySelectedAsset else { return false }
        return !asset.isDeleted && asset.sourceURL != nil
    }

    var previewAsset: LightboxAsset? {
        guard let previewAssetID else { return nil }
        return assetForCurrentPresentation(previewAssetID)
            ?? (previewAssetSnapshot?.id == previewAssetID ? previewAssetSnapshot : nil)
    }

    var isComparing: Bool {
        comparisonAssets.count >= 2
    }

    var isPreviewPresented: Bool {
        previewPhase == .opening || previewPhase == .open || previewPhase == .closing
    }

    var isPreviewClosing: Bool {
        previewPhase == .closing
    }

    var isOverlayChromeVisible: Bool {
        // Return chrome with the gallery veil, independently of image landing.
        !isComparing && (previewAssetID == nil || isPreviewClosing)
    }

    var needsPreviewRootClickCatcher: Bool {
        isPreviewPresented && !previewInteractionLayerReady
    }

    var hasActiveOverlay: Bool {
        isPreviewPresented || isComparing
    }

    var selectedAssetCount: Int {
        selectedAssetIDs.count
    }

    var hasExplicitSelection: Bool {
        !selectedAssetIDs.isEmpty
    }

    var canStartCompareTrayComparison: Bool {
        compareTrayAssets.count >= 2
    }

    var preferredColorScheme: ColorScheme? {
        colorMode.preferredColorScheme
    }

    func localized(_ key: LightboxTextKey) -> String {
        LightboxLocalization.text(key, language: appLanguage)
    }

    func localizedColorTagName(_ tagName: String) -> String {
        LightboxLocalization.colorTagName(tagName, language: appLanguage)
    }

    func localizedColorTagFilterTitle(_ tagName: String) -> String {
        LightboxLocalization.filterColorTag(tagName, language: appLanguage)
    }

    func selectedCountText(_ count: Int) -> String {
        LightboxLocalization.selectedCount(count, language: appLanguage)
    }

    func loadingStatusText(_ status: LibraryLoadingStatus) -> String {
        switch status.phase {
        case .scanning:
            return localized(.scanningFolder)
        case .preparingPreviews:
            return LightboxLocalization.preparingPreviews(status.processed, total: status.total, language: appLanguage)
        }
    }

    func sortFieldTitle(_ field: GallerySortField) -> String {
        switch field {
        case .time:
            localized(.sortTime)
        case .size:
            localized(.sortSize)
        case .tag:
            localized(.sortTag)
        case .fileName:
            localized(.sortFileName)
        case .type:
            localized(.sortType)
        }
    }

    var sortDirectionTitle: String {
        switch sortDirection {
        case .ascending:
            localized(.sortAscending)
        case .descending:
            localized(.sortDescending)
        }
    }

    var sortDirectionIcon: String {
        switch sortDirection {
        case .ascending:
            "arrow.up"
        case .descending:
            "arrow.down"
        }
    }

    func setSortField(_ field: GallerySortField) {
        if sortField == field {
            sortDirection = sortDirection.toggled
        } else {
            sortField = field
        }
    }

    func toggleSortDirection() {
        sortDirection = sortDirection.toggled
    }

    func select(_ asset: LightboxAsset) {
        selectedAssetIDs = [asset.id]
        selectedAssetID = asset.id
        selectionAnchorID = asset.id
    }

    func isAssetHighlighted(_ asset: LightboxAsset) -> Bool {
        if selectedAssetIDs.isEmpty {
            return selectedAssetID == asset.id
        }

        return selectedAssetIDs.contains(asset.id)
    }

    func handleAssetClick(
        _ asset: LightboxAsset,
        modifiers: NSEvent.ModifierFlags,
        click: LightboxClickContext? = nil,
        sourceFrame: CGRect?
    ) {
        let extendsSelection = modifiers.contains(.command)
        let selectsRange = modifiers.contains(.shift)
        Self.previewLogger.info("asset click received phase=\(self.previewPhase.rawValue, privacy: .public) overlay=\(self.hasActiveOverlay, privacy: .public) asset=\(asset.originalName, privacy: .public) frame=\(Self.frameDescription(sourceFrame), privacy: .public) \(Self.clickDescription(click, sourceFrame: sourceFrame), privacy: .public)")
        guard !hasActiveOverlay else {
            Self.previewLogger.info("asset click ignored activeOverlay=true phase=\(self.previewPhase.rawValue, privacy: .public) asset=\(asset.originalName, privacy: .public) frame=\(Self.frameDescription(sourceFrame), privacy: .public)")
            return
        }

        if selectsRange {
            selectRange(to: asset, extending: extendsSelection)
            return
        }

        if extendsSelection {
            toggleSelection(asset)
            return
        }

        if !selectedAssetIDs.isEmpty {
            toggleSelection(asset)
            return
        }

        showPreview(for: asset, sourceFrame: sourceFrame)
    }

    func updatePreviewSpaceAssetFrames(_ frames: [LightboxAsset.ID: CGRect]) {
        storedPreviewSpaceAssetFrames = frames
    }

    func setPreviewSpaceAssetFrameProvider(_ provider: (() -> [LightboxAsset.ID: CGRect])?) {
        previewSpaceAssetFrameProvider = provider
        if provider == nil { storedPreviewSpaceAssetFrames = [:] }
    }

    func previewSpaceFrame(for assetID: LightboxAsset.ID) -> CGRect? {
        previewSpaceAssetFrames[assetID]
    }

    private func previewSpaceAssetHit(at point: CGPoint?) -> (asset: LightboxAsset, frame: CGRect)? {
        guard let point else { return nil }
        let frames = previewSpaceAssetFrames
        for asset in activeAssets {
            guard let frame = frames[asset.id],
                  frame.contains(point)
            else {
                continue
            }

            return (asset, frame)
        }

        return nil
    }

    func previewSwitchTarget(
        at point: CGPoint?,
        excluding currentAssetID: LightboxAsset.ID
    ) -> (asset: LightboxAsset, frame: CGRect)? {
        guard let hit = previewSpaceAssetHit(at: point),
              hit.asset.id != currentAssetID
        else {
            return nil
        }

        return hit
    }

    func previewSpaceHitDescription(at point: CGPoint?) -> String {
        guard let point else { return "point=nil" }
        if let hit = previewSpaceAssetHit(at: point) {
            return "hit=\(hit.asset.originalName) frame=\(Self.frameDescription(hit.frame)) point=\(LightboxClickFormatter.pointDescription(point))"
        }

        let frames = previewSpaceAssetFrames
        guard let nearest = activeAssets.compactMap({ asset -> (LightboxAsset, CGRect, CGFloat)? in
            guard let frame = frames[asset.id] else { return nil }
            return (asset, frame, Self.distance(from: point, to: frame))
        }).min(by: { $0.2 < $1.2 }) else {
            return "hit=nil frames=0 point=\(LightboxClickFormatter.pointDescription(point))"
        }

        return "hit=nil nearest=\(nearest.0.originalName) distance=\(String(format: "%.1f", nearest.2)) frame=\(Self.frameDescription(nearest.1)) point=\(LightboxClickFormatter.pointDescription(point))"
    }

    func markPreviewInteractionLayerReady(_ isReady: Bool) {
        guard previewInteractionLayerReady != isReady else { return }
        previewInteractionLayerReady = isReady
        Self.previewLogger.info("preview interaction-layer ready=\(isReady, privacy: .public) phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    func handlePreviewRootClick(_ click: LightboxClickContext) {
        handlePreviewRootClick(at: click.localTopLeftLocation)
    }

    func handlePreviewRootClick(at point: CGPoint?) {
        guard isPreviewPresented else {
            Self.previewLogger.info("preview root-click ignored phase=\(self.previewPhase.rawValue, privacy: .public)")
            return
        }

        let underlying = previewSpaceHitDescription(at: point)
        if previewPhase == .closing {
            if let currentID = previewAssetID,
               let hit = previewSwitchTarget(at: point, excluding: currentID) {
                Self.previewLogger.info("preview root-click action=switch-during-close target=\(hit.asset.originalName, privacy: .public) underlying=\(underlying, privacy: .public)")
                showPreview(for: hit.asset, sourceFrame: hit.frame)
                return
            }

            if let previewAssetID {
                Self.previewLogger.info("preview root-click action=reopen-current underlying=\(underlying, privacy: .public)")
                _ = reopenPreviewDuringClose(for: previewAssetID)
            }
            return
        }

        guard previewPhase == .opening || previewPhase == .open else {
            Self.previewLogger.info("preview root-click ignored phase=\(self.previewPhase.rawValue, privacy: .public) underlying=\(underlying, privacy: .public)")
            return
        }

        Self.previewLogger.info("preview root-click action=close phase=\(self.previewPhase.rawValue, privacy: .public) underlying=\(underlying, privacy: .public)")
        _ = beginInteractivePreviewClose(after: .milliseconds(60), revealSourceAfter: .milliseconds(0))
    }

    func markPreviewKeyboardFocusAcquired(sessionID: UUID) {
        guard sessionID == previewSessionID,
              previewPhase == .opening || previewPhase == .open else { return }
        previewKeyboardFocusSessionID = sessionID
    }

    func handlePreviewArrowDuringKeyboardHandoff(_ key: UInt16) -> Bool {
        guard previewKeyboardFocusSessionID != previewSessionID,
              previewAssetID != nil, !isComparing,
              previewPhase == .opening || previewPhase == .open else { return false }
        switch key {
        case 123: stepPreview(.previous)
        case 124: stepPreview(.next)
        default: return false
        }
        return true
    }

    func handleGalleryKey(_ key: UInt16, modifiers: NSEvent.ModifierFlags, from id: LightboxAsset.ID) {
        guard !hasActiveOverlay, let current = activeAssets.firstIndex(where: { $0.id == id }) else { return }
        if key == 53 { clearSelection(); return }
        if key == 0, modifiers.contains(.command) {
            replaceSelection(with: activeAssetIDs, primary: id, anchor: id)
            return
        }
        guard let targetIndex = GalleryKeyboardNavigation.targetIndex(
            key: key, current: current, ids: activeAssetIDList, frames: previewSpaceAssetFrames
        ) else { return }
        let target = activeAssets[targetIndex]
        if modifiers.contains(.shift) {
            if selectionAnchorID == nil { selectionAnchorID = id }
            selectRange(to: target, extending: modifiers.contains(.command))
        } else {
            replaceSelection(with: [target.id], primary: target.id, anchor: target.id)
        }
        galleryKeyboardFocusID = target.id
        galleryKeyboardScrollGeneration &+= 1
    }

    func replaceSelection(with ids: Set<LightboxAsset.ID>) {
        let primary = firstVisibleID(in: ids)
        replaceSelection(with: ids, primary: primary, anchor: primary)
    }

    func selectGalleryFolder(_ id: LibraryFolderEntry.ID) {
        clearSelection()
        galleryKeyboardFocusID = nil
        selectedGalleryFolderID = id
    }

    func clearSelection() {
        selectedGalleryFolderID = nil
        selectedAssetIDs = []
        selectedAssetID = nil
        selectionAnchorID = nil
    }

    func toggleGalleryLayoutMode() {
        galleryLayoutMode = galleryLayoutMode.next
    }

    func chooseSource(_ sourceID: LibrarySource.ID) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        activateSource(source)
    }

    func openSource(_ source: LibrarySource) {
        if let existing = sources.first(where: { sourceMatches($0, source) }) {
            chooseSource(existing.id)
            return
        }

        chooseTemporarySource(source)
    }

    func openSidebarFolder(_ url: URL) {
        cancelPendingFolderPath()
        let standardizedURL = url.standardizedFileURL

        if let source = bestSource(containing: standardizedURL) {
            let pinnedSource = sources.first { sourceMatches($0, source) }
            let sourceToActivate = pinnedSource ?? source
            Self.logger.info("sidebar folder open requested path=\(standardizedURL.path, privacy: .public) source=\(sourceToActivate.id, privacy: .public) pinned=\(pinnedSource != nil, privacy: .public)")
            activateSource(sourceToActivate, initialFolderURL: standardizedURL)
            return
        }

        let source = LibrarySourceStore.makeExternalSource(rootURL: standardizedURL)
        Self.logger.info("sidebar folder open requested path=\(standardizedURL.path, privacy: .public) source=\(source.id, privacy: .public) pinned=false")
        chooseTemporarySource(source)
    }

    func openTrashFromSidebar() {
        cancelPendingFolderPath()
        if let source = selectedSource {
            recordNavigation(to: source, folderURL: currentFolderURL, filter: .trash)
        }
        if let index = activeTabIndex { tabs[index].isStartPage = false }
        preservesUnavailableCurrentFolder = false
        resetScrollForNavigation()
        selectedFilter = .trash
        searchText = ""
        clearSelection()
    }

    private func chooseTemporarySource(_ source: LibrarySource) {
        sourceIndexWriter.upsertSource(source)
        activateSource(source)
    }

    private func activateSource(_ source: LibrarySource, initialFolderURL: URL? = nil) {
        cancelPendingFolderPath()
        cancelPreviewDimensionResolution(clearPendingStep: true)
        let destinationFolderURL = initialFolderURL?.standardizedFileURL ?? source.rootURL
        recordNavigation(to: source, folderURL: destinationFolderURL, filter: .all)
        isApplyingTabState = true
        clearContentForFolderNavigation()
        if let index = activeTabIndex { tabs[index].isStartPage = false }
        temporarySource = sources.contains(where: { sourceMatches($0, source) }) ? nil : source
        let previousSourceID = selectedSourceID
        selectedSourceID = source.id
        LibrarySourceStore.saveSelectedSourceID(source.id, defaults: libraryDefaults)
        selectedFilter = .all
        currentFolderURL = destinationFolderURL
        restoreFolderSort()
        preservesUnavailableCurrentFolder = false
        resetScrollForNavigation()
        isApplyingTabState = false
        rebuildLibraryColorTags()
        rebuildActiveAssets()
        rebuildActiveFolderEntries()
        saveCurrentFolderSession()
        if previousSourceID != source.id {
            SidebarFolderTagCache.shared.clear()
        }
        ImageCache.shared.removeSourceMemoryObjects(reason: "choose-source")
        restartLibraryMonitor()
        refreshLibrary()
    }

    func addExternalSource() {
        let panel = NSOpenPanel()
        let title = localized(isShowingStartPage ? .startOpenFolder : .openFolder)
        panel.title = title
        panel.prompt = title.replacingOccurrences(of: "...", with: "")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        let standardizedURL = url.standardizedFileURL
        if let existing = sources.first(where: { $0.rootURL.standardizedFileURL.path == standardizedURL.path }) {
            chooseSource(existing.id)
            return
        }

        chooseTemporarySource(LibrarySourceStore.makeExternalSource(rootURL: standardizedURL))
    }

    func pinCurrentPath() {
        guard canPinCurrentPath else { return }
        pinFolder(currentFolderURL, selectPinnedFolder: false)
    }

    func unpinSource(_ sourceID: LibrarySource.ID) {
        guard let source = sources.first(where: { $0.id == sourceID }),
              !source.isLocalLibrary
        else {
            return
        }
        pendingPinTasks.removeValue(forKey: source.rootURL.standardizedFileURL.path)?.task.cancel()

        let wasSelected = selectedSourceID == sourceID
        sources.removeAll { $0.id == sourceID }
        LibrarySourceStore.saveExternalSources(sources, defaults: libraryDefaults)
        if wasSelected {
            temporarySource = source
            LibrarySourceStore.saveSelectedSourceID(source.id, defaults: libraryDefaults)
        }
    }

    func pinSource(_ source: LibrarySource, selectPinnedFolder: Bool) {
        guard !source.isLocalLibrary else { return }
        if let existing = sources.first(where: {
            $0.id == source.id || $0.rootURL.standardizedFileURL.path == source.rootURL.standardizedFileURL.path
        }) {
            if selectPinnedFolder {
                chooseSource(existing.id)
            }
            return
        }

        sources.append(source)
        LibrarySourceStore.saveExternalSources(sources, defaults: libraryDefaults)
        sourceIndexWriter.upsertSource(source)
        if temporarySource?.rootURL.standardizedFileURL.path == source.rootURL.standardizedFileURL.path {
            temporarySource = nil
        }
        if selectedSourceID == source.id {
            LibrarySourceStore.saveSelectedSourceID(source.id, defaults: libraryDefaults)
        }
        if selectPinnedFolder {
            chooseSource(source.id)
        }
    }

    private func pinFolder(_ url: URL, selectPinnedFolder: Bool) {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        guard pendingPinTasks[path] == nil else { return }
        let probe = directoryProbe
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.pendingPinTasks[path]?.id == requestID { self?.pendingPinTasks[path] = nil }
            }
            guard (try? await DirectoryAccessResolver.existingDirectory(standardizedURL, probe: probe)) == true,
                  !Task.isCancelled, let self else { return }
            self.pinSource(LibrarySourceStore.makeExternalSource(rootURL: standardizedURL),
                           selectPinnedFolder: selectPinnedFolder)
        }
        pendingPinTasks[path] = (requestID, task)
    }

    private func sourceMatches(_ lhs: LibrarySource, _ rhs: LibrarySource) -> Bool {
        lhs.id == rhs.id || lhs.rootURL.standardizedFileURL.path == rhs.rootURL.standardizedFileURL.path
    }

    private func bestSource(containing folderURL: URL) -> LibrarySource? {
        let folderPath = folderURL.standardizedFileURL.path
        let allSources = sources + [temporarySource].compactMap { $0 }
        let candidates = allSources.filter { source in
            let rootPath = source.rootURL.standardizedFileURL.path
            return folderPath == rootPath || folderPath.hasPrefix(rootPath + "/")
        }

        return candidates.max {
            $0.rootURL.standardizedFileURL.path.count < $1.rootURL.standardizedFileURL.path.count
        }
    }

    private func saveCurrentFolderSession() {
        guard !isShowingStartPage else { captureActiveTabState(); return }
        if !isViewingTrash {
            let url = currentFolderURL.standardizedFileURL
            recentFolderURLs.removeAll { $0.standardizedFileURL == url }
            recentFolderURLs.insert(url, at: 0)
            recentFolderURLs = Array(recentFolderURLs.prefix(12))
            libraryDefaults.set(recentFolderURLs.map(\.path), forKey: "Lightbox.recentFolders")
        }
        if !isViewingTrash, let selectedSource {
            LibrarySourceStore.saveLastSession(
                source: selectedSource,
                folderURL: currentFolderURL,
                defaults: libraryDefaults
            )
        }
        captureActiveTabState()
    }

    func openFolder(_ folder: LibraryFolderEntry) {
        cancelPendingFolderPath()
        Self.logger.info("folder open requested source=\(folder.sourceID, privacy: .public) selectedSource=\(self.selectedSourceID, privacy: .public) path=\(folder.url.path, privacy: .public)")
        let standardizedURL = folder.url.standardizedFileURL
        guard folder.sourceID == selectedSourceID else {
            guard let source = sources.first(where: { $0.id == folder.sourceID }) else {
                Self.logger.error("folder open rejected source mismatch folderSource=\(folder.sourceID, privacy: .public) selectedSource=\(self.selectedSourceID, privacy: .public) path=\(folder.url.path, privacy: .public)")
                return
            }
            recordNavigation(to: source, folderURL: standardizedURL, filter: .all)
            isApplyingTabState = true
            clearContentForFolderNavigation()
            temporarySource = nil
            cancelPreviewDimensionResolution(clearPendingStep: true)
            selectedSourceID = source.id
            LibrarySourceStore.saveSelectedSourceID(source.id, defaults: libraryDefaults)
            selectedFilter = .all
            currentFolderURL = standardizedURL
            restoreFolderSort()
            preservesUnavailableCurrentFolder = false
            resetScrollForNavigation()
            isApplyingTabState = false
            rebuildLibraryColorTags()
            rebuildActiveAssets()
            rebuildActiveFolderEntries()
            saveCurrentFolderSession()
            ImageCache.shared.removeThumbnailMemoryObjects(reason: "open-folder")
            restartLibraryMonitor()
            refreshLibrary()
            return
        }
        openFolderURL(standardizedURL)
    }

    func openBreadcrumb(_ breadcrumb: PathBreadcrumb) {
        openFolderURL(breadcrumb.url)
    }

    private func openFolderURL(_ url: URL) {
        cancelPendingFolderPath()
        let standardizedURL = url.standardizedFileURL
        cancelPreviewDimensionResolution(clearPendingStep: true)
        if let source = selectedSource {
            recordNavigation(to: source, folderURL: standardizedURL, filter: .all)
        }
        // Commit a navigation snapshot before rebuilding derived presentation.
        // Otherwise the new location/sort rebuilds the previous directory's
        // cards, and its new scroll identity mounts them a second time.
        isApplyingTabState = true
        clearContentForFolderNavigation()
        selectedFilter = .all
        currentFolderURL = standardizedURL
        restoreFolderSort()
        preservesUnavailableCurrentFolder = false
        resetScrollForNavigation()
        isApplyingTabState = false
        rebuildLibraryColorTags()
        rebuildActiveAssets()
        rebuildActiveFolderEntries()
        saveCurrentFolderSession()
        ImageCache.shared.removeThumbnailMemoryObjects(reason: "open-folder")
        restartLibraryMonitor()
        refreshLibrary()
    }

    /// Called inside the existing state-application guard. Old asynchronous
    /// results lose their generation before any destination fields change.
    private func clearContentForFolderNavigation() {
        searchTask?.cancel()
        searchGeneration &+= 1
        recursiveSearchScope = nil
        searchText = ""
        searchStatus = nil
        searchResultAssets = nil
        searchResultFolderEntries = nil
        assets = []
        folderEntries = []
        clearSelection()
        galleryKeyboardFocusID = nil
    }

    private func clearSearchForNavigation() {
        galleryKeyboardFocusID = nil
        searchTask?.cancel()
        searchGeneration &+= 1
        searchStatus = nil
        if hasSearchQuery {
            searchText = ""
        } else {
            clearSearchResults()
            rebuildActiveAssets()
        }
    }

    func copyCurrentPathToClipboard() {
        let path = currentPathForCopy
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        Self.logger.info("path copied path=\(path, privacy: .public)")
    }

    func showPreview(for asset: LightboxAsset? = nil, sourceFrame: CGRect? = nil) {
        selectedGalleryFolderID = nil
        guard let target = asset ?? selectedAsset ?? activeAssets.first else {
            Self.previewLogger.info("preview show ignored reason=no-target phase=\(self.previewPhase.rawValue, privacy: .public)")
            return
        }

        pendingPreviewStepAssetID = nil
        resolvePreviewTarget(
            target,
            sourceFrame: sourceFrame,
            requiresActiveAsset: false
        ) { [weak self] resolvedTarget in
            self?.presentPreview(resolvedTarget, sourceFrame: sourceFrame)
        }
    }

    private func presentPreview(_ target: LightboxAsset, sourceFrame: CGRect?) {
        pendingPreviewStepAssetID = nil
        let previousPhase = previewPhase
        let nextSessionID = UUID()
        closeComparison()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        previewInteractionLayerReady = false
        previewPhase = .opening
        previewSessionID = nextSessionID
        previewStepDirection = nil
        selectedAssetIDs = []
        selectionAnchorID = nil
        selectedAssetID = target.id
        previewSourceHiddenAssetID = nil
        previewSourceFrame = sourceFrame
        previewAssetID = target.id
        previewAssetSnapshot = target
        Self.previewLogger.info("preview show phase=\(previousPhase.rawValue, privacy: .public)->opening session=\(nextSessionID.uuidString, privacy: .public) asset=\(target.originalName, privacy: .public) frame=\(Self.frameDescription(sourceFrame), privacy: .public) folder=\(self.currentFolderURL.lastPathComponent, privacy: .public)")
        schedulePreviewOpenCompletion()
    }

    private func resolvePreviewTarget(
        _ asset: LightboxAsset,
        sourceFrame: CGRect?,
        requiresActiveAsset: Bool,
        completion: @escaping @MainActor @Sendable (LightboxAsset) -> Void
    ) {
        cancelPreviewDimensionResolution()
        guard needsPreviewDimensionResolve(asset),
              let url = asset.sourceURL
        else {
            completion(asset)
            return
        }

        let dimensionProbe = previewDimensionProbe
        let indexDatabaseURL = indexDatabaseURL
        let requestID = UUID()
        let requestSourceID = selectedSourceID
        let requestFolderPath = currentFolderURL.standardizedFileURL.path
        let requestSessionID = previewSessionID
        let requestAssetID = asset.id
        previewDimensionRequestID = requestID
        previewDimensionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let dimensions = autoreleasepool {
                dimensionProbe(url)
            }
            guard !Task.isCancelled else { return }

            let didResolve = await MainActor.run { () -> Bool in
                guard let self,
                      self.previewDimensionRequestID == requestID
                else {
                    return false
                }
                self.previewDimensionTask = nil
                self.previewDimensionRequestID = nil
                guard !Task.isCancelled,
                      self.selectedSourceID == requestSourceID,
                      self.currentFolderURL.standardizedFileURL.path == requestFolderPath,
                      self.previewSessionID == requestSessionID,
                      !requiresActiveAsset || self.activeAssets.contains(where: { $0.id == requestAssetID })
                else {
                    Self.previewLogger.info("preview dimensions ignored stale-context assetID=\(requestAssetID, privacy: .public)")
                    return false
                }
                let resolved = self.resolvedPreviewTarget(
                    asset,
                    sourceFrame: sourceFrame,
                    dimensions: dimensions
                )
                completion(resolved)
                return true
            }

            guard didResolve,
                  !Task.isCancelled,
                  let dimensions,
                  dimensions.width > 1,
                  dimensions.height > 1
            else {
                return
            }
            LightboxIndexStore(databaseURL: indexDatabaseURL).updateCachedDimensions(
                sourceID: requestSourceID,
                updates: [IndexedAssetDimensions(
                    url: url,
                    width: dimensions.width,
                    height: dimensions.height
                )]
            )
        }
    }

    private func cancelPreviewDimensionResolution(clearPendingStep: Bool = false) {
        previewDimensionTask?.cancel()
        previewDimensionTask = nil
        previewDimensionRequestID = nil
        if clearPendingStep {
            pendingPreviewStepAssetID = nil
        }
    }

    private func resolvedPreviewTarget(
        _ asset: LightboxAsset,
        sourceFrame: CGRect?,
        dimensions: CGSize?
    ) -> LightboxAsset {
        if let dimensions,
           dimensions.width > 1,
           dimensions.height > 1 {
            var resolved = asset
            resolved.width = dimensions.width
            resolved.height = dimensions.height
            resolved.metadataLoaded = true

            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                var nextAssets = assets
                nextAssets[index].width = dimensions.width
                nextAssets[index].height = dimensions.height
                nextAssets[index].metadataLoaded = true
                assets = nextAssets
            }
            updatePresentedAssetDimensions(
                asset.id,
                width: dimensions.width,
                height: dimensions.height,
                metadataLoaded: true
            )

            Self.previewLogger.info("preview dimensions resolved asset=\(asset.originalName, privacy: .public) width=\(dimensions.width, format: .fixed(precision: 0)) height=\(dimensions.height, format: .fixed(precision: 0))")
            return resolved
        }

        guard let sourceFrame,
              sourceFrame.width > 1,
              sourceFrame.height > 1
        else {
            return asset
        }

        var fallback = asset
        fallback.width = sourceFrame.width
        fallback.height = sourceFrame.height
        fallback.metadataLoaded = false

        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            var nextAssets = assets
            nextAssets[index].width = sourceFrame.width
            nextAssets[index].height = sourceFrame.height
            nextAssets[index].metadataLoaded = false
            assets = nextAssets
        }
        updatePresentedAssetDimensions(
            asset.id,
            width: sourceFrame.width,
            height: sourceFrame.height,
            metadataLoaded: false
        )

        Self.previewLogger.info("preview dimensions fallback-to-card asset=\(asset.originalName, privacy: .public) width=\(sourceFrame.width, format: .fixed(precision: 0)) height=\(sourceFrame.height, format: .fixed(precision: 0))")
        return fallback
    }

    private func needsPreviewDimensionResolve(_ asset: LightboxAsset) -> Bool {
        !asset.metadataLoaded || asset.width <= 1 || asset.height <= 1
    }

    func hidePreviewSourceForCurrentPreview(_ assetID: LightboxAsset.ID) {
        guard previewAssetID == assetID,
              previewPhase == .opening || previewPhase == .open
        else {
            Self.previewLogger.info("preview source hide ignored phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return
        }

        previewSourceHiddenAssetID = assetID
        Self.previewLogger.info("preview source hide session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    private func markPreviewOpen() {
        guard previewPhase == .opening else {
            Self.previewLogger.info("preview open ignored phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return
        }
        Self.previewLogger.info("preview open phase=opening->open session=\(self.previewSessionID.uuidString, privacy: .public)")
        previewPhase = .open
    }

    func beginPreviewClose(
        after delay: Duration = MotionTokens.previewGeometryDuration,
        revealSourceAfter sourceRevealDelay: Duration = MotionTokens.previewSourceRevealDelay
    ) -> Bool {
        let previousPhase = previewPhase
        guard previewPhase == .opening || previewPhase == .open else {
            Self.previewLogger.info("preview close rejected phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return false
        }
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewPhase = .closing
        previewStepDirection = nil
        Self.previewLogger.info("preview close begin phase=\(previousPhase.rawValue, privacy: .public)->closing session=\(self.previewSessionID.uuidString, privacy: .public) delay=\(Self.durationDescription(delay), privacy: .public) revealDelay=\(Self.durationDescription(sourceRevealDelay), privacy: .public) sourceHidden=\(self.previewSourceHiddenAssetID != nil, privacy: .public)")
        previewSourceRevealTask = Task { [weak self] in
            try? await Task.sleep(for: sourceRevealDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                Self.previewLogger.info("preview source reveal session=\(self?.previewSessionID.uuidString ?? "nil", privacy: .public)")
                self?.previewSourceHiddenAssetID = nil
            }
        }
        previewCloseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishPreviewClose()
            }
        }
        return true
    }

    func beginInteractivePreviewClose(
        after delay: Duration = MotionTokens.previewGeometryDuration,
        revealSourceAfter sourceRevealDelay: Duration = MotionTokens.previewSourceRevealDelay
    ) -> Bool {
        guard previewPhase == .opening || previewPhase == .open else { return false }
        return beginPreviewClose(after: delay, revealSourceAfter: sourceRevealDelay)
    }

    func reopenPreviewDuringClose(for assetID: LightboxAsset.ID) -> Bool {
        guard previewPhase == .closing,
              previewAssetID == assetID
        else {
            Self.previewLogger.info("preview reopen rejected phase=\(self.previewPhase.rawValue, privacy: .public) assetID=\(assetID, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return false
        }

        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        previewPhase = .opening
        previewStepDirection = nil
        previewSourceHiddenAssetID = assetID
        selectedAssetID = assetID
        Self.previewLogger.info("preview reopen phase=closing->opening session=\(self.previewSessionID.uuidString, privacy: .public) assetID=\(assetID, privacy: .public)")
        schedulePreviewOpenCompletion()
        return true
    }

    func closePreview() {
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        finishPreviewClose(force: true)
    }

    func showComparisonFromSelection() {
        let selected = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        guard selected.count >= 2 else { return }
        Self.comparisonLogger.info("comparison open selected=\(selected.count) source=\(self.selectedSourceID, privacy: .public)")
        ImageCache.shared.cancelOutstandingRequests(reason: "open-comparison")
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewAssetID = nil
        previewAssetSnapshot = nil
        previewSourceHiddenAssetID = nil
        previewInteractionLayerReady = false
        previewSourceFrame = nil
        previewPhase = .closed
        previewSessionID = UUID()
        previewStepDirection = nil
        comparisonAssets = selected
        selectedAssetIDs = []
        selectionAnchorID = nil
        selectedAssetID = selected.first?.id
    }

    func addToCompareTray(_ asset: LightboxAsset) {
        guard !asset.isDeleted else { return }
        guard !compareTrayAssets.contains(where: { $0.id == asset.id }) else {
            pulseCompareTrayItem(asset.id)
            return
        }
        guard compareTrayAssets.count < compareTrayLimit else {
            compareTrayRejectGeneration += 1
            return
        }

        compareTrayAssets.append(asset)
        pulseCompareTrayItem(asset.id)
    }

    func addSelectedToCompareTray(fallback asset: LightboxAsset) {
        let selected = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        let targets = selected.count > 1 && selected.contains(where: { $0.id == asset.id }) ? selected : [asset]
        for target in targets {
            addToCompareTray(target)
        }
    }

    func addCompareTrayItem(for url: URL) async {
        let standardizedPath = url.standardizedFileURL.path
        if let existing = assets.first(where: { $0.sourceURL?.standardizedFileURL.path == standardizedPath }) {
            addToCompareTray(existing)
            return
        }

        let fallbackSize = MockLibrary.importFallbackSizes[compareTrayAssets.count % MockLibrary.importFallbackSizes.count]
        let palette = MockPalette.imported[compareTrayAssets.count % MockPalette.imported.count]
        let assetLoader = compareTrayAssetLoader
        let asset = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                assetLoader(url, fallbackSize, palette)
            }
        }.value
        addToCompareTray(asset)
    }

    func handleCompareTrayDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { @MainActor [weak self] in
            for provider in providers {
                guard let url = await Self.fileURL(from: provider) else { continue }
                await self?.addCompareTrayItem(for: url)
            }
            self?.compareTrayDragID = nil
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: url(from: item))
            }
        }
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }

            if let string = String(data: data, encoding: .utf8) {
                return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    func removeFromCompareTray(_ assetID: LightboxAsset.ID) {
        compareTrayAssets.removeAll { $0.id == assetID }
        if comparisonAssets.contains(where: { $0.id == assetID }) {
            comparisonAssets.removeAll { $0.id == assetID }
            if comparisonAssets.count < 2 {
                closeComparison()
            }
        }
    }

    func clearCompareTray() {
        compareTrayAssets = []
        closeComparison()
    }

    func startCompareTrayComparison() {
        guard compareTrayAssets.count >= 2 else {
            compareTrayRejectGeneration += 1
            return
        }

        Self.comparisonLogger.info("comparison open tray count=\(self.compareTrayAssets.count)")
        ImageCache.shared.cancelOutstandingRequests(reason: "open-compare-tray")
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewAssetID = nil
        previewAssetSnapshot = nil
        previewSourceHiddenAssetID = nil
        previewInteractionLayerReady = false
        previewSourceFrame = nil
        previewPhase = .closed
        previewSessionID = UUID()
        previewStepDirection = nil
        comparisonAssets = compareTrayAssets
        selectedAssetIDs = []
        selectionAnchorID = nil
        selectedAssetID = compareTrayAssets.first?.id
    }

    func compareTrayLabel(for assetID: LightboxAsset.ID) -> String? {
        guard let index = compareTrayAssets.firstIndex(where: { $0.id == assetID }) else {
            return nil
        }
        return comparisonLabel(for: index)
    }

    func beginCompareTrayDrag(_ assetID: LightboxAsset.ID) {
        compareTrayDragID = assetID
    }

    func moveCompareTrayDraggedItem(before targetID: LightboxAsset.ID) {
        guard let draggedID = compareTrayDragID,
              draggedID != targetID,
              let fromIndex = compareTrayAssets.firstIndex(where: { $0.id == draggedID }),
              let toIndex = compareTrayAssets.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        let item = compareTrayAssets.remove(at: fromIndex)
        let adjustedIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        compareTrayAssets.insert(item, at: adjustedIndex)
    }

    func endCompareTrayDrag() {
        compareTrayDragID = nil
    }

    private func pulseCompareTrayItem(_ assetID: LightboxAsset.ID) {
        compareTrayPulseTask?.cancel()
        compareTrayPulseID = assetID
        compareTrayPulseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            if self?.compareTrayPulseID == assetID {
                self?.compareTrayPulseID = nil
            }
        }
    }

    private func comparisonLabel(for index: Int) -> String {
        "\(index + 1)"
    }

    func closeComparison() {
        guard !comparisonAssets.isEmpty else { return }
        Self.comparisonLogger.info("comparison close count=\(self.comparisonAssets.count)")
        comparisonAssets = []
    }

    func closeActiveOverlay() {
        if isComparing {
            closeComparison()
            return
        }

        _ = beginPreviewClose()
    }

    private func finishPreviewClose(force: Bool = false) {
        let previousPhase = previewPhase
        guard force || previewPhase == .closing else {
            Self.previewLogger.info("preview finish ignored force=\(force, privacy: .public) phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return
        }
        let returnID = previewAssetID.flatMap { id in activeAssets.contains(where: { $0.id == id }) ? id : nil }
        previewSourceRevealTask?.cancel()
        pendingPreviewStepAssetID = nil
        previewAssetID = nil
        previewAssetSnapshot = nil
        previewSourceHiddenAssetID = nil
        previewInteractionLayerReady = false
        selectedAssetID = nil
        selectedAssetIDs = []
        selectionAnchorID = nil
        previewSourceFrame = nil
        previewPhase = .closed
        previewStepDirection = nil
        if previousPhase != .closed {
            // Returning from preview restores the responder without moving the
            // viewport. Explicit gallery arrow navigation requests its own scroll.
            galleryKeyboardFocusID = returnID ?? activeAssets.first?.id
        }
        Self.previewLogger.info("preview close finish force=\(force, privacy: .public) phase=\(previousPhase.rawValue, privacy: .public)->closed session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    func togglePreview() {
        switch previewPhase {
        case .closed:
            showPreview()
        case .opening, .open:
            _ = beginPreviewClose()
        case .closing:
            if let previewAssetID {
                _ = reopenPreviewDuringClose(for: previewAssetID)
            }
        }
    }

    private func schedulePreviewOpenCompletion() {
        previewOpenTask?.cancel()
        previewOpenTask = Task { [weak self] in
            try? await Task.sleep(for: MotionTokens.previewGeometryDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.markPreviewOpen()
            }
        }
    }

    func stepPreview(_ direction: PreviewDirection) {
        let visible = activeAssets
        guard visible.count > 1,
              previewPhase == .opening || previewPhase == .open
        else { return }
        let currentID = pendingPreviewStepAssetID ?? previewAssetID ?? selectedAssetID
        let currentIndex = currentID.flatMap { id in visible.firstIndex { $0.id == id } } ?? 0
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = (currentIndex - 1 + visible.count) % visible.count
        case .next:
            nextIndex = (currentIndex + 1) % visible.count
        }
        let nextAsset = visible[nextIndex]
        pendingPreviewStepAssetID = nextAsset.id
        resolvePreviewTarget(
            nextAsset,
            sourceFrame: nil,
            requiresActiveAsset: true
        ) { [weak self] nextAsset in
            self?.presentPreviewStep(nextAsset, direction: direction)
        }
    }

    private func presentPreviewStep(_ nextAsset: LightboxAsset, direction: PreviewDirection) {
        guard pendingPreviewStepAssetID == nextAsset.id else { return }
        pendingPreviewStepAssetID = nil
        guard previewPhase == .opening || previewPhase == .open,
              activeAssets.contains(where: { $0.id == nextAsset.id })
        else {
            return
        }
        previewOpenTask?.cancel()
        previewSourceRevealTask?.cancel()
        if previewPhase == .opening {
            previewPhase = .open
        }
        selectedAssetID = nextAsset.id
        previewSourceHiddenAssetID = nil
        previewSourceFrame = nil
        previewStepDirection = direction
        previewAssetID = nextAsset.id
        previewAssetSnapshot = nextAsset
        Self.previewLogger.info("preview step direction=\(direction.rawValue, privacy: .public) asset=\(nextAsset.originalName, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    func markDeleted(_ asset: LightboxAsset) {
        let targetAssets: [LightboxAsset]
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            let selectedIDs = selectedAssetIDs
            targetAssets = activeAssets.filter { selectedIDs.contains($0.id) }
        } else {
            targetAssets = [asset]
        }

        moveAssetsToSystemTrash(targetAssets)
    }

    func deleteSelectedAssets() {
        let targetAssets: [LightboxAsset]
        if !selectedAssetIDs.isEmpty {
            let selectedIDs = selectedAssetIDs
            targetAssets = activeAssets.filter { selectedIDs.contains($0.id) }
        } else if let asset = explicitlySelectedAsset {
            targetAssets = [asset]
        } else {
            return
        }

        moveAssetsToSystemTrash(targetAssets)
    }

    private func moveAssetsToSystemTrash(_ targetAssets: [LightboxAsset]) {
        let validAssets = targetAssets.filter { !$0.isDeleted && $0.sourceURL != nil && !trashMovingAssetIDs.contains($0.id) }
        guard !validAssets.isEmpty else { return }

        if trashMoveTask != nil {
            let queuedIDs = Set(queuedTrashAssets.map(\.id))
            queuedTrashAssets.append(contentsOf: validAssets.filter { !queuedIDs.contains($0.id) })
            Self.logger.info("system trash queued assets=\(self.queuedTrashAssets.count)")
            return
        }

        let targets = validAssets.compactMap { asset -> (id: LightboxAsset.ID, url: URL)? in
            guard let sourceURL = asset.sourceURL else { return nil }
            return (asset.id, sourceURL)
        }

        trashMovingAssetIDs = Set(targets.map(\.id))
        let previewOrder = activeAssets.map(\.id)
        let previewSession = previewSessionID
        let trashMover = systemTrashMover
        trashMoveTask = Task.detached(priority: .userInitiated) { [weak self] in
            var removedIDs = Set<LightboxAsset.ID>()
            for target in targets {
                guard !Task.isCancelled else { break }
                if trashMover(target.url) {
                    removedIDs.insert(target.id)
                } else {
                    Self.logger.error("system trash failed id=\(target.id, privacy: .public) path=\(target.url.path, privacy: .public)")
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.applySystemTrashSuccesses(removedIDs, previewOrder: previewOrder, previewSession: previewSession)
                self.trashMovingAssetIDs = []
                self.trashMoveTask = nil
                self.queuedTrashAssets.removeAll { removedIDs.contains($0.id) }
                let queuedAssets = self.queuedTrashAssets
                self.queuedTrashAssets = []
                if !queuedAssets.isEmpty {
                    self.moveAssetsToSystemTrash(queuedAssets)
                }
            }
        }
    }

    private func applySystemTrashSuccesses(_ removedIDs: Set<LightboxAsset.ID>, previewOrder: [LightboxAsset.ID], previewSession: UUID) {
        guard !removedIDs.isEmpty else { return }

        var continuation: (asset: LightboxAsset, direction: PreviewDirection)?
        if let currentID = previewAssetID, removedIDs.contains(currentID),
           previewPhase == .opening || previewPhase == .open {
            let order = previewSessionID == previewSession ? previewOrder : activeAssets.map(\.id)
            let remainingIDs = Set(activeAssets.map(\.id)).subtracting(removedIDs)
            if let index = order.firstIndex(of: currentID) {
                let following = order.dropFirst(index + 1).first { remainingIDs.contains($0) }
                let preceding = order.prefix(index).last { remainingIDs.contains($0) }
                let pending = pendingPreviewStepAssetID.flatMap { remainingIDs.contains($0) ? $0 : nil }
                if let nextID = pending ?? following ?? preceding,
                   let next = activeAssets.first(where: { $0.id == nextID }) {
                    let direction: PreviewDirection = (order.firstIndex(of: nextID) ?? index) < index ? .previous : .next
                    continuation = (next, direction)
                    cancelPreviewDimensionResolution(clearPendingStep: true)
                    pendingPreviewStepAssetID = next.id
                    // Keep the overlay in its current session before gallery observers run.
                    presentPreviewStep(next, direction: direction)
                }
            }
        }

        // Update both sources before the assets observer rebuilds the gallery and its ID caches.
        searchResultAssets?.removeAll { removedIDs.contains($0.id) }
        assets.removeAll { removedIDs.contains($0.id) }
        selectedAssetIDs.subtract(removedIDs)
        if let selectedAssetID, removedIDs.contains(selectedAssetID) {
            self.selectedAssetID = firstVisibleID(in: selectedAssetIDs)
        }
        if let selectionAnchorID, removedIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }
        if selectedAssetIDs.isEmpty {
            selectionAnchorID = nil
        }
        if let previewAssetID, removedIDs.contains(previewAssetID) {
            closePreview()
        }
        for assetID in removedIDs {
            removeFromCompareTray(assetID)
        }
        rebuildActiveAssets()
        if let continuation, previewAssetID == continuation.asset.id {
            pendingPreviewStepAssetID = continuation.asset.id
            resolvePreviewTarget(continuation.asset, sourceFrame: nil, requiresActiveAsset: true) { [weak self] resolved in
                self?.presentPreviewStep(resolved, direction: continuation.direction)
            }
        }
    }

    func restore(_ asset: LightboxAsset) {
        guard let sourceURL = asset.sourceURL,
              LightboxLibraryStore.isSystemTrashURL(sourceURL)
        else {
            return
        }

        let assetID = asset.id
        Task { [weak self] in
            let restored = await LightboxLibraryStore.restoreFromSystemTrash(sourceURL)
            guard let self else { return }

            guard restored else {
                Self.logger.error("system trash restore failed id=\(assetID, privacy: .public) path=\(sourceURL.path, privacy: .public)")
                return
            }

            finishRestore(assetID)
        }
    }

    private func finishRestore(_ assetID: LightboxAsset.ID) {
        assets.removeAll { $0.id == assetID }
        selectedAssetIDs.remove(assetID)
        if selectedAssetID == assetID {
            selectedAssetID = firstVisibleID(in: selectedAssetIDs)
        }
        if selectionAnchorID == assetID {
            selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }
        removeFromCompareTray(assetID)
        scheduleLibraryRefresh()
    }

    func applyTag(_ tag: String, to asset: LightboxAsset) {
        guard MacColorTag.isColorTag(tag) else { return }
        enqueueTagMutation(TagMutationRequest(tag: tag, assets: [asset], action: .add))
    }

    func toggleTag(_ tag: String, to asset: LightboxAsset) {
        guard MacColorTag.isColorTag(tag) else { return }
        let targetIDs: Set<LightboxAsset.ID>
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            targetIDs = selectedAssetIDs
        } else {
            targetIDs = [asset.id]
        }
        let targetAssets = activeAssets.filter { targetIDs.contains($0.id) }
        guard !targetAssets.isEmpty else { return }
        enqueueTagMutation(TagMutationRequest(tag: tag, assets: targetAssets, action: .toggle))
    }

    func selectedAssetTagCoverage(for tag: String) -> Double {
        guard MacColorTag.isColorTag(tag), !selectedAssetIDs.isEmpty else { return 0 }
        let selectedAssets = activeAssets.filter { selectedAssetIDs.contains($0.id) }
        guard !selectedAssets.isEmpty else { return 0 }
        let taggedCount = selectedAssets.filter { $0.tags.contains(tag) }.count
        return Double(taggedCount) / Double(selectedAssets.count)
    }

    func toggleTagForSelection(_ tag: String) {
        guard MacColorTag.isColorTag(tag), !selectedAssetIDs.isEmpty else { return }
        let targetIDs = selectedAssetIDs
        let selectedAssets = activeAssets.filter { targetIDs.contains($0.id) }
        guard !selectedAssets.isEmpty else { return }

        enqueueTagMutation(TagMutationRequest(tag: tag, assets: selectedAssets, action: .toggle))
    }

    private func enqueueTagMutation(_ request: TagMutationRequest) {
        var request = request
        request.originTabID = activeTabID
        request.originFilter = selectedFilter
        request.originVisibleAssetIDs = Set(activeAssets.map(\.id))
        request.originFolderPath = currentFolderURL.standardizedFileURL.path
        request.originSearchText = searchText
        queuedTagMutations.append(request)
        guard tagMutationTask == nil else { return }

        tagMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.queuedTagMutations.isEmpty {
                let request = self.queuedTagMutations.removeFirst()
                let targetAssets = request.assets.map { asset in
                    self.assetForCurrentPresentation(asset.id) ?? asset
                }
                let targetIDs = Set(targetAssets.map(\.id))
                let writer = self.finderTagWriter
                let mutation = await Task.detached(priority: .userInitiated) {
                    () -> (removesTag: Bool, tagsByID: [LightboxAsset.ID: [String]]) in
                    // Gallery tags may be deferred or stale. Read all targets before
                    // deciding a group toggle; abort if any target cannot be read.
                    let writes: [TagMutationWrite]
                    do {
                        writes = try targetAssets.map { asset in
                            TagMutationWrite(
                                id: asset.id,
                                url: asset.sourceURL,
                                tags: try asset.sourceURL.map { try FinderTagStore.readColorTags(for: $0) }
                                    ?? asset.tags
                            )
                        }
                    } catch {
                        return (false, [:])
                    }
                    let removesTag = request.action == .toggle
                        && writes.allSatisfy { $0.tags.contains(request.tag) }
                    var result: [LightboxAsset.ID: [String]] = [:]
                    for write in writes {
                        guard !Task.isCancelled else { break }
                        var nextTags = write.tags
                        if removesTag {
                            nextTags.removeAll { $0 == request.tag }
                        } else if !nextTags.contains(request.tag) {
                            nextTags.append(request.tag)
                        }
                        nextTags = MacColorTag.sort(nextTags.filter(MacColorTag.isColorTag))
                        if let url = write.url, !writer(nextTags, url) { continue }
                        result[write.id] = nextTags
                    }
                    return (removesTag, result)
                }.value
                let updatedTagsByID = mutation.tagsByID
                let shouldClearCurrentFilter = mutation.removesTag
                    && request.originFilter == .tag(request.tag)
                    && !request.originVisibleAssetIDs.isEmpty
                    && request.originVisibleAssetIDs.allSatisfy { targetIDs.contains($0) }
                guard !Task.isCancelled else { break }

                self.applyTagCopies(updatedTagsByID)
                self.clearCurrentTagFilterIfNeeded(
                    shouldClearCurrentFilter,
                    removedTag: request.tag,
                    targetAssets: targetAssets,
                    updatedTagsByID: updatedTagsByID,
                    originTabID: request.originTabID,
                    originFolderPath: request.originFolderPath,
                    originSearchText: request.originSearchText
                )
            }
            self.tagMutationTask = nil
        }
    }

    func revealInFinder(_ asset: LightboxAsset) {
        guard let url = asset.sourceURL else { return }
        revealURLInFinder(url)
    }

    func openWithApplication(_ asset: LightboxAsset, applicationURL: URL?) {
        let targets = operationTargetAssets(fallback: asset)
        let urls = targets.compactMap(\.sourceURL)
        guard !urls.isEmpty else { return }

        if let applicationURL {
            withExistingFileURLs(urls) { state, existing in state.open(existing, with: applicationURL) }
            return
        }

        let panel = NSOpenPanel()
        panel.title = localized(.openWith)
        panel.prompt = localized(.openWith).replacingOccurrences(of: "...", with: "")
        panel.message = urls.count == 1 ? asset.originalName : selectedCountText(urls.count)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK,
              let applicationURL = panel.url
        else { return }

        withExistingFileURLs(urls) { state, existing in state.open(existing, with: applicationURL) }
    }

    private func operationTargetAssets(fallback asset: LightboxAsset) -> [LightboxAsset] {
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            let selectedIDs = selectedAssetIDs
            return activeAssets.filter { selectedIDs.contains($0.id) }
        }

        return [asset]
    }

    private func withExistingFileURLs(_ urls: [URL], action: @escaping @MainActor (AppState, [URL]) -> Void) {
        fileActionTask?.cancel()
        fileActionTask = Task { [weak self] in
            guard let existing = try? await FileActionResolver.existingURLs(urls),
                  !Task.isCancelled, let self else { return }
            self.fileActionTask = nil
            guard !existing.isEmpty else { return }
            action(self, existing)
        }
    }

    private func open(_ urls: [URL], with applicationURL: URL) {
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if let error {
                Self.logger.error("open-with failed app=\(applicationURL.path, privacy: .public) count=\(urls.count) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func revealCurrentFolderInFinder() {
        let folderURL = isViewingTrash ? LightboxLibraryStore.primarySystemTrashFolder : currentFolderURL
        revealURLInFinder(folderURL)
    }

    func revealFolderInFinder(_ folder: LibraryFolderEntry) {
        revealURLInFinder(folder.url)
    }

    func revealSidebarURLInFinder(_ url: URL) {
        revealURLInFinder(url)
    }

    func isFolderPinned(_ url: URL) -> Bool {
        isFolderPinned(path: url.standardizedFileURL.path)
    }

    func isFolderPinned(path: String) -> Bool {
        sources.contains { source in
            !source.isLocalLibrary && source.rootURL.standardizedFileURL.path == path
        }
    }

    func togglePinFolderURL(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if let source = sources.first(where: {
            !$0.isLocalLibrary && $0.rootURL.standardizedFileURL.path == standardizedURL.path
        }) {
            unpinSource(source.id)
            return
        }

        pinFolder(standardizedURL, selectPinnedFolder: false)
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func revealURLInFinder(_ url: URL) {
        // Finder resolves missing or disconnected targets itself. A preflight
        // stat on a removable/network volume could stall the main actor.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToClipboard(_ asset: LightboxAsset) {
        let urls = operationTargetAssets(fallback: asset).compactMap(\.sourceURL)
        withExistingFileURLs(urls) { _, existing in ImageClipboardWriter.copyImages(at: existing) }
    }

    func share(_ asset: LightboxAsset, from view: NSView) {
        let urls = operationTargetAssets(fallback: asset).compactMap(\.sourceURL)
        withExistingFileURLs(urls) { [weak view] state, existing in
            guard let view, view.window != nil else { return }
            let picker = NSSharingServicePicker(items: existing)
            state.sharingPicker = picker
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    func refreshLibrary(preservingVisibleSnapshot: Bool = false) {
        // Explicit refreshes and directory change notifications invalidate the scan.
        recursiveSearchScope = nil
        guard !isShowingStartPage else {
            suspendActiveTabWork()
            assets = []
            folderEntries = []
            searchResultAssets = nil
            searchResultFolderEntries = nil
            libraryLoadingStatus = nil
            return
        }
        let cancelledRefreshTask = refreshTask != nil
        let cancelledLoadTask = libraryLoadTask != nil
        let cancelledMetadataTask = assetMetadataTask != nil
        refreshTask?.cancel()
        libraryLoadTask?.cancel()
        assetMetadataTask?.cancel()
        refreshSerial += 1
        let refreshID = refreshSerial
        if includesSubfolders {
            // A slow top-level folder snapshot must not delay recursive image results.
            scheduleSearch(preservingResults: preservingVisibleSnapshot, forceRefresh: true)
        }
        libraryLoadingStatus = LibraryLoadingStatus(phase: .scanning, processed: 0, total: nil)
        Self.logger.info("refresh[\(refreshID)] begin trash=\(self.isViewingTrash) source=\(self.selectedSourceID, privacy: .public) sourceKind=\(self.selectedSource?.kind.rawValue ?? "none", privacy: .public) folder=\(self.currentFolderURL.path, privacy: .public) cancelledDebounce=\(cancelledRefreshTask) cancelledLoad=\(cancelledLoadTask) cancelledMetadata=\(cancelledMetadataTask)")
        if isViewingTrash {
            folderEntries = []
            let trashFolders = LightboxLibraryStore.systemTrashFolders
            libraryLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let startedAt = Date()
                Self.logger.info("refresh[\(refreshID)] system trash scan task start folders=\(trashFolders.count)")
                let snapshot = LocalImageSource.loadSystemTrashSnapshot(in: trashFolders)

                await MainActor.run {
                    guard let self, !Task.isCancelled, self.isViewingTrash else {
                        Self.logger.info("refresh[\(refreshID)] trash ignored cancelled=\(Task.isCancelled)")
                        return
                    }
                    let applyStartedAt = Date()
                    self.trashAccessDenied = !snapshot.inaccessibleFolders.isEmpty && snapshot.assets.isEmpty
                    self.mergeLibrarySnapshot(snapshot.assets)
                    self.libraryLoadingStatus = nil
                    Self.logger.info("refresh[\(refreshID)] system trash complete folders=\(trashFolders.count) assets=\(snapshot.assets.count) deniedFolders=\(snapshot.inaccessibleFolders.count) apply=\(Date().timeIntervalSince(applyStartedAt), format: .fixed(precision: 2))s total=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                }
            }
            return
        }
        trashAccessDenied = false

        guard let source = selectedSource else {
            libraryLoadingStatus = nil
            Self.logger.info("refresh[\(refreshID)] no selected source")
            return
        }
        let folderURL = currentFolderURL
        let storageClassifier = storageClassifier
        let indexDatabaseURL = indexDatabaseURL
        let showsHiddenItems = showsHiddenItems
        let tabID = activeTabID
        libraryLoadTask = Task.detached(priority: .userInitiated) { [weak self, source, showsHiddenItems] in
            // SQLite reads and connection setup can wait on disk or another writer.
            // Never do them inside the main-actor tab activation path.
            let metadataStore = LightboxIndexStore(databaseURL: indexDatabaseURL)
            let cachedSnapshot = preservingVisibleSnapshot ? nil : metadataStore.cachedVisibleSnapshot(source: source, folderURL: folderURL)
            guard !Task.isCancelled else { return }
            let hasCachedVisibleSnapshot = await MainActor.run { () -> Bool in
                guard let self, self.refreshSerial == refreshID, self.activeTabID == tabID else { return false }
                return preservingVisibleSnapshot || self.applyCachedVisibleSnapshotIfAvailable(
                    cachedSnapshot, source: source, folderURL: folderURL, refreshID: refreshID
                )
            }
            guard !Task.isCancelled else { return }
            // Symlink resolution can wait on a disconnected volume. Cached content
            // is published first, and neither gallery bodies nor monitoring resolve it.
            let usesConservativeExternalLoading = storageClassifier(source)
            guard !Task.isCancelled else { return }
            let acceptedClassification = await MainActor.run { () -> Bool in
                guard let self, !Task.isCancelled, self.refreshSerial == refreshID,
                      self.activeTabID == tabID, !self.isViewingTrash,
                      self.selectedSource == source, self.currentFolderURL == folderURL else { return false }
                let classification = SourceStorageClassification(
                    source: source, conservative: usesConservativeExternalLoading
                )
                if self.sourceStorageClassification != classification {
                    self.sourceStorageClassification = classification
                }
                self.restartLibraryMonitor()
                return true
            }
            guard acceptedClassification else { return }
            let refreshPolicy = LibraryRefreshPolicy(
                usesConservativeExternalLoading: usesConservativeExternalLoading,
                hasCachedVisibleSnapshot: hasCachedVisibleSnapshot
            )
            let scanDelayMilliseconds = max(preservingVisibleSnapshot ? 350 : 0, refreshPolicy.scanStartDelayMilliseconds)
            if scanDelayMilliseconds > 0 {
                Self.logger.info("refresh[\(refreshID)] scan delayed cachedSnapshot=true delayMs=\(scanDelayMilliseconds) folder=\(folderURL.path, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(scanDelayMilliseconds))
                guard !Task.isCancelled else {
                    Self.logger.info("refresh[\(refreshID)] scan delay cancelled folder=\(folderURL.path, privacy: .public)")
                    return
                }
            }
            let startedAt = Date()
            Self.logger.info("refresh[\(refreshID)] scan task start source=\(source.id, privacy: .public) sourceKind=\(source.kind.rawValue, privacy: .public) folder=\(folderURL.path, privacy: .public)")
            let cachedDimensions = metadataStore.cachedDimensions(
                sourceID: source.id,
                parentPath: folderURL.path
            )
            // Attached SSDs are local volumes too. Keep network-volume caution,
            // without delaying dimension hydration for every /Volumes path.
            let isLocalVolume = (try? folderURL.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
            let directorySnapshot = LocalImageSource.loadFolderSnapshot(
                in: folderURL,
                sourceID: source.id,
                rootURL: source.rootURL,
                probeMetadata: false,
                probeFolderTags: !usesConservativeExternalLoading,
                initialMetadataLimit: usesConservativeExternalLoading ? (isLocalVolume ? 48 : 0) : 120,
                showsHiddenItems: showsHiddenItems,
                cachedDimensions: cachedDimensions
            )
            let folders = directorySnapshot.folders
            let snapshot = directorySnapshot.assets
            let sourceRootAvailability: LocalFolderSnapshotAvailability? = {
                guard case .unavailable(.sourceUnavailable) = directorySnapshot.availability,
                      folderURL.standardizedFileURL.path != source.rootURL.standardizedFileURL.path
                else {
                    return nil
                }
                return LocalImageSource.folderAvailability(in: source.rootURL)
            }()

            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.refreshSerial == refreshID,
                      self.activeTabID == tabID,
                      !self.isViewingTrash,
                      self.selectedSourceID == source.id,
                      self.currentFolderURL.standardizedFileURL.path == folderURL.standardizedFileURL.path
                else {
                    Self.logger.info("refresh[\(refreshID)] ignored cancelled=\(Task.isCancelled) folder=\(folderURL.path, privacy: .public)")
                    return
                }

                if case let .unavailable(reason) = directorySnapshot.availability {
                    if reason == .sourceUnavailable,
                       !self.preservesUnavailableCurrentFolder,
                       sourceRootAvailability == .available {
                        Self.logger.info("refresh[\(refreshID)] current folder missing, fallback=\(source.rootURL.path, privacy: .public)")
                        self.cancelPreviewDimensionResolution(clearPendingStep: true)
                        self.currentFolderURL = source.rootURL
                        self.resetScrollForNavigation()
                        self.saveCurrentFolderSession()
                        self.restartLibraryMonitor()
                        self.refreshLibrary()
                        return
                    }
                    self.libraryLoadingStatus = nil
                    Self.logger.error("refresh[\(refreshID)] scan unavailable reason=\(reason.rawValue, privacy: .public) keeping-current-content folder=\(folderURL.path, privacy: .public)")
                    return
                }

                let applyStartedAt = Date()
                self.preservesUnavailableCurrentFolder = false
                self.folderEntries = folders
                let mergeStartedAt = Date()
                self.mergeLibrarySnapshot(snapshot)
                let mergeSeconds = Date().timeIntervalSince(mergeStartedAt)
                Self.logger.info("refresh[\(refreshID)] scan complete entries=\(directorySnapshot.entryCount) folders=\(folders.count) assets=\(snapshot.count) read=\(directorySnapshot.directoryReadSeconds, format: .fixed(precision: 2))s classify=\(directorySnapshot.classificationSeconds, format: .fixed(precision: 2))s metadataProbe=\(directorySnapshot.metadataProbeSeconds, format: .fixed(precision: 2))s sort=\(directorySnapshot.sortSeconds, format: .fixed(precision: 2))s merge=\(mergeSeconds, format: .fixed(precision: 2))s scanTotal=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                self.libraryLoadingStatus = nil
                self.scheduleVisibleSnapshotIndex(
                    source: source,
                    folderURL: folderURL,
                    folders: folders,
                    assets: snapshot,
                    refreshID: refreshID
                )
                let requiresCompleteAssetTags: Bool
                if case .tag = self.selectedFilter {
                    requiresCompleteAssetTags = true
                } else {
                    requiresCompleteAssetTags = false
                }
                let metadataPolicy = AssetMetadataRefreshPolicy(
                    usesConservativeExternalLoading: usesConservativeExternalLoading,
                    requiresCompleteAssetTags: requiresCompleteAssetTags,
                    isLocalVolume: isLocalVolume
                )
                self.startAssetMetadataRefresh(
                    snapshot,
                    folderURL: folderURL,
                    sourceID: source.id,
                    refreshID: refreshID,
                    metadataLimit: metadataPolicy.dimensionLimit(assetCount: snapshot.count),
                    tagLimit: metadataPolicy.tagLimit(assetCount: snapshot.count),
                    loadsFinderTags: true,
                    startDelayMilliseconds: metadataPolicy.startDelayMilliseconds
                )
                self.scheduleSearch(preservingResults: preservingVisibleSnapshot, forceRefresh: !self.includesSubfolders)
                self.captureActiveTabState()
                Self.logger.info("refresh[\(refreshID)] apply complete applyTotal=\(Date().timeIntervalSince(applyStartedAt), format: .fixed(precision: 2))s folderEntries=\(self.folderEntries.count) storeAssets=\(self.assets.count) visibleSnapshotAssets=\(snapshot.count)")
            }
        }
    }

    private func applyCachedVisibleSnapshotIfAvailable(
        _ snapshot: IndexedVisibleSnapshot?,
        source: LibrarySource,
        folderURL: URL,
        refreshID: Int
    ) -> Bool {
        if let snapshot {
            let visibleFolders = showsHiddenItems
                ? snapshot.folders
                : snapshot.folders.filter { !LocalImageSource.isHiddenItemURL($0.url) }
            let visibleAssets = showsHiddenItems
                ? snapshot.assets
                : snapshot.assets.filter { asset in
                    guard let url = asset.sourceURL else { return true }
                    return !LocalImageSource.isHiddenItemURL(url)
                }
            folderEntries = visibleFolders
            mergeLibrarySnapshot(visibleAssets)
            Self.logger.info("refresh[\(refreshID)] cached snapshot applied folders=\(visibleFolders.count) assets=\(visibleAssets.count) folder=\(folderURL.path, privacy: .public)")
            return true
        }

        guard !visibleContentMatches(folderURL: folderURL) else {
            Self.logger.info("refresh[\(refreshID)] cached snapshot unavailable keeping-current-content folder=\(folderURL.path, privacy: .public)")
            return false
        }

        folderEntries = []
        mergeLibrarySnapshot([])
        Self.logger.info("refresh[\(refreshID)] cached snapshot unavailable cleared-stale-content folder=\(folderURL.path, privacy: .public)")
        return false
    }

    private func visibleContentMatches(folderURL: URL) -> Bool {
        let folderPath = folderURL.standardizedFileURL.path
        let assetsMatch = assets.allSatisfy { asset in
            asset.sourceURL?.deletingLastPathComponent().standardizedFileURL.path == folderPath
        }
        let foldersMatch = folderEntries.allSatisfy { folder in
            folder.url.deletingLastPathComponent().standardizedFileURL.path == folderPath
        }
        return assetsMatch && foldersMatch
    }

    private func scheduleLibraryRefresh() {
        Self.logger.info("refresh schedule debounce folder=\(self.currentFolderURL.path, privacy: .public) trash=\(self.isViewingTrash)")
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.refreshLibrary()
        }
    }

    private func restartLibraryMonitor() {
        guard !isShowingStartPage else {
            libraryDirectoryMonitor?.stop()
            libraryDirectoryMonitor = nil
            libraryMonitorContext = nil
            return
        }
        let monitoredURL = isViewingTrash ? LightboxLibraryStore.primarySystemTrashFolder : currentFolderURL
        if !isViewingTrash, selectedSourceUsesConservativeExternalLoading {
            libraryDirectoryMonitor?.stop()
            libraryDirectoryMonitor = nil
            libraryMonitorContext = nil
            Self.logger.info("monitor skipped external source path=\(monitoredURL.path, privacy: .public)")
            return
        }

        let context = LibraryMonitorContext(folderURL: monitoredURL, recursive: includesSubfolders)
        guard libraryMonitorContext != context || libraryDirectoryMonitor == nil else { return }
        libraryDirectoryMonitor?.stop()
        libraryMonitorContext = context

        Self.logger.info("monitor restart path=\(monitoredURL.path, privacy: .public) trash=\(self.isViewingTrash)")
        let monitor = directoryMonitorFactory(monitoredURL, includesSubfolders)
        libraryDirectoryMonitor = monitor
        monitor.start(onInvalidated: { [weak self, weak monitor] in
            guard let self, let monitor, self.libraryDirectoryMonitor === monitor else { return }
            self.libraryDirectoryMonitor = nil
            self.libraryMonitorContext = nil
        }) { [weak self] in
            self?.scheduleLibraryRefresh()
        }
    }

    private func mergeLibrarySnapshot(_ snapshot: [LightboxAsset]) {
        let snapshotByPath = Dictionary(
            snapshot.compactMap { asset -> (String, LightboxAsset)? in
                guard let key = sourceKey(for: asset) else { return nil }
                return (key, asset)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        var retainedKeys = Set<String>()
        let retainedAssets = assets.compactMap { existing -> LightboxAsset? in
            guard let key = sourceKey(for: existing),
                  let refreshed = snapshotByPath[key]
            else {
                return nil
            }

            var existing = existing
            existing.originalName = refreshed.originalName
            if refreshed.addedAt != .distantPast {
                existing.addedAt = refreshed.addedAt
            }
            if refreshed.contentModifiedAt != nil {
                existing.contentModifiedAt = refreshed.contentModifiedAt
            }
            if refreshed.fileSize != nil {
                existing.fileSize = refreshed.fileSize
            }
            if refreshed.metadataLoaded || !existing.metadataLoaded {
                existing.width = refreshed.width
                existing.height = refreshed.height
                existing.tags = refreshed.tags
                existing.metadataLoaded = refreshed.metadataLoaded
            }
            existing.sourceURL = refreshed.sourceURL
            existing.palette = refreshed.palette
            existing.deletedAt = refreshed.deletedAt
            retainedKeys.insert(key)
            return existing
        }

        let addedAssets = snapshot.filter { asset in
            guard let key = sourceKey(for: asset) else { return true }
            return !retainedKeys.contains(key)
        }

        assets = addedAssets + retainedAssets
        removeDetachedSelection()
    }

    private func startAssetMetadataRefresh(
        _ snapshot: [LightboxAsset],
        folderURL: URL,
        sourceID: LibrarySource.ID,
        refreshID: Int,
        metadataLimit: Int,
        tagLimit: Int,
        loadsFinderTags: Bool,
        startDelayMilliseconds: Int
    ) {
        let targets = snapshot.enumerated().compactMap { index, asset -> AssetMetadataTarget? in
            let shouldLoadDimensions = index < metadataLimit && !asset.metadataLoaded
            let shouldLoadTags = loadsFinderTags && index < tagLimit
            guard (shouldLoadDimensions || shouldLoadTags), let url = asset.sourceURL else { return nil }
            return AssetMetadataTarget(
                id: asset.id,
                url: url,
                shouldLoadDimensions: shouldLoadDimensions,
                shouldLoadTags: shouldLoadTags
            )
        }

        guard !targets.isEmpty else {
            Self.logger.info("refresh[\(refreshID)] metadata skipped no assets")
            return
        }

        Self.logger.info("refresh[\(refreshID)] metadata begin total=\(targets.count) dimensionLimit=\(metadataLimit) tagLimit=\(tagLimit) tags=\(loadsFinderTags) delayMs=\(startDelayMilliseconds) folder=\(folderURL.path, privacy: .public)")

        let indexDatabaseURL = indexDatabaseURL
        assetMetadataTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .milliseconds(startDelayMilliseconds))
            guard !Task.isCancelled else { return }
            let startedAt = Date()
            let dimensionIndexStore = LightboxIndexStore(databaseURL: indexDatabaseURL)
            var batch: [AssetMetadataUpdate] = []
            var processedCount = 0
            let batchSize = 32

            func persist(_ updates: [AssetMetadataUpdate]) {
                guard !updates.isEmpty else { return }
                dimensionIndexStore.updateCachedMetadata(
                    sourceID: sourceID,
                    updates: updates.map {
                        IndexedAssetMetadata(
                            url: $0.url,
                            width: $0.width,
                            height: $0.height,
                            tags: $0.tags
                        )
                    }
                )
            }

            for target in targets {
                guard !Task.isCancelled else {
                    persist(batch)
                    Self.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(targets.count)")
                    return
                }

                let metadata = autoreleasepool {
                    (
                        size: target.shouldLoadDimensions ? ImageProbe.dimensions(for: target.url) : nil,
                        tags: target.shouldLoadTags ? FinderTagStore.colorTags(for: target.url) : nil
                    )
                }
                processedCount += 1

                if metadata.size != nil || metadata.tags != nil {
                    batch.append(AssetMetadataUpdate(
                        id: target.id,
                        url: target.url,
                        width: metadata.size?.width,
                        height: metadata.size?.height,
                        tags: metadata.tags
                    ))
                }
                guard !Task.isCancelled else {
                    persist(batch)
                    Self.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(targets.count)")
                    return
                }

                if batch.count >= batchSize || processedCount % batchSize == 0 {
                    let updates = batch
                    batch.removeAll(keepingCapacity: true)
                    persist(updates)
                    await MainActor.run {
                        self?.applyAssetMetadataUpdates(
                            updates,
                            processedCount: processedCount,
                            totalCount: targets.count,
                            folderURL: folderURL,
                            sourceID: sourceID,
                            refreshID: refreshID
                        )
                    }
                    guard !Task.isCancelled else {
                        Self.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(targets.count)")
                        return
                    }
                }

                if processedCount % batchSize == 0 {
                    try? await Task.sleep(for: .milliseconds(6))
                }
            }

            if !batch.isEmpty || processedCount > 0 {
                persist(batch)
                await MainActor.run {
                    self?.applyAssetMetadataUpdates(
                        batch,
                        processedCount: processedCount,
                        totalCount: targets.count,
                        folderURL: folderURL,
                        sourceID: sourceID,
                        refreshID: refreshID
                    )
                }
                guard !Task.isCancelled else {
                    Self.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(targets.count)")
                    return
                }
            }

            await MainActor.run {
                self?.finishAssetMetadataRefresh(
                    folderURL: folderURL,
                    sourceID: sourceID,
                    refreshID: refreshID,
                    elapsed: Date().timeIntervalSince(startedAt)
                )
            }
        }
    }

    private func startCompleteAssetTagRefresh() {
        guard !isViewingTrash,
              !assets.isEmpty,
              let source = selectedSource
        else {
            return
        }

        assetMetadataTask?.cancel()
        startAssetMetadataRefresh(
            assets,
            folderURL: currentFolderURL,
            sourceID: source.id,
            refreshID: refreshSerial,
            metadataLimit: assets.count,
            tagLimit: assets.count,
            loadsFinderTags: true,
            startDelayMilliseconds: 0
        )
    }

    private func scheduleVisibleSnapshotIndex(
        source: LibrarySource,
        folderURL: URL,
        folders: [LibraryFolderEntry],
        assets: [LightboxAsset],
        refreshID: Int
    ) {
        indexWriteTask?.cancel()
        let indexDatabaseURL = indexDatabaseURL
        indexWriteTask = Task.detached(priority: .utility) {
            let startedAt = Date()
            let store = LightboxIndexStore(databaseURL: indexDatabaseURL)
            store.upsertSource(source)
            store.replaceVisibleSnapshot(
                source: source,
                folderURL: folderURL,
                folders: folders,
                assets: assets
            )
            Self.logger.info("refresh[\(refreshID)] index scheduled write finished seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))")
        }
    }

    private func applyAssetMetadataUpdates(
        _ updates: [AssetMetadataUpdate],
        processedCount: Int,
        totalCount: Int,
        folderURL: URL,
        sourceID: LibrarySource.ID,
        refreshID: Int
    ) {
        guard !isViewingTrash,
              selectedSourceID == sourceID,
              currentFolderURL.standardizedFileURL.path == folderURL.standardizedFileURL.path
        else {
            Self.logger.info("refresh[\(refreshID)] metadata batch ignored processed=\(processedCount)/\(totalCount)")
            return
        }

        Self.logger.info("refresh[\(refreshID)] metadata batch processed=\(processedCount)/\(totalCount) updates=\(updates.count)")

        let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        var nextAssets = assets
        var changed = false

        for index in nextAssets.indices {
            guard let update = updatesByID[nextAssets[index].id] else { continue }
            if let width = update.width, let height = update.height {
                nextAssets[index].width = width
                nextAssets[index].height = height
                nextAssets[index].metadataLoaded = true
            }
            if let tags = update.tags {
                nextAssets[index].tags = tags
            }
            changed = true
        }

        if changed {
            assets = nextAssets
        }
    }

    private func applySearchResultMetadataUpdates(
        _ updates: [AssetMetadataUpdate],
        sourceID: LibrarySource.ID,
        folderPath: String,
        searchText expectedSearchText: String?,
        generation: Int
    ) {
        guard !updates.isEmpty,
              searchGeneration == generation,
              !isViewingTrash,
              selectedSourceID == sourceID,
              currentFolderURL.standardizedFileURL.path == folderPath,
              expectedSearchText == nil || searchText.trimmingCharacters(in: .whitespacesAndNewlines) == expectedSearchText
        else {
            return
        }

        let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        var didChange = false

        func apply(_ asset: inout LightboxAsset) -> Bool {
            guard let update = updatesByID[asset.id] else { return false }
            let previous = asset
            if let width = update.width, let height = update.height {
                asset.width = width
                asset.height = height
                asset.metadataLoaded = true
            }
            if let tags = update.tags { asset.tags = tags }
            return asset != previous
        }

        if var searchResultAssets {
            for index in searchResultAssets.indices {
                if apply(&searchResultAssets[index]) { didChange = true }
            }
            if didChange {
                self.searchResultAssets = searchResultAssets
            }
        }

        // Publish one complete batch: mutating @Published array elements separately
        // rebuilds and sorts the entire gallery after every field assignment.
        var nextAssets = assets
        var assetsChanged = false
        for index in nextAssets.indices {
            if apply(&nextAssets[index]) { assetsChanged = true }
        }

        if var previewAssetSnapshot, apply(&previewAssetSnapshot) {
            self.previewAssetSnapshot = previewAssetSnapshot
        }

        if assetsChanged {
            // Commit the direct-folder fields without rebuilding the recursive
            // snapshot through assets.didSet as well as the metadata path below.
            isApplyingSearchMetadata = true
            assets = nextAssets
            isApplyingSearchMetadata = false
        }
        if assetsChanged || didChange {
            rebuildLibraryColorTags()
            if selectedFilter == .all, sortField != .tag {
                // Only dimensions/tags changed. Keep membership, navigation IDs,
                // group titles and order; do not standardize every file URL again.
                var visibleAssets = cachedActiveAssets
                var visibleChanged = false
                for index in visibleAssets.indices {
                    if apply(&visibleAssets[index]) { visibleChanged = true }
                }
                if visibleChanged {
                    for groupIndex in cachedSearchAssetGroups.indices {
                        for assetIndex in cachedSearchAssetGroups[groupIndex].assets.indices {
                            _ = apply(&cachedSearchAssetGroups[groupIndex].assets[assetIndex])
                        }
                    }
                    activeAssetsRevision &+= 1
                    cachedActiveAssets = visibleAssets
                }
            } else {
                rebuildActiveAssets()
            }
        }
    }

    private func finishAssetMetadataRefresh(
        folderURL: URL,
        sourceID: LibrarySource.ID,
        refreshID: Int,
        elapsed: TimeInterval
    ) {
        guard !isViewingTrash,
              selectedSourceID == sourceID,
              currentFolderURL.standardizedFileURL.path == folderURL.standardizedFileURL.path
        else {
            Self.logger.info("refresh[\(refreshID)] metadata finish ignored")
            return
        }

        Self.logger.info("refresh[\(refreshID)] metadata finish seconds=\(elapsed, format: .fixed(precision: 2))")
    }

    private func rebuildActiveAssets() {
        let query = LightboxSearchQuery.parse(searchText)
        let sourceAssets = searchResultAssetsForActiveQuery ?? assets
        let locale = Locale.current.identifier
        // Filtering preserves a sorted snapshot's order. Reuse only a complete
        // non-trash result with identical source values and sort semantics.
        let snapshot = sortedUnfilteredSnapshot
        let reusesSort = selectedFilter != .trash && snapshot?.field == sortField
            && snapshot?.direction == sortDirection && snapshot?.locale == locale
            && snapshot?.source == sourceAssets
        let candidates = reusesSort ? (snapshot?.assets ?? sourceAssets) : sourceAssets
        let filtered: [LightboxAsset] = switch selectedFilter {
        case .all:
            candidates.filter { !$0.isDeleted }
        case .tag(let tag):
            candidates.filter { !$0.isDeleted && $0.tags.contains(tag) }
        case .trash:
            candidates.filter(\.isDeleted)
        }
        let matches = query.isEmpty ? filtered : filtered.filter(query.matches)
        let ordered = reusesSort ? matches : sortedAssets(matches)
        if selectedFilter == .all, query.isEmpty {
            sortedUnfilteredSnapshot = (sourceAssets, sortField, sortDirection, locale, ordered)
        }
        setCachedActiveAssets(ordered)
    }

    private func setCachedActiveAssets(_ nextAssets: [LightboxAsset]) {
        guard cachedActiveAssets != nextAssets else { return }
        cachedActiveAssetIDList = nextAssets.map(\.id)
        cachedActiveAssetIDs = Set(cachedActiveAssetIDList)
        cachedSearchAssetGroups = makeSearchAssetGroups(for: nextAssets)
        activeAssetsRevision &+= 1
        cachedActiveAssets = nextAssets
    }

    private func rebuildActiveFolderEntries() {
        guard !isViewingTrash else {
            setCachedActiveFolderEntries([])
            return
        }
        guard hasSearchQuery else {
            setCachedActiveFolderEntries(sortedFolderEntries(folderEntries))
            return
        }

        let query = LightboxSearchQuery.parse(searchText)
        guard !query.isEmpty else {
            setCachedActiveFolderEntries(sortedFolderEntries(folderEntries))
            return
        }

        if let searchResultFolderEntries {
            setCachedActiveFolderEntries(sortedFolderEntries(searchResultFolderEntries.filter(query.matches)))
        } else {
            setCachedActiveFolderEntries(sortedFolderEntries(folderEntries.filter(query.matches)))
        }
    }

    private func setCachedActiveFolderEntries(_ nextEntries: [LibraryFolderEntry]) {
        guard cachedActiveFolderEntries != nextEntries else { return }
        cachedActiveFolderEntries = nextEntries
    }

    private func rebuildLibraryColorTags() {
        let availableTagNames = Set(
            (assets + (searchResultAssetsForActiveQuery ?? [])).lazy
                .filter { !$0.isDeleted }
                .flatMap(\.tags)
        )
        let nextTags = MacColorTag.all.filter { availableTagNames.contains($0.name) }
        guard cachedLibraryColorTags != nextTags else { return }
        cachedLibraryColorTags = nextTags
    }

    private var searchResultAssetsForActiveQuery: [LightboxAsset]? {
        guard usesRecursiveResults, !isViewingTrash else { return nil }
        // Recursive results arrive incrementally; avoid mixing in direct-folder cards.
        return searchResultAssets ?? (includesSubfolders ? [] : nil)
    }

    private func scheduleSearch(preservingResults: Bool = false, forceRefresh: Bool = false) {
        let scope = RecursiveSearchScope(
            sourceID: selectedSourceID,
            folderPath: currentFolderURL.standardizedFileURL.path,
            showsHiddenItems: showsHiddenItems
        )
        // A recursive scan already covers every name. Typing filters that snapshot,
        // including while it is arriving, without restarting NAS I/O or metadata work.
        if !forceRefresh, includesSubfolders, recursiveSearchScope == scope, searchStatus != nil {
            return
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        recursiveSearchScope = nil
        let generation = searchGeneration
        let keepsVisibleSearchSnapshot = preservingResults && searchStatus?.isSearching == false
            && searchResultAssets?.isEmpty == false
        let knownSearchAssets = preservingResults ? (searchResultAssets ?? []) : []
        if !preservingResults { clearSearchResults() }
        searchStatus = nil

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isShowingStartPage,
              (!trimmedSearchText.isEmpty || includesSubfolders),
              !isViewingTrash,
              let source = selectedSource
        else {
            return
        }

        let query = LightboxSearchQuery.parse(trimmedSearchText)
        guard !query.isEmpty || includesSubfolders else { return }

        let recursive = includesSubfolders
        if recursive { recursiveSearchScope = scope }
        let scanQuery = recursive ? LightboxSearchQuery.parse("") : query
        let searchFolder = currentFolderURL
        let sourceID = source.id
        let sourceRootURL = source.rootURL
        let currentFolderPath = currentFolderURL.standardizedFileURL.path
        let indexDatabaseURL = indexDatabaseURL
        let showsHiddenItems = showsHiddenItems
        searchStatus = LightboxSearchStatus(isSearching: true)
        let dimensionProbe = searchDimensionProbe

        searchTask = Task.detached(priority: .utility) { [weak self, scanQuery, searchFolder, sourceID, sourceRootURL, currentFolderPath, trimmedSearchText, showsHiddenItems, recursive, generation] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let metadataSnapshot = SearchMetadataSnapshot(knownSearchAssets)

            let publishProgress: @Sendable (LightboxSearchScanResult) -> Void = { [weak self] partial in
                var partial = partial
                if !keepsVisibleSearchSnapshot {
                    partial.assets = metadataSnapshot.mergingDimensions(into: partial.assets)
                }
                let progress = partial
                Task { @MainActor [weak self] in
                    guard let self,
                          self.searchStatus?.isSearching == true,
                          self.searchGeneration == generation,
                          self.selectedSourceID == sourceID,
                          !self.isViewingTrash,
                          self.currentFolderURL.standardizedFileURL.path == currentFolderPath,
                          recursive || self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSearchText,
                          progress.visitedCount > (self.searchStatus?.visitedCount ?? 0)
                    else { return }
                    // A refresh keeps the complete usable gallery until the new
                    // scan completes. Partial snapshots would repeatedly remove
                    // and recreate cards that have already been displayed.
                    if !keepsVisibleSearchSnapshot {
                        self.searchResultAssets = progress.assets
                        self.searchResultFolderEntries = progress.folders
                    }
                    self.searchStatus = LightboxSearchStatus(
                        isSearching: true, limitReached: progress.limitReached,
                        discoveredCount: progress.assets.count, visitedCount: progress.visitedCount
                    )
                    if !keepsVisibleSearchSnapshot {
                        self.rebuildLibraryColorTags()
                        self.rebuildActiveAssets()
                        self.rebuildActiveFolderEntries()
                    }
                }
            }
            var scanned: LightboxSearchScanResult
            if recursive {
                scanned = await LocalImageSource.scanRecursiveAssets(
                    in: searchFolder, sourceID: sourceID, rootURL: sourceRootURL,
                    showsHiddenItems: showsHiddenItems, onProgress: publishProgress
                )
            } else {
                scanned = LocalImageSource.searchAssets(
                    in: searchFolder, sourceID: sourceID, rootURL: sourceRootURL,
                    query: scanQuery, recursive: false, showsHiddenItems: showsHiddenItems,
                    skipsPackages: true, onProgress: publishProgress
                )
            }
            guard !Task.isCancelled else { return }
            scanned.assets = metadataSnapshot.mergingDimensions(into: scanned.assets)
            let result = scanned

            let didApplySearchResults = await MainActor.run { () -> Bool in
                guard let self,
                      !Task.isCancelled,
                      self.searchGeneration == generation,
                      self.selectedSourceID == sourceID,
                      !self.isViewingTrash,
                      recursive || self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSearchText,
                      self.currentFolderURL.standardizedFileURL.path == currentFolderPath
                else {
                    return false
                }

                self.searchResultAssets = result.assets
                self.rebuildLibraryColorTags()
                self.searchResultFolderEntries = result.folders
                self.searchStatus = LightboxSearchStatus(
                    isSearching: false, limitReached: result.limitReached,
                    discoveredCount: result.assets.count, visitedCount: result.visitedCount
                )
                self.rebuildActiveAssets()
                self.rebuildActiveFolderEntries()
                self.removeDetachedSelection()
                return true
            }
            guard didApplySearchResults else { return }

            // Match the gallery order so visible images receive dimensions first.
            let metadataSort = await MainActor.run { () -> (GallerySortField, GallerySortDirection)? in
                guard let self, self.searchGeneration == generation, !Task.isCancelled else { return nil }
                return (self.sortField, self.sortDirection)
            }
            guard let metadataSort, !Task.isCancelled else { return }
            let orderedAssets = GalleryAssetSorter.sorted(result.assets,
                field: metadataSort.0, direction: metadataSort.1)
            guard !Task.isCancelled else { return }
            let metadataTargets = orderedAssets
                .prefix(recursive ? Int.max : Self.searchMetadataRefreshLimit)
                .compactMap { asset -> AssetMetadataTarget? in
                    guard recursive || !asset.metadataLoaded, let url = asset.sourceURL else { return nil }
                    return AssetMetadataTarget(
                        id: asset.id,
                        url: url,
                        shouldLoadDimensions: !asset.metadataLoaded,
                        shouldLoadTags: recursive
                    )
                }
            guard !metadataTargets.isEmpty else { return }
            await MainActor.run {
                guard let self, self.searchGeneration == generation else { return }
                self.searchStatus?.metadataTotal = metadataTargets.count
            }

            let metadataStore = LightboxIndexStore(databaseURL: indexDatabaseURL)
            var batch: [AssetMetadataUpdate] = []
            var processedCount = 0
            var lastPublishAt = Date()
            for target in metadataTargets {
                guard !Task.isCancelled else { return }
                let size = target.shouldLoadDimensions ? autoreleasepool(invoking: {
                    RecursiveImageDimensionCache.shared.dimensions(for: target.url, resolver: dimensionProbe)
                }) : nil
                guard !Task.isCancelled else { return }
                let tags = target.shouldLoadTags ? FinderTagStore.colorTags(for: target.url) : nil
                guard !Task.isCancelled else { return }
                processedCount += 1
                batch.append(AssetMetadataUpdate(
                    id: target.id,
                    url: target.url,
                    width: size?.width,
                    height: size?.height,
                    tags: tags
                ))

                // Fast local metadata can otherwise invalidate the entire shell
                // dozens of times per second. Keep the first image immediate,
                // then bound both batch memory and the time to the next update.
                let batchLimit = recursive ? 256 : 48
                let publishInterval = recursive ? 0.15 : 0.5
                if (recursive && processedCount == 1) || batch.count >= batchLimit || Date().timeIntervalSince(lastPublishAt) >= publishInterval {
                    lastPublishAt = Date()
                    let updates = batch
                    batch.removeAll(keepingCapacity: true)
                    metadataStore.updateCachedMetadata(
                        sourceID: sourceID,
                        updates: updates.map {
                            IndexedAssetMetadata(
                                url: $0.url,
                                width: $0.width,
                                height: $0.height,
                                tags: $0.tags
                            )
                        }
                    )
                    await MainActor.run {
                        self?.applySearchResultMetadataUpdates(
                            updates,
                            sourceID: sourceID,
                            folderPath: currentFolderPath,
                            searchText: recursive ? nil : trimmedSearchText,
                            generation: generation
                        )
                        if let self, self.searchGeneration == generation {
                            self.searchStatus?.metadataProcessed = processedCount
                        }
                    }
                }

                if processedCount % 32 == 0 {
                    try? await Task.sleep(for: .milliseconds(4))
                }
            }

            guard !batch.isEmpty else { return }
            metadataStore.updateCachedMetadata(
                sourceID: sourceID,
                updates: batch.map {
                    IndexedAssetMetadata(
                        url: $0.url,
                        width: $0.width,
                        height: $0.height,
                        tags: $0.tags
                    )
                }
            )
            await MainActor.run {
                self?.applySearchResultMetadataUpdates(
                    batch,
                    sourceID: sourceID,
                    folderPath: currentFolderPath,
                    searchText: recursive ? nil : trimmedSearchText,
                    generation: generation
                )
                if let self, self.searchGeneration == generation {
                    self.searchStatus?.metadataProcessed = processedCount
                }
            }
        }
    }

    private func clearSearchResults() {
        searchResultAssets = nil
        searchResultFolderEntries = nil
        rebuildLibraryColorTags()
    }

    private func sortedAssets(_ items: [LightboxAsset]) -> [LightboxAsset] {
        GalleryAssetSorter.sorted(items, field: sortField, direction: sortDirection)
    }

    private func sortedFolderEntries(_ items: [LibraryFolderEntry]) -> [LibraryFolderEntry] {
        LibraryFolderEntrySorter.sorted(items, field: sortField, direction: sortDirection)
    }

    private func assetForCurrentPresentation(_ assetID: LightboxAsset.ID) -> LightboxAsset? {
        assets.first { $0.id == assetID }
            ?? searchResultAssets?.first { $0.id == assetID }
            ?? cachedActiveAssets.first { $0.id == assetID }
    }

    private func updatePresentedAssetDimensions(
        _ assetID: LightboxAsset.ID,
        width: CGFloat,
        height: CGFloat,
        metadataLoaded: Bool
    ) {
        if let index = searchResultAssets?.firstIndex(where: { $0.id == assetID }) {
            searchResultAssets?[index].width = width
            searchResultAssets?[index].height = height
            searchResultAssets?[index].metadataLoaded = metadataLoaded
        }

        if let index = cachedActiveAssets.firstIndex(where: { $0.id == assetID }) {
            cachedActiveAssets[index].width = width
            cachedActiveAssets[index].height = height
            cachedActiveAssets[index].metadataLoaded = metadataLoaded
        }

        if previewAssetSnapshot?.id == assetID {
            previewAssetSnapshot?.width = width
            previewAssetSnapshot?.height = height
            previewAssetSnapshot?.metadataLoaded = metadataLoaded
        }
    }

    private func removeDetachedSelection() {
        if usesRecursiveResults, searchResultAssets == nil {
            return
        }
        let assetIDs = Set((assets + (searchResultAssets ?? []) + cachedActiveAssets).map(\.id))

        if let selectedAssetID, !assetIDs.contains(selectedAssetID) {
            self.selectedAssetID = nil
        }

        selectedAssetIDs = selectedAssetIDs.filter { assetIDs.contains($0) }
        if let selectionAnchorID, !assetIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }

        if let previewAssetID, !assetIDs.contains(previewAssetID), !trashMovingAssetIDs.contains(previewAssetID) {
            previewOpenTask?.cancel()
            previewCloseTask?.cancel()
            previewSourceRevealTask?.cancel()
            self.previewAssetID = nil
            previewSourceHiddenAssetID = nil
            previewInteractionLayerReady = false
            previewSourceFrame = nil
            previewAssetSnapshot = nil
            previewPhase = .closed
            previewSessionID = UUID()
            previewStepDirection = nil
        }
    }

    private func clearCurrentTagFilterIfNeeded(
        _ shouldClear: Bool,
        removedTag tag: String,
        targetAssets: [LightboxAsset],
        updatedTagsByID: [LightboxAsset.ID: [String]],
        originTabID: UUID?,
        originFolderPath: String?,
        originSearchText: String?
    ) {
        guard shouldClear,
              !targetAssets.isEmpty,
              targetAssets.allSatisfy({ updatedTagsByID[$0.id]?.contains(tag) == false })
        else {
            return
        }

        guard let originTabID else { return }
        if originTabID == activeTabID {
            guard selectedFilter == .tag(tag),
                  currentFolderURL.standardizedFileURL.path == originFolderPath,
                  searchText == originSearchText
            else {
                return
            }
            selectedFilter = .all
            return
        }

        guard let index = tabs.firstIndex(where: { $0.id == originTabID }),
              tabs[index].filter == .tag(tag),
              tabs[index].folderURL.standardizedFileURL.path == originFolderPath,
              tabs[index].searchText == originSearchText
        else {
            return
        }
        tabs[index].filter = .all
        tabs[index].selectedAssetIDs = []
        tabs[index].selectedAssetID = nil
        scheduleTabPersistence()
    }

    private func update(_ asset: LightboxAsset, body: (inout LightboxAsset) -> Void) {
        var didUpdate = false
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            body(&assets[index])
            didUpdate = true
        }
        if var searchResultAssets,
           let index = searchResultAssets.firstIndex(where: { $0.id == asset.id }) {
            body(&searchResultAssets[index])
            self.searchResultAssets = searchResultAssets
            didUpdate = true
        }
        if let index = cachedActiveAssets.firstIndex(where: { $0.id == asset.id }) {
            body(&cachedActiveAssets[index])
            didUpdate = true
        }
        if var snapshot = previewAssetSnapshot, snapshot.id == asset.id {
            body(&snapshot)
            previewAssetSnapshot = snapshot
            didUpdate = true
        }
        if didUpdate {
            rebuildActiveAssets()
        }
    }

    private func applyTagCopies(_ tagsByID: [LightboxAsset.ID: [String]]) {
        guard !tagsByID.isEmpty else { return }

        var nextAssets = assets
        var changedAssets = false
        for index in nextAssets.indices {
            guard let tags = tagsByID[nextAssets[index].id] else { continue }
            nextAssets[index].tags = tags
            changedAssets = true
        }
        if changedAssets {
            assets = nextAssets
        }

        if var searchResultAssets {
            var changedSearchResults = false
            for index in searchResultAssets.indices {
                guard let tags = tagsByID[searchResultAssets[index].id] else { continue }
                searchResultAssets[index].tags = tags
                changedSearchResults = true
            }
            if changedSearchResults {
                self.searchResultAssets = searchResultAssets
            }
        }

        if let previewAssetSnapshot,
           let tags = tagsByID[previewAssetSnapshot.id] {
            self.previewAssetSnapshot?.tags = tags
        }

        rebuildActiveAssets()
    }

    private func sourceKey(for asset: LightboxAsset) -> String? {
        asset.sourceURL?.standardizedFileURL.path
    }

    private func toggleSelection(_ asset: LightboxAsset) {
        selectedGalleryFolderID = nil
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
            selectedAssetID = firstVisibleID(in: selectedAssetIDs)
            if selectedAssetIDs.isEmpty {
                selectionAnchorID = nil
            }
        } else {
            selectedAssetIDs.insert(asset.id)
            selectedAssetID = asset.id
            selectionAnchorID = asset.id
        }
    }

    private func selectRange(to asset: LightboxAsset, extending: Bool) {
        let visibleIDs = activeAssetIDList
        let anchorID = selectionAnchorID ?? selectedAssetID ?? firstVisibleID(in: selectedAssetIDs) ?? asset.id

        guard let anchorIndex = visibleIDs.firstIndex(of: anchorID),
              let targetIndex = visibleIDs.firstIndex(of: asset.id)
        else {
            replaceSelection(with: [asset.id], primary: asset.id, anchor: asset.id)
            return
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let rangeIDs = Set(visibleIDs[bounds])
        let newSelection = extending ? selectedAssetIDs.union(rangeIDs) : rangeIDs
        replaceSelection(with: newSelection, primary: asset.id, anchor: anchorID)
    }

    private func replaceSelection(
        with ids: Set<LightboxAsset.ID>,
        primary: LightboxAsset.ID?,
        anchor: LightboxAsset.ID?
    ) {
        if !ids.isEmpty, selectedGalleryFolderID != nil { selectedGalleryFolderID = nil }
        if selectedAssetIDs != ids { selectedAssetIDs = ids }
        if selectedAssetID != primary { selectedAssetID = primary }
        selectionAnchorID = ids.isEmpty ? nil : anchor
    }

    private func firstVisibleID(in ids: Set<LightboxAsset.ID>) -> LightboxAsset.ID? {
        guard !ids.isEmpty else { return nil }
        return activeAssetIDList.first { ids.contains($0) }
    }

    nonisolated private static func frameDescription(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
    }

    nonisolated private static func clickDescription(_ click: LightboxClickContext?, sourceFrame: CGRect?) -> String {
        LightboxClickFormatter.describe(click, previewSpacePoint: click?.mappedTopLeftPoint(in: sourceFrame))
    }

    nonisolated private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < frame.minX {
            dx = frame.minX - point.x
        } else if point.x > frame.maxX {
            dx = point.x - frame.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < frame.minY {
            dy = frame.minY - point.y
        } else if point.y > frame.maxY {
            dy = point.y - frame.maxY
        } else {
            dy = 0
        }

        return hypot(dx, dy)
    }

    nonisolated private static func durationDescription(_ duration: Duration) -> String {
        "\(duration)"
    }
}

enum PreviewDirection {
    case previous
    case next

    var rawValue: String {
        switch self {
        case .previous:
            "previous"
        case .next:
            "next"
        }
    }
}

private struct AssetMetadataTarget: Sendable {
    var id: LightboxAsset.ID
    var url: URL
    var shouldLoadDimensions: Bool
    var shouldLoadTags: Bool
}

private struct AssetMetadataUpdate: Sendable {
    var id: LightboxAsset.ID
    var url: URL
    var width: CGFloat?
    var height: CGFloat?
    var tags: [String]?
}

struct LibraryLoadingStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case scanning
        case preparingPreviews
    }

    var phase: Phase
    var processed: Int
    var total: Int?
}

private enum PreviewPhase: String {
    case closed
    case opening
    case open
    case closing
}
