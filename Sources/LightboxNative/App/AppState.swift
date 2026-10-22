import AppKit
import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct SearchAssetGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var assets: [LightboxAsset]
}

struct RecursiveSearchScope: Equatable {
    var sourceID: LibrarySource.ID
    var folderPath: String
    var showsHiddenItems: Bool
    var showsOtherFiles = false
}

struct SourceStorageClassification: Equatable {
    var source: LibrarySource
    var conservative: Bool
}

struct LibraryMonitorContext: Equatable {
    var folderURL: URL
    var recursive: Bool
    var includesOtherFiles: Bool
}

struct TabContentSnapshot {
    var tab: LightboxTab
    var showsHiddenItems: Bool
    var showsOtherFiles = false
    /// The view mode decides this too, and it is shared by all tabs.
    var includesSubfolders = false
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

enum TagMutationAction: Equatable, Sendable {
    case add
    case toggle
    /// Keep, reject or clear (see `CullMark`); `tag` is unused.
    case cull(CullMark)
    /// Puts back each asset's tags exactly (an undo); `tag` is unused.
    case restore([LightboxAsset.ID: [String]])
}

struct TagMutationRequest: Sendable {
    var tag: String
    var assets: [LightboxAsset]
    var action: TagMutationAction
    var originTabID: UUID? = nil
    var originFilter: LibraryFilter? = nil
    var originVisibleAssetIDs: Set<LightboxAsset.ID> = []
    var originFolderPath: String? = nil
    var originSearchText: String? = nil
    /// Given each asset's previous tags once written.
    var undoStep: TagUndoStep? = nil
}

struct TagMutationWrite: Sendable {
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

struct SidebarVolumeObserverToken: @unchecked Sendable {
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
    nonisolated static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "LibraryLoading")
    nonisolated static let comparisonLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Comparison")
    nonisolated static let previewLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Preview")
    @Published var sidebarCollapsed = LightboxSettingsStore.defaultSidebarCollapsed {
        didSet {
            LightboxSettingsStore.saveSidebarCollapsed(sidebarCollapsed, defaults: libraryDefaults)
        }
    }
    @Published var sidebarWidth: CGFloat = LightboxSettingsStore.defaultSidebarWidth {
        didSet {
            let clamped = LightboxSettingsStore.clampSidebarWidth(sidebarWidth)
            if sidebarWidth != clamped {
                sidebarWidth = clamped
            }
            LightboxSettingsStore.saveSidebarWidth(clamped, defaults: libraryDefaults)
        }
    }
    @Published var sidebarVisibleLocationIDs: Set<SidebarLocationID> = LightboxSettingsStore.defaultSidebarLocationIDs {
        didSet {
            LightboxSettingsStore.saveSidebarVisibleLocationIDs(sidebarVisibleLocationIDs, defaults: libraryDefaults)
            refreshSidebarDestinations()
        }
    }
    @Published var sidebarLocations: [SidebarLocationID] = []
    @Published var sidebarLocationDirectories: [SidebarLocationID: SidebarDirectoryIdentity] = [:]
    @Published var sidebarVolumes: [SidebarVolume] = []
    /// Grid or list, for every folder; kept across launches. The list shows
    /// this folder only, as Finder's does: a tab browsing with subfolders gets
    /// them back in the grid (see `includesSubfolders`).
    @Published var galleryViewMode: GalleryViewMode = .grid {
        didSet {
            guard galleryViewMode != oldValue else { return }
            LightboxSettingsStore.saveViewMode(galleryViewMode, defaults: libraryDefaults)
            if galleryLayoutMode == .recursive, !isApplyingTabState { applyBrowsingScopeChange() }
        }
    }
    @Published var showFolderCards = LightboxSettingsStore.defaultShowFolderCards {
        didSet {
            LightboxSettingsStore.saveShowFolderCards(showFolderCards, defaults: libraryDefaults)
        }
    }
    @Published var showsHiddenItems = LightboxSettingsStore.defaultShowsHiddenItems {
        didSet {
            guard showsHiddenItems != oldValue else { return }
            LightboxSettingsStore.saveShowsHiddenItems(showsHiddenItems, defaults: libraryDefaults)
            refreshLibrary()
            scheduleSearch()
        }
    }
    /// Lists files other than images as icon tiles. Off by default, so the
    /// gallery stays images-only; scans, caches and the folder watcher follow it.
    @Published var showsOtherFiles = LightboxSettingsStore.defaultShowsOtherFiles {
        didSet {
            guard showsOtherFiles != oldValue else { return }
            LightboxSettingsStore.saveShowsOtherFiles(showsOtherFiles, defaults: libraryDefaults)
            if !showsOtherFiles, [.videos, .documents].contains(attributeFilter.kind) {
                attributeFilter.kind = .any
            }
            restartLibraryMonitor()
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
    /// Kind, orientation, pixel size, date and file size; kept per tab and
    /// cleared on opening another folder, like the name search.
    @Published var attributeFilter = GalleryAttributeFilter() {
        didSet {
            guard attributeFilter != oldValue, !isApplyingTabState else { return }
            rebuildActiveAssets()
            clearSelection()
            captureActiveTabState()
        }
    }
    /// The preview's last culling mark, shown briefly over the image.
    @Published var cullFeedback: CullFeedback?
    /// The bottom bar's filter popover; the View menu opens it too.
    @Published var showsAttributeFilterPanel = false
    @Published var galleryLayoutMode: GalleryLayoutMode = .masonry {
        didSet {
            guard galleryLayoutMode != oldValue, !isApplyingTabState else { return }
            applyBrowsingScopeChange()
        }
    }

    /// One more (`delta` 1) or one fewer (-1) image per row in the grid: the
    /// slider's end dots and ⌘− / ⌘=. False when the grid can't go further.
    @discardableResult
    func stepThumbnailColumns(by delta: Int) -> Bool {
        let available = thumbnailScale.galleryAvailableWidth
        guard galleryViewMode == .grid, available > 0 else { return false }
        let current = GalleryThumbnailSizing.columns(forWidth: thumbnailWidth, availableWidth: available)
        guard let width = GalleryThumbnailSizing.width(forColumns: current + delta, availableWidth: available) else {
            return false
        }
        if let anchor = currentScrollAnchorAssetID {
            thumbnailScale.columnStepAnchor = ColumnStepAnchor(
                assetID: anchor, generation: (thumbnailScale.columnStepAnchor?.generation ?? 0) + 1)
        }
        thumbnailWidth = width
        return true
    }

    /// After `includesSubfolders` changed.
    private func applyBrowsingScopeChange() {
        clearSelection()
        scheduleSearch()
        rebuildActiveAssets()
        rebuildActiveFolderEntries()
        restartLibraryMonitor()
        captureActiveTabState()
    }
    /// Thumbnail size and slider drag state, observed by the gallery and the
    /// slider alone (see `ThumbnailScaleState`).
    let thumbnailScale = ThumbnailScaleState()
    /// Forwards to `thumbnailScale`; never republishes the app state.
    var thumbnailWidth: CGFloat {
        get { thumbnailScale.width }
        set {
            guard thumbnailScale.width != newValue else { return }
            thumbnailScale.width = newValue
            // While the slider is dragged, capture once on release: each capture
            // republishes `tabs`, which every app-state observer re-renders for.
            guard !isApplyingTabState, !isScalingThumbnails else { return }
            captureActiveTabState()
        }
    }
    /// Forwards to `thumbnailScale`, like `thumbnailWidth`.
    var isScalingThumbnails: Bool {
        get { thumbnailScale.isScaling }
        set {
            let wasScaling = thumbnailScale.isScaling
            guard wasScaling != newValue else { return }
            thumbnailScale.isScaling = newValue
            if wasScaling { captureActiveTabState() }
        }
    }
    @Published var assets: [LightboxAsset] = [] {
        didSet {
            guard !isApplyingTabState, !isApplyingSearchMetadata else { return }
            rebuildLibraryColorTags()
            rebuildActiveAssets()
        }
    }
    @Published var sources: [LibrarySource] = []
    /// Open tabs, their history, cached contents and saving (see
    /// `TabSession`). Its changes republish here.
    let tabSession: TabSession
    private var tabSessionObserver: AnyCancellable?
    var tabs: [LightboxTab] { tabSession.tabs }
    var activeTabID: UUID { tabSession.activeTabID }
    @Published var scrollRestoreGeneration = 0
    @Published var selectedSourceID: LibrarySource.ID = LibrarySource.defaultStartupSource().id
    @Published var temporarySource: LibrarySource?
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
    @Published var searchStatus: LightboxSearchStatus?
    @Published var searchResultFolderEntries: [LibraryFolderEntry]? {
        didSet {
            guard !isApplyingTabState else { return }
            rebuildActiveFolderEntries()
        }
    }
    @Published var searchFocusGeneration = 0
    @Published var goToFolderFocusGeneration = 0
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
    /// Gallery selection, observed by the gallery, the header's selection bar
    /// and the menu commands (see `GallerySelectionState`).
    let selection = GallerySelectionState()
    /// Keyboard focus, observed by the gallery alone.
    let keyboardFocus = GalleryKeyboardFocusState()
    /// Forwards to `selection`. App-state observers are told only when a
    /// selection starts, ends, or turns into or out of a multi-selection.
    var selectedAssetIDs: Set<LightboxAsset.ID> {
        get { selection.assetIDs }
        set {
            guard selection.assetIDs != newValue else { return }
            if min(selection.assetIDs.count, 2) != min(newValue.count, 2) { objectWillChange.send() }
            selection.assetIDs = newValue
        }
    }
    /// Forwards to `selection`; never republishes the app state.
    var selectedAssetID: LightboxAsset.ID? {
        get { selection.assetID }
        set {
            guard selection.assetID != newValue else { return }
            selection.assetID = newValue
        }
    }
    /// Forwards to `selection`; never republishes the app state.
    var selectedGalleryFolderID: LibraryFolderEntry.ID? {
        get { selection.folderID }
        set {
            guard selection.folderID != newValue else { return }
            selection.folderID = newValue
        }
    }
    /// Forwards to `keyboardFocus`; never republishes the app state.
    var galleryKeyboardFocusID: LightboxAsset.ID? {
        get { keyboardFocus.assetID }
        set {
            guard keyboardFocus.assetID != newValue else { return }
            keyboardFocus.assetID = newValue
        }
    }
    /// Forwards to `keyboardFocus`; never republishes the app state.
    var galleryKeyboardScrollGeneration: Int {
        get { keyboardFocus.scrollGeneration }
        set { keyboardFocus.scrollGeneration = newValue }
    }
    /// The open preview's image and geometry, observed by the preview and the
    /// gallery (see `PreviewPresentationState`).
    let preview = PreviewPresentationState()
    /// Forwards to `preview`. App-state observers are told only when a
    /// preview appears or goes away, not when it steps to another image.
    var previewAssetID: LightboxAsset.ID? {
        get { preview.assetID }
        set {
            guard preview.assetID != newValue else { return }
            if (preview.assetID == nil) != (newValue == nil) { objectWillChange.send() }
            preview.assetID = newValue
        }
    }
    /// Forwards to `preview`; never republishes the app state.
    var previewSourceHiddenAssetID: LightboxAsset.ID? {
        get { preview.sourceHiddenAssetID }
        set {
            guard preview.sourceHiddenAssetID != newValue else { return }
            preview.sourceHiddenAssetID = newValue
        }
    }
    /// Forwards to `preview`; never republishes the app state.
    var previewSourceFrame: CGRect? {
        get { preview.sourceFrame }
        set {
            guard preview.sourceFrame != newValue else { return }
            preview.sourceFrame = newValue
        }
    }
    /// Forwards to `preview`; never republishes the app state.
    var previewSessionID: UUID {
        get { preview.sessionID }
        set {
            guard preview.sessionID != newValue else { return }
            preview.sessionID = newValue
        }
    }
    /// Forwards to `preview`; never republishes the app state.
    var previewStepDirection: PreviewDirection? {
        get { preview.stepDirection }
        set {
            guard preview.stepDirection != newValue else { return }
            preview.stepDirection = newValue
        }
    }
    @Published var previewInteractionLayerReady = false
    @Published var comparisonAssets: [LightboxAsset] = []
    /// Images queued for comparison. Its changes republish here, so views
    /// read the tray through the properties below.
    let compareTray = CompareTrayModel()
    private var compareTrayObserver: AnyCancellable?
    var compareTrayAssets: [LightboxAsset] { compareTray.items }
    var compareTrayPulseID: LightboxAsset.ID? { compareTray.pulseID }
    var compareTrayRejectGeneration: Int { compareTray.rejectGeneration }
    @Published var previewPhase: PreviewPhase = .closed
    /// Scan and transfer progress, observed by the header alone (see
    /// `BackgroundActivityState`).
    let activity = BackgroundActivityState()
    /// Forwards to `activity`. App-state observers are told only when a load
    /// starts or finishes, not on every progress tick.
    var libraryLoadingStatus: LibraryLoadingStatus? {
        get { activity.loadingStatus }
        set {
            guard activity.loadingStatus != newValue else { return }
            if (activity.loadingStatus == nil) != (newValue == nil) { objectWillChange.send() }
            activity.loadingStatus = newValue
        }
    }
    /// Mirrors `fileTransfers.progress` into `activity`, like
    /// `libraryLoadingStatus`.
    private(set) var fileTransferProgress: FileTransferProgress? {
        get { activity.fileTransferProgress }
        set {
            guard activity.fileTransferProgress != newValue else { return }
            if (activity.fileTransferProgress == nil) != (newValue == nil) { objectWillChange.send() }
            activity.fileTransferProgress = newValue
        }
    }
    @Published var trashAccessDenied = false
    @Published var colorMode: LightboxColorMode = .system {
        didSet {
            LightboxSettingsStore.saveColorMode(colorMode, defaults: libraryDefaults)
        }
    }
    let glassOpacity = LightboxSettingsStore.defaultGlassOpacity
    @Published var appLanguage: LightboxLanguage = .english {
        didSet {
            LightboxSettingsStore.saveLanguage(appLanguage, defaults: libraryDefaults)
        }
    }

    var previewOpenTask: Task<Void, Never>?
    var previewCloseTask: Task<Void, Never>?
    var previewSourceRevealTask: Task<Void, Never>?
    var previewDimensionTask: Task<Void, Never>?
    var previewDimensionRequestID: UUID?
    var previewKeyboardFocusSessionID: UUID?
    var trashMoveTask: Task<Void, Never>?
    var trashMovingAssetIDs: Set<LightboxAsset.ID> = []
    var pendingTrashOperations = 0
    var fileOperationTask: Task<Void, Never>?
    var renameUndoSteps: [WeakFileUndoStep] = []
    var tagMutationTask: Task<Void, Never>?
    var queuedTagMutations: [TagMutationRequest] = []
    var refreshTask: Task<Void, Never>?
    var libraryLoadTask: Task<Void, Never>?
    var indexWriteTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var searchGeneration = 0
    var isApplyingSearchMetadata = false
    var recursiveSearchScope: RecursiveSearchScope?
    var tabDragHoverTask: Task<Void, Never>?
    var sharingPicker: NSSharingServicePicker?
    var fileActionTask: Task<Void, Never>?
    var renameTask: Task<Void, Never>?
    /// The files the rename sheet is open for.
    @Published var renameRequest: RenameRequest?
    /// The folder the New Folder sheet creates in.
    @Published var folderRenameRequest: FolderRenameRequest?
    @Published var newFolderRequest: NewFolderRequest?
    let quickLook: QuickLookController
    /// What Quick Look was last asked to show.
    var quickLookAssetIDs: [LightboxAsset.ID] = []
    /// A file operation that failed with no sheet open to say so (an undone rename).
    @Published var fileOperationAlert: String?
    var folderPathTask: Task<FolderPathOpenResult, Never>?
    var folderPathRequestID: UUID?
    var pendingPinTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    var sidebarDestinationTask: Task<Void, Never>?
    var refreshSerial = 0
    @Published var sourceStorageClassification: SourceStorageClassification?
    private let trashDirectoryMonitor: DirectoryChangeMonitor
    let indexDatabaseURL: URL
    let sourceIndexWriter: SourceIndexWriter
    /// Covers and image counts for the gallery's folder cells.
    let folderSummaries: FolderSummaryService
    let sidebarNavigation: SidebarNavigationState
    let libraryDefaults: UserDefaults
    var selectionAnchorID: LightboxAsset.ID?
    @Published var cachedActiveAssets: [LightboxAsset] = []
    var cachedActiveAssetIDs: Set<LightboxAsset.ID> = []
    var cachedActiveAssetIDList: [LightboxAsset.ID] = []
    var cachedSearchAssetGroups: [SearchAssetGroup] = []
    /// Whether `cachedSearchAssetGroups` was worked out for search or
    /// subfolder results (it is empty otherwise); nil after a tab's cached
    /// contents came back, so the next rebuild settles it.
    var cachedSearchAssetGroupsAreGrouped: Bool?
    var groupFolderIdentities: [URL: (path: String, title: String)] = [:]
    var groupFolderSources: [LibrarySource] = []
    var groupFolderScope: URL?
    var sortedUnfilteredSnapshot: GalleryContentFilter.SortedSource?

    var activeAssetsRevision = 0
    @Published var cachedActiveFolderEntries: [LibraryFolderEntry] = []
    @Published var cachedLibraryColorTags: [MacColorTag] = []
    var searchResultAssets: [LightboxAsset]?
    var previewAssetSnapshot: LightboxAsset?
    var pendingPreviewStepAssetID: LightboxAsset.ID?
    var storedPreviewSpaceAssetFrames: [LightboxAsset.ID: CGRect] = [:]
    var previewSpaceAssetFrameProvider: (() -> [LightboxAsset.ID: CGRect])?
    /// The corner radius of the thumbnails the provider's frames belong to.
    var previewSourceCornerRadius: CGFloat = RadiusTokens.card
    var previewSpaceAssetFrames: [LightboxAsset.ID: CGRect] {
        previewSpaceAssetFrameProvider?() ?? storedPreviewSpaceAssetFrames
    }
    var isApplyingTabState = false
    var isPerformingHistoryNavigation = false
    var isRestoringFolderSort = false
    var currentScrollAnchorAssetID: LightboxAsset.ID?
    var preservesUnavailableCurrentFolder = false
    var sidebarVolumeObserverTokens: [SidebarVolumeObserverToken] = []
    let previewDimensionProbe: @Sendable (URL) -> CGSize?
    let searchDimensionProbe: @Sendable (URL) -> CGSize?
    let directoryProbe: @Sendable (URL) -> Bool
    let storageClassifier: @Sendable (LibrarySource) -> Bool
    /// Watches the folder on screen; a change schedules a refresh.
    let folderWatcher: FolderWatcher
    /// Reads dimensions and Finder tags for the folder's images in the background.
    let assetMetadata: AssetMetadataLoader
    /// Reads dimensions (and, for recursive results, tags) for search results.
    let searchMetadata: AssetMetadataLoader
    let sidebarDestinationLoader: @Sendable (Set<SidebarLocationID>) -> SidebarDestinationSnapshot
    /// Moves an item to the Trash; where it landed, or nil.
    let systemTrashMover: @Sendable (URL) -> URL?
    /// Puts an item in the Trash back where it came from (Restore, and the
    /// undo of Move to Trash).
    let systemTrashRestorer: @Sendable (URL) async -> TrashRestoreResult
    let finderTagWriter: @Sendable ([String], URL) -> Bool
    /// Opens files in their default applications (non-image files on activation).
    let defaultApplicationOpener: @MainActor ([URL]) -> Void
    /// Where renames register their undo: the main window's, so ⌘Z works.
    let renameUndoManager: @MainActor () -> UndoManager?
    let compareTrayAssetLoader: @Sendable (URL, CGSize, MockPalette) -> LightboxAsset
    /// Copy and move queue; `AppState` applies each request's results.
    let fileTransfers: FileTransferController

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
        systemTrashMover: @escaping @Sendable (URL) -> URL? = {
            LightboxLibraryStore.moveToSystemTrash($0)
        },
        systemTrashRestorer: @escaping @Sendable (URL) async -> TrashRestoreResult = {
            await LightboxLibraryStore.restoreFromSystemTrash($0)
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
        },
        defaultApplicationOpener: @escaping @MainActor ([URL]) -> Void = { urls in
            for url in urls { NSWorkspace.shared.open(url) }
        },
        renameUndoManager: @escaping @MainActor () -> UndoManager? = { NSApp.mainWindow?.undoManager },
        quickLookPanel: QuickLookPanelDriving? = nil
    ) {
        self.indexDatabaseURL = indexDatabaseURL
        sourceIndexWriter = SourceIndexWriter(databaseURL: indexDatabaseURL)
        folderSummaries = FolderSummaryService(indexDatabaseURL: indexDatabaseURL)
        self.libraryDefaults = libraryDefaults
        tabSession = TabSession(defaults: libraryDefaults)
        self.sidebarNavigation = SidebarNavigationState(defaults: libraryDefaults)
        self.previewDimensionProbe = previewDimensionProbe
        self.searchDimensionProbe = searchDimensionProbe
        self.directoryProbe = directoryProbe
        self.storageClassifier = storageClassifier
        folderWatcher = FolderWatcher(makeMonitor: directoryMonitorFactory)
        assetMetadata = AssetMetadataLoader(indexDatabaseURL: indexDatabaseURL)
        searchMetadata = AssetMetadataLoader(indexDatabaseURL: indexDatabaseURL, dimensionProbe: searchDimensionProbe)
        self.sidebarDestinationLoader = sidebarDestinationLoader
        self.systemTrashMover = systemTrashMover
        self.systemTrashRestorer = systemTrashRestorer
        self.finderTagWriter = finderTagWriter
        self.defaultApplicationOpener = defaultApplicationOpener
        self.renameUndoManager = renameUndoManager
        quickLook = QuickLookController(panel: quickLookPanel ?? SystemQuickLookPanel())
        self.compareTrayAssetLoader = compareTrayAssetLoader
        fileTransfers = FileTransferController(executor: fileTransferExecutor)
        colorMode = LightboxSettingsStore.loadColorMode(defaults: libraryDefaults)
        appLanguage = LightboxSettingsStore.loadLanguage(defaults: libraryDefaults)
        sidebarCollapsed = LightboxSettingsStore.loadSidebarCollapsed(defaults: libraryDefaults)
        sidebarWidth = LightboxSettingsStore.loadSidebarWidth(defaults: libraryDefaults)
        sidebarVisibleLocationIDs = LightboxSettingsStore.loadSidebarVisibleLocationIDs(defaults: libraryDefaults)
        showFolderCards = LightboxSettingsStore.loadShowFolderCards(defaults: libraryDefaults)
        galleryViewMode = LightboxSettingsStore.loadViewMode(defaults: libraryDefaults)
        showsHiddenItems = LightboxSettingsStore.loadShowsHiddenItems(defaults: libraryDefaults)
        showsOtherFiles = LightboxSettingsStore.loadShowsOtherFiles(defaults: libraryDefaults)
        trashDirectoryMonitor = DirectoryChangeMonitor(url: LightboxLibraryStore.primarySystemTrashFolder)
        fileTransfers.onProgressChange = { [weak self] in self?.fileTransferProgress = $0 }
        fileTransfers.onResult = { [weak self] in self?.applyFileTransferResult($0) }
        connectLibraryLoading()
        quickLook.onArrow = { [weak self] in self?.followQuickLook($0) }
        compareTrayObserver = compareTray.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tabSessionObserver = tabSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Saved tabs carry the active tab's live scroll anchor and sort.
        tabSession.activeTabOverlay = { [weak self] tab in
            guard let self else { return }
            tab.scrollAnchorAssetID = self.currentScrollAnchorAssetID
            tab.sortField = self.sortField
            tab.sortDirection = self.sortDirection
        }
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
        collapsedGroupFolderPaths = libraryDefaults.stringArray(forKey: Self.collapsedGroupFoldersKey) ?? []
        collapsedGroupFolderSet = Set(collapsedGroupFolderPaths) // didSet does not run in init
        sources = loadedSources
        if loadedSources.contains(where: { sourceMatches($0, resolvedSource) }) {
            temporarySource = restoredTemporarySource
        } else {
            temporarySource = restoredTemporarySource ?? resolvedSource
        }
        tabSession.restore(initialTabs, activeTabID: activeInitialTab.id)
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
        trashDirectoryMonitor.stop()
        refreshTask?.cancel()
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        previewDimensionTask?.cancel()
        trashMoveTask?.cancel()
        fileOperationTask?.cancel()
        tagMutationTask?.cancel()
        libraryLoadTask?.cancel()
        indexWriteTask?.cancel()
        searchTask?.cancel()
        fileActionTask?.cancel()
        renameTask?.cancel()
        folderPathTask?.cancel()
        sidebarDestinationTask?.cancel()
        for pending in pendingPinTasks.values { pending.task.cancel() }
        tabDragHoverTask?.cancel()
        for token in sidebarVolumeObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token.value)
        }
    }

    @Published var recentFolderURLs: [URL] = []
    /// Folders whose group is collapsed in subfolder and search results, by
    /// path, oldest first; kept across folders, tabs and launches.
    @Published var collapsedGroupFolderPaths: [String] = [] {
        didSet { collapsedGroupFolderSet = Set(collapsedGroupFolderPaths) }
    }
    var collapsedGroupFolderSet: Set<String> = []
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

struct AssetMetadataTarget: Sendable {
    var id: LightboxAsset.ID
    var url: URL
    var shouldLoadDimensions: Bool
    var shouldLoadTags: Bool
    /// The file's modification time and size when it was listed; a stored
    /// size is reused only while they still match.
    var signature: FileContentSignature? = nil
    /// Every image, whatever the tag and size limits: the badge and the
    /// Camera Raw filter need all of them.
    var shouldCheckCameraRaw = false
}

struct AssetMetadataUpdate: Sendable {
    var id: LightboxAsset.ID
    var url: URL
    var width: CGFloat?
    var height: CGFloat?
    var tags: [String]?
    var hasCameraRawSettings: Bool? = nil
}

struct LibraryLoadingStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case scanning
        case preparingPreviews
    }

    var phase: Phase
    var processed: Int
    var total: Int?
    /// A recheck of content already on screen (a tab restored from its cache,
    /// a folder whose files changed). It runs like any load but the header
    /// does not announce it.
    var isBackground = false
}

enum PreviewPhase: String {
    case closed
    case opening
    case open
    case closing
}
