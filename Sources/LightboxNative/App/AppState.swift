import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct SearchAssetGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var assets: [LightboxAsset]
}

struct AssetMetadataRefreshPolicy: Equatable {
    static let externalDimensionLimit = 4
    static let externalAssetTagLimit = 12
    static let localStartDelayMilliseconds = 650
    static let externalStartDelayMilliseconds = 1_600

    var usesConservativeExternalLoading: Bool
    var requiresCompleteAssetTags = false

    func dimensionLimit(assetCount: Int) -> Int {
        usesConservativeExternalLoading ? min(assetCount, Self.externalDimensionLimit) : assetCount
    }

    func tagLimit(assetCount: Int) -> Int {
        if !usesConservativeExternalLoading || requiresCompleteAssetTags {
            return assetCount
        }
        return min(assetCount, Self.externalAssetTagLimit)
    }

    var startDelayMilliseconds: Int {
        usesConservativeExternalLoading ? Self.externalStartDelayMilliseconds : Self.localStartDelayMilliseconds
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
    @Published private(set) var sidebarVolumes: [SidebarVolume] = []
    @Published var showFolderCards = LightboxSettingsStore.defaultShowFolderCards {
        didSet {
            LightboxSettingsStore.saveShowFolderCards(showFolderCards)
        }
    }
    @Published var selectedFilter: LibraryFilter = .all {
        didSet {
            guard selectedFilter != oldValue else { return }
            rebuildActiveAssets()
            clearSelection()
            restartLibraryMonitor()
            if selectedFilter == .trash || oldValue == .trash {
                refreshLibrary()
            }
        }
    }
    @Published var galleryLayoutMode: GalleryLayoutMode = .masonry
    @Published var thumbnailWidth: CGFloat = 206
    @Published var assets: [LightboxAsset] = [] {
        didSet {
            rebuildActiveAssets()
        }
    }
    @Published var sources: [LibrarySource] = []
    @Published var selectedSourceID: LibrarySource.ID = LibrarySource.defaultStartupSource().id
    @Published private var temporarySource: LibrarySource?
    @Published var currentFolderURL: URL = LibrarySource.defaultStartupSource().rootURL
    @Published var folderEntries: [LibraryFolderEntry] = []
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            clearSearchResults()
            scheduleSearch()
            rebuildActiveAssets()
        }
    }
    @Published private(set) var searchStatus: LightboxSearchStatus?
    @Published private var searchResultFolderEntries: [LibraryFolderEntry]?
    @Published private(set) var searchFocusGeneration = 0
    @Published var sortField: GallerySortField = .time {
        didSet {
            rebuildActiveAssets()
        }
    }
    @Published var sortDirection: GallerySortDirection = .descending {
        didSet {
            rebuildActiveAssets()
        }
    }
    @Published var selectedAssetIDs: Set<LightboxAsset.ID> = []
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
    @Published private var previewPhase: PreviewPhase = .closed
    @Published var libraryLoadingStatus: LibraryLoadingStatus?
    @Published var trashAccessDenied = false
    @Published var colorMode: LightboxColorMode = .system {
        didSet {
            LightboxSettingsStore.saveColorMode(colorMode)
        }
    }
    @Published var glassOpacity: Double = LightboxSettingsStore.defaultGlassOpacity {
        didSet {
            let clamped = LightboxSettingsStore.clampGlassOpacity(glassOpacity)
            if glassOpacity != clamped {
                glassOpacity = clamped
            }
            LightboxSettingsStore.saveGlassOpacity(clamped)
        }
    }
    @Published var appLanguage: LightboxLanguage = .english {
        didSet {
            LightboxSettingsStore.saveLanguage(appLanguage)
        }
    }

    private var previewOpenTask: Task<Void, Never>?
    private var previewCloseTask: Task<Void, Never>?
    private var previewSourceRevealTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var libraryLoadTask: Task<Void, Never>?
    private var assetMetadataTask: Task<Void, Never>?
    private var indexWriteTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sharingPicker: NSSharingServicePicker?
    private var refreshSerial = 0
    private var libraryDirectoryMonitor: DirectoryChangeMonitor?
    private let trashDirectoryMonitor: DirectoryChangeMonitor
    private let indexStore = LightboxIndexStore()
    private var selectionAnchorID: LightboxAsset.ID?
    @Published private var cachedActiveAssets: [LightboxAsset] = []
    private var searchResultAssets: [LightboxAsset]?
    private var previewAssetSnapshot: LightboxAsset?
    private var previewSpaceAssetFrames: [LightboxAsset.ID: CGRect] = [:]
    private var compareTrayPulseTask: Task<Void, Never>?
    private var compareTrayDragID: LightboxAsset.ID?
    private let compareTrayLimit = 8
    private var sidebarVolumeObserverTokens: [SidebarVolumeObserverToken] = []

    init() {
        ImageCache.shared.removeMemoryObjects(reason: "app-init")
        colorMode = LightboxSettingsStore.loadColorMode()
        glassOpacity = LightboxSettingsStore.loadGlassOpacity()
        appLanguage = LightboxSettingsStore.loadLanguage()
        sidebarCollapsed = LightboxSettingsStore.loadSidebarCollapsed()
        sidebarWidth = LightboxSettingsStore.loadSidebarWidth()
        sidebarVisibleLocationIDs = LightboxSettingsStore.loadSidebarVisibleLocationIDs()
        showFolderCards = LightboxSettingsStore.loadShowFolderCards()
        trashDirectoryMonitor = DirectoryChangeMonitor(url: LightboxLibraryStore.primarySystemTrashFolder)
        let loadedSources = LibrarySourceStore.loadSources()
        let fallbackSource = LibrarySource.defaultStartupSource()
        let savedSourceID = LibrarySourceStore.selectedSourceID(default: fallbackSource.id)
        var resolvedSource = loadedSources.first { $0.id == savedSourceID } ?? fallbackSource
        var restoredTemporarySource: LibrarySource?
        var initialFolderURL = resolvedSource.rootURL

        if let lastSession = LibrarySourceStore.loadLastSession(),
           FileManager.default.fileExists(atPath: lastSession.folderURL.path) {
            if let matchedSource = loadedSources.first(where: {
                $0.id == lastSession.sourceID ||
                $0.rootURL.standardizedFileURL.path == lastSession.sourceRootURL.path
            }) {
                resolvedSource = matchedSource
                initialFolderURL = lastSession.folderURL
            } else if lastSession.sourceKind == .external,
                      FileManager.default.fileExists(atPath: lastSession.sourceRootURL.path) {
                let temporary = LibrarySource(
                    id: lastSession.sourceID,
                    name: lastSession.sourceName,
                    rootURL: lastSession.sourceRootURL,
                    kind: .external
                )
                restoredTemporarySource = temporary
                resolvedSource = temporary
                initialFolderURL = lastSession.folderURL
            }
        }

        sources = loadedSources
        if loadedSources.contains(where: { sourceMatches($0, resolvedSource) }) {
            temporarySource = restoredTemporarySource
        } else {
            temporarySource = restoredTemporarySource ?? resolvedSource
        }
        selectedSourceID = resolvedSource.id
        currentFolderURL = initialFolderURL
        LibrarySourceStore.saveSelectedSourceID(resolvedSource.id)
        saveCurrentFolderSession()
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
        libraryLoadTask?.cancel()
        assetMetadataTask?.cancel()
        indexWriteTask?.cancel()
        searchTask?.cancel()
        compareTrayPulseTask?.cancel()
        for token in sidebarVolumeObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token.value)
        }
    }

    var activeAssets: [LightboxAsset] {
        cachedActiveAssets
    }

    var isViewingTrash: Bool {
        selectedFilter == .trash
    }

    var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeFolderEntries: [LibraryFolderEntry] {
        guard !isViewingTrash else { return [] }
        guard hasSearchQuery else { return sortedFolderEntries(folderEntries) }

        let query = LightboxSearchQuery.parse(searchText)
        guard !query.isEmpty else { return sortedFolderEntries(folderEntries) }

        if let searchResultFolderEntries {
            return sortedFolderEntries(searchResultFolderEntries)
        }

        return sortedFolderEntries(folderEntries.filter(query.matches))
    }

    var searchAssetGroups: [SearchAssetGroup] {
        let activeAssets = activeAssets
        guard hasSearchQuery, !activeAssets.isEmpty
        else {
            return [
                SearchAssetGroup(
                    id: currentFolderURL.standardizedFileURL.path,
                    title: currentPathTitle,
                    assets: activeAssets
                )
            ]
        }

        var grouped: [(path: String, title: String, assets: [LightboxAsset])] = []
        var indexByPath: [String: Int] = [:]
        for asset in activeAssets {
            let folderURL = asset.sourceURL?.deletingLastPathComponent().standardizedFileURL ?? currentFolderURL
            let path = folderURL.path
            if let index = indexByPath[path] {
                grouped[index].assets.append(asset)
            } else {
                indexByPath[path] = grouped.count
                grouped.append((path, searchGroupTitle(for: folderURL), [asset]))
            }
        }

        return grouped.map {
            SearchAssetGroup(id: $0.path, title: $0.title, assets: $0.assets)
        }
    }

    func focusSearch() {
        searchFocusGeneration += 1
    }

    private func searchGroupTitle(for folderURL: URL) -> String {
        if let source = bestSource(containing: folderURL) {
            let relativePath = folderURL.relativePath(from: source.rootURL)
            if relativePath.isEmpty {
                return source.displayName
            }
            return relativePath
        }

        return folderURL.lastPathComponent.isEmpty ? folderURL.path : folderURL.lastPathComponent
    }

    var selectedSource: LibrarySource? {
        if let temporarySource, temporarySource.id == selectedSourceID {
            return temporarySource
        }

        return sources.first { $0.id == selectedSourceID }
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
        sidebarLocations = Self.makeSidebarLocations(visibleLocationIDs: sidebarVisibleLocationIDs)
        sidebarVolumes = Self.makeSidebarVolumes(visibleLocationIDs: sidebarVisibleLocationIDs)
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

    private static func makeSidebarLocations(visibleLocationIDs: Set<SidebarLocationID>) -> [SidebarLocationID] {
        SidebarLocationID.allCases.filter { location in
            visibleLocationIDs.contains(location) && location.defaultURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
    }

    private static func makeSidebarVolumes(visibleLocationIDs: Set<SidebarLocationID>) -> [SidebarVolume] {
        guard visibleLocationIDs.contains(.volumes) else { return [] }
        let keys: [URLResourceKey] = [.volumeNameKey, .isVolumeKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.path != "/" else { return nil }
            let name = (try? standardizedURL.resourceValues(forKeys: [.volumeNameKey]).volumeName)
                ?? standardizedURL.lastPathComponent
            guard !name.isEmpty else { return nil }
            return SidebarVolume(url: standardizedURL, displayName: name)
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
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
        guard !isViewingTrash else { return false }
        let currentPath = currentFolderURL.standardizedFileURL.path
        let parentPath = currentFolderURL.deletingLastPathComponent().standardizedFileURL.path
        return currentPath != parentPath
    }

    var canPinCurrentPath: Bool {
        guard !isViewingTrash else { return false }
        let currentPath = currentFolderURL.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: currentPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        return !sources.contains {
            $0.rootURL.standardizedFileURL.path == currentPath
        }
    }

    func openParentFolder() {
        guard canOpenParentFolder else { return }
        openFolderURL(currentFolderURL.deletingLastPathComponent())
    }

    private func volumeTitle() -> String {
        let volumeName = (try? currentFolderURL.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
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
        MacColorTag.all.filter { tag in
            assets.contains { asset in
                !asset.isDeleted && asset.tags.contains(tag.name)
            }
        }
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
            if selectedAssetIDs.count == 1, selectedAssetIDs.contains(asset.id) {
                clearSelection()
                showPreview(for: asset, sourceFrame: sourceFrame)
            } else {
                replaceSelection(with: [asset.id], primary: asset.id, anchor: asset.id)
            }
            return
        }

        showPreview(for: asset, sourceFrame: sourceFrame)
    }

    func updatePreviewSpaceAssetFrames(_ frames: [LightboxAsset.ID: CGRect]) {
        previewSpaceAssetFrames = frames
    }

    func previewSpaceFrame(for assetID: LightboxAsset.ID) -> CGRect? {
        previewSpaceAssetFrames[assetID]
    }

    private func previewSpaceAssetHit(at point: CGPoint?) -> (asset: LightboxAsset, frame: CGRect)? {
        guard let point else { return nil }
        for asset in activeAssets {
            guard let frame = previewSpaceAssetFrames[asset.id],
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

        guard let nearest = activeAssets.compactMap({ asset -> (LightboxAsset, CGRect, CGFloat)? in
            guard let frame = previewSpaceAssetFrames[asset.id] else { return nil }
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

    func replaceSelection(with ids: Set<LightboxAsset.ID>) {
        replaceSelection(with: ids, primary: firstVisibleID(in: ids), anchor: firstVisibleID(in: ids))
    }

    func clearSelection() {
        selectedAssetIDs = []
        selectedAssetID = nil
        selectionAnchorID = nil
    }

    func toggleGalleryLayoutMode() {
        galleryLayoutMode = galleryLayoutMode.next
    }

    func chooseSource(_ sourceID: LibrarySource.ID) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        temporarySource = nil
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
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            Self.logger.error("sidebar folder open rejected missing-or-not-directory path=\(standardizedURL.path, privacy: .public)")
            return
        }

        if let source = bestSource(containing: standardizedURL) {
            let pinnedSource = sources.first { sourceMatches($0, source) }
            let sourceToActivate = pinnedSource ?? source
            temporarySource = pinnedSource == nil ? source : nil
            Self.logger.info("sidebar folder open requested path=\(standardizedURL.path, privacy: .public) source=\(sourceToActivate.id, privacy: .public) pinned=\(pinnedSource != nil, privacy: .public)")
            activateSource(sourceToActivate, initialFolderURL: standardizedURL)
            return
        }

        let source = LibrarySourceStore.makeExternalSource(rootURL: standardizedURL)
        Self.logger.info("sidebar folder open requested path=\(standardizedURL.path, privacy: .public) source=\(source.id, privacy: .public) pinned=false")
        chooseTemporarySource(source)
    }

    func openTrashFromSidebar() {
        selectedFilter = .trash
        searchText = ""
        clearSelection()
    }

    private func chooseTemporarySource(_ source: LibrarySource) {
        temporarySource = source
        indexStore.upsertSource(source)
        activateSource(source)
    }

    private func activateSource(_ source: LibrarySource, initialFolderURL: URL? = nil) {
        let previousSourceID = selectedSourceID
        selectedSourceID = source.id
        LibrarySourceStore.saveSelectedSourceID(source.id)
        selectedFilter = .all
        currentFolderURL = initialFolderURL?.standardizedFileURL ?? source.rootURL
        saveCurrentFolderSession()
        searchText = ""
        clearSelection()
        if previousSourceID != source.id {
            SidebarFolderTagCache.shared.clear()
        }
        ImageCache.shared.removeSourceMemoryObjects(reason: "choose-source")
        restartLibraryMonitor()
        refreshLibrary()
    }

    func addExternalSource() {
        let panel = NSOpenPanel()
        panel.title = localized(.openFolder)
        panel.prompt = localized(.openFolder).replacingOccurrences(of: "...", with: "")
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
        pinFolder(currentFolderURL, selectPinnedFolder: true)
    }

    func unpinSource(_ sourceID: LibrarySource.ID) {
        guard let source = sources.first(where: { $0.id == sourceID }),
              !source.isLocalLibrary
        else {
            return
        }

        let wasSelected = selectedSourceID == sourceID
        sources.removeAll { $0.id == sourceID }
        LibrarySourceStore.saveExternalSources(sources)
        if wasSelected {
            temporarySource = source
            LibrarySourceStore.saveSelectedSourceID(source.id)
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
        LibrarySourceStore.saveExternalSources(sources)
        indexStore.upsertSource(source)
        if temporarySource?.rootURL.standardizedFileURL.path == source.rootURL.standardizedFileURL.path {
            temporarySource = nil
        }
        if selectedSourceID == source.id {
            LibrarySourceStore.saveSelectedSourceID(source.id)
        }
        if selectPinnedFolder {
            chooseSource(source.id)
        }
    }

    private func pinFolder(_ url: URL, selectPinnedFolder: Bool) {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return
        }

        if let existing = sources.first(where: { $0.rootURL.standardizedFileURL.path == standardizedURL.path }) {
            if selectPinnedFolder {
                chooseSource(existing.id)
            }
            return
        }

        let source = LibrarySourceStore.makeExternalSource(rootURL: standardizedURL)
        sources.append(source)
        LibrarySourceStore.saveExternalSources(sources)
        indexStore.upsertSource(source)
        if temporarySource?.rootURL.standardizedFileURL.path == standardizedURL.path {
            temporarySource = nil
        }
        if selectPinnedFolder {
            chooseSource(source.id)
        }
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
        guard !isViewingTrash, let selectedSource else { return }
        LibrarySourceStore.saveLastSession(source: selectedSource, folderURL: currentFolderURL)
    }

    func openFolder(_ folder: LibraryFolderEntry) {
        Self.logger.info("folder open requested source=\(folder.sourceID, privacy: .public) selectedSource=\(self.selectedSourceID, privacy: .public) path=\(folder.url.path, privacy: .public)")
        let standardizedURL = folder.url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            Self.logger.error("folder open rejected missing-or-not-directory path=\(standardizedURL.path, privacy: .public)")
            return
        }

        guard folder.sourceID == selectedSourceID else {
            guard let source = sources.first(where: { $0.id == folder.sourceID }) else {
                Self.logger.error("folder open rejected source mismatch folderSource=\(folder.sourceID, privacy: .public) selectedSource=\(self.selectedSourceID, privacy: .public) path=\(folder.url.path, privacy: .public)")
                return
            }
            temporarySource = nil
            selectedSourceID = source.id
            LibrarySourceStore.saveSelectedSourceID(source.id)
            selectedFilter = .all
            currentFolderURL = standardizedURL
            saveCurrentFolderSession()
            clearSearchForNavigation()
            clearSelection()
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
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            Self.logger.error("folder open rejected missing-or-not-directory path=\(standardizedURL.path, privacy: .public)")
            return
        }

        selectedFilter = .all
        currentFolderURL = standardizedURL
        saveCurrentFolderSession()
        clearSearchForNavigation()
        clearSelection()
        ImageCache.shared.removeThumbnailMemoryObjects(reason: "open-folder")
        restartLibraryMonitor()
        refreshLibrary()
    }

    private func clearSearchForNavigation() {
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
        guard var target = asset ?? selectedAsset ?? activeAssets.first else {
            Self.previewLogger.info("preview show ignored reason=no-target phase=\(self.previewPhase.rawValue, privacy: .public)")
            return
        }
        target = resolvedPreviewTarget(target, sourceFrame: sourceFrame)

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

    private func resolvedPreviewTarget(_ asset: LightboxAsset, sourceFrame: CGRect?) -> LightboxAsset {
        guard needsPreviewDimensionResolve(asset),
              let url = asset.sourceURL
        else {
            return asset
        }

        if let dimensions = ImageProbe.dimensions(for: url),
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

    func addCompareTrayItem(for url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        if let existing = assets.first(where: { $0.sourceURL?.standardizedFileURL.path == standardizedPath }) {
            addToCompareTray(existing)
            return
        }

        let fallbackSize = MockLibrary.importFallbackSizes[compareTrayAssets.count % MockLibrary.importFallbackSizes.count]
        let size = ImageProbe.dimensions(for: url) ?? fallbackSize
        let asset = LightboxAsset(
            originalName: url.lastPathComponent,
            width: size.width,
            height: size.height,
            tags: FinderTagStore.colorTags(for: url),
            sourceURL: url,
            addedAt: LocalImageSource.addedDate(for: url) ?? .now,
            fileSize: LocalImageSource.fileSize(for: url),
            palette: MockPalette.imported[compareTrayAssets.count % MockPalette.imported.count],
            metadataLoaded: true
        )
        addToCompareTray(asset)
    }

    func handleCompareTrayDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { [weak self] in
            for provider in providers {
                guard let url = await Self.fileURL(from: provider) else { continue }
                await MainActor.run {
                    self?.addCompareTrayItem(for: url)
                }
            }
            await MainActor.run {
                self?.compareTrayDragID = nil
            }
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
        previewSourceRevealTask?.cancel()
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
        let currentID = previewAssetID ?? selectedAssetID
        let currentIndex = currentID.flatMap { id in visible.firstIndex { $0.id == id } } ?? 0
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = (currentIndex - 1 + visible.count) % visible.count
        case .next:
            nextIndex = (currentIndex + 1) % visible.count
        }
        let nextAsset = resolvedPreviewTarget(visible[nextIndex], sourceFrame: nil)
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
        var removedIDs = Set<LightboxAsset.ID>()

        for asset in targetAssets where !asset.isDeleted {
            guard let sourceURL = asset.sourceURL else { continue }
            if LightboxLibraryStore.moveToSystemTrash(sourceURL) {
                removedIDs.insert(asset.id)
            } else {
                Self.logger.error("system trash failed id=\(asset.id, privacy: .public) path=\(sourceURL.path, privacy: .public)")
            }
        }

        guard !removedIDs.isEmpty else { return }

        assets.removeAll { removedIDs.contains($0.id) }
        searchResultAssets?.removeAll { removedIDs.contains($0.id) }
        cachedActiveAssets.removeAll { removedIDs.contains($0.id) }
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
        update(asset) { item in
            var nextTags = item.tags
            if !nextTags.contains(tag) {
                nextTags.append(tag)
            }
            writeColorTags(nextTags, to: &item)
        }
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
        let removesTag = !targetAssets.isEmpty && targetAssets.allSatisfy { $0.tags.contains(tag) }
        let shouldClearCurrentFilter = shouldClearTagFilterAfterRemoving(tag, targetIDs: targetIDs)
        var nextTagsByID: [LightboxAsset.ID: [String]] = [:]

        for asset in targetAssets {
            var nextTags = asset.tags
            if removesTag {
                nextTags.removeAll { $0 == tag }
            } else if !nextTags.contains(tag) {
                nextTags.append(tag)
            }

            let sortedTags = MacColorTag.sort(nextTags.filter(MacColorTag.isColorTag))
            if let url = asset.sourceURL,
               !FinderTagStore.setColorTags(sortedTags, for: url) {
                continue
            }
            nextTagsByID[asset.id] = sortedTags
        }

        applyTagCopies(nextTagsByID)
        clearCurrentTagFilterIfNeeded(
            shouldClearCurrentFilter,
            removedTag: tag,
            targetAssets: targetAssets,
            updatedTagsByID: nextTagsByID
        )
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

        let removesTag = selectedAssets.allSatisfy { $0.tags.contains(tag) }
        let shouldClearCurrentFilter = shouldClearTagFilterAfterRemoving(tag, targetIDs: targetIDs)
        var nextTagsByID: [LightboxAsset.ID: [String]] = [:]

        for asset in selectedAssets {
            var nextTags = asset.tags
            if removesTag {
                nextTags.removeAll { $0 == tag }
            } else if !nextTags.contains(tag) {
                nextTags.append(tag)
            }

            let sortedTags = MacColorTag.sort(nextTags.filter(MacColorTag.isColorTag))
            if let url = asset.sourceURL,
               !FinderTagStore.setColorTags(sortedTags, for: url) {
                continue
            }
            nextTagsByID[asset.id] = sortedTags
        }

        applyTagCopies(nextTagsByID)
        clearCurrentTagFilterIfNeeded(
            shouldClearCurrentFilter,
            removedTag: tag,
            targetAssets: selectedAssets,
            updatedTagsByID: nextTagsByID
        )
    }

    func revealInFinder(_ asset: LightboxAsset) {
        guard let url = asset.sourceURL else { return }
        revealURLInFinder(url)
    }

    func openWithApplication(_ asset: LightboxAsset, applicationURL: URL?) {
        let targets = operationTargetAssets(fallback: asset)
        let urls = existingFileURLs(for: targets)
        guard !urls.isEmpty else { return }

        if let applicationURL {
            open(urls, with: applicationURL)
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

        open(urls, with: applicationURL)
    }

    private func operationTargetAssets(fallback asset: LightboxAsset) -> [LightboxAsset] {
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(asset.id) {
            let selectedIDs = selectedAssetIDs
            return activeAssets.filter { selectedIDs.contains($0.id) }
        }

        return [asset]
    }

    private func existingFileURLs(for assets: [LightboxAsset]) -> [URL] {
        assets.compactMap { asset in
            guard let url = asset.sourceURL,
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return nil
            }

            return url
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
        let path = url.standardizedFileURL.path
        return sources.contains { source in
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
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToClipboard(_ asset: LightboxAsset) {
        let urls = existingFileURLs(for: operationTargetAssets(fallback: asset))
        guard !urls.isEmpty else { return }
        ImageClipboardWriter.copyImages(at: urls)
    }

    func share(_ asset: LightboxAsset, from view: NSView) {
        let urls = existingFileURLs(for: operationTargetAssets(fallback: asset))
        guard !urls.isEmpty else { return }

        let picker = NSSharingServicePicker(items: urls)
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func refreshLibrary() {
        let cancelledRefreshTask = refreshTask != nil
        let cancelledLoadTask = libraryLoadTask != nil
        let cancelledMetadataTask = assetMetadataTask != nil
        refreshTask?.cancel()
        libraryLoadTask?.cancel()
        assetMetadataTask?.cancel()
        refreshSerial += 1
        let refreshID = refreshSerial
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
        if !FileManager.default.fileExists(atPath: currentFolderURL.path) {
            Self.logger.info("refresh[\(refreshID)] current folder missing, fallback=\(source.rootURL.path, privacy: .public)")
            currentFolderURL = source.rootURL
            saveCurrentFolderSession()
        }

        let folderURL = currentFolderURL
        let hasCachedVisibleSnapshot = applyCachedVisibleSnapshotIfAvailable(source: source, folderURL: folderURL, refreshID: refreshID)
        let usesConservativeExternalLoading = source.usesConservativeExternalLoading
        let refreshPolicy = LibraryRefreshPolicy(
            usesConservativeExternalLoading: usesConservativeExternalLoading,
            hasCachedVisibleSnapshot: hasCachedVisibleSnapshot
        )
        libraryLoadTask = Task.detached(priority: .userInitiated) { [weak self, source] in
            let scanDelayMilliseconds = refreshPolicy.scanStartDelayMilliseconds
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
            let cachedDimensions = LightboxIndexStore().cachedDimensions(
                sourceID: source.id,
                parentPath: folderURL.path
            )
            let directorySnapshot = LocalImageSource.loadFolderSnapshot(
                in: folderURL,
                sourceID: source.id,
                rootURL: source.rootURL,
                probeMetadata: false,
                probeFolderTags: !usesConservativeExternalLoading,
                initialMetadataLimit: usesConservativeExternalLoading ? 0 : 120,
                cachedDimensions: cachedDimensions
            )
            let folders = directorySnapshot.folders
            let snapshot = directorySnapshot.assets

            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      !self.isViewingTrash,
                      self.selectedSourceID == source.id,
                      self.currentFolderURL.standardizedFileURL.path == folderURL.standardizedFileURL.path
                else {
                    Self.logger.info("refresh[\(refreshID)] ignored cancelled=\(Task.isCancelled) folder=\(folderURL.path, privacy: .public)")
                    return
                }

                let applyStartedAt = Date()
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
                    requiresCompleteAssetTags: requiresCompleteAssetTags
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
                self.scheduleSearch()
                Self.logger.info("refresh[\(refreshID)] apply complete applyTotal=\(Date().timeIntervalSince(applyStartedAt), format: .fixed(precision: 2))s folderEntries=\(self.folderEntries.count) storeAssets=\(self.assets.count) visibleSnapshotAssets=\(snapshot.count)")
            }
        }
    }

    private func applyCachedVisibleSnapshotIfAvailable(
        source: LibrarySource,
        folderURL: URL,
        refreshID: Int
    ) -> Bool {
        if let snapshot = indexStore.cachedVisibleSnapshot(source: source, folderURL: folderURL) {
            folderEntries = snapshot.folders
            mergeLibrarySnapshot(snapshot.assets)
            Self.logger.info("refresh[\(refreshID)] cached snapshot applied folders=\(snapshot.folders.count) assets=\(snapshot.assets.count) folder=\(folderURL.path, privacy: .public)")
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
        libraryDirectoryMonitor?.stop()
        let monitoredURL = isViewingTrash ? LightboxLibraryStore.primarySystemTrashFolder : currentFolderURL
        if !isViewingTrash, selectedSource?.usesConservativeExternalLoading == true {
            libraryDirectoryMonitor = nil
            Self.logger.info("monitor skipped external source path=\(monitoredURL.path, privacy: .public)")
            return
        }

        Self.logger.info("monitor restart path=\(monitoredURL.path, privacy: .public) trash=\(self.isViewingTrash)")
        let monitor = DirectoryChangeMonitor(url: monitoredURL)
        libraryDirectoryMonitor = monitor
        monitor.start { [weak self] in
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

        assetMetadataTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .milliseconds(startDelayMilliseconds))
            guard !Task.isCancelled else { return }
            let startedAt = Date()
            let dimensionIndexStore = LightboxIndexStore()
            var batch: [AssetMetadataUpdate] = []
            var processedCount = 0
            let progressInterval = 160

            for target in targets {
                guard !Task.isCancelled else {
                    Self.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(targets.count)")
                    return
                }

                let metadata = autoreleasepool {
                    (
                        size: target.shouldLoadDimensions ? ImageProbe.dimensions(for: target.url) : nil,
                        tags: target.shouldLoadTags ? FinderTagStore.colorTags(for: target.url) : nil
                    )
                }
                guard !Task.isCancelled else {
                    Self.logger.info("refresh[\(refreshID)] metadata cancelled processed=\(processedCount)/\(targets.count)")
                    return
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

                if batch.count >= 160 || processedCount % progressInterval == 0 {
                    let updates = batch
                    batch.removeAll(keepingCapacity: true)
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

                if processedCount % 80 == 0 {
                    try? await Task.sleep(for: .milliseconds(6))
                }
            }

            if !batch.isEmpty || processedCount > 0 {
                dimensionIndexStore.updateCachedMetadata(
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

    private func scheduleVisibleSnapshotIndex(
        source: LibrarySource,
        folderURL: URL,
        folders: [LibraryFolderEntry],
        assets: [LightboxAsset],
        refreshID: Int
    ) {
        indexWriteTask?.cancel()
        indexWriteTask = Task.detached(priority: .utility) {
            let startedAt = Date()
            let store = LightboxIndexStore()
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
        searchText expectedSearchText: String
    ) {
        guard !updates.isEmpty,
              !isViewingTrash,
              selectedSourceID == sourceID,
              currentFolderURL.standardizedFileURL.path == folderPath,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == expectedSearchText
        else {
            return
        }

        let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        var didChange = false

        if var searchResultAssets {
            for index in searchResultAssets.indices {
                guard let update = updatesByID[searchResultAssets[index].id],
                      let width = update.width,
                      let height = update.height
                else {
                    continue
                }
                searchResultAssets[index].width = width
                searchResultAssets[index].height = height
                searchResultAssets[index].metadataLoaded = true
                didChange = true
            }
            if didChange {
                self.searchResultAssets = searchResultAssets
            }
        }

        var assetsChanged = false
        for index in assets.indices {
            guard let update = updatesByID[assets[index].id],
                  let width = update.width,
                  let height = update.height
            else {
                continue
            }
            assets[index].width = width
            assets[index].height = height
            assets[index].metadataLoaded = true
            assetsChanged = true
        }

        for index in cachedActiveAssets.indices {
            guard let update = updatesByID[cachedActiveAssets[index].id],
                  let width = update.width,
                  let height = update.height
            else {
                continue
            }
            cachedActiveAssets[index].width = width
            cachedActiveAssets[index].height = height
            cachedActiveAssets[index].metadataLoaded = true
            didChange = true
        }

        if let previewAssetSnapshot,
           let update = updatesByID[previewAssetSnapshot.id],
           let width = update.width,
           let height = update.height {
            self.previewAssetSnapshot?.width = width
            self.previewAssetSnapshot?.height = height
            self.previewAssetSnapshot?.metadataLoaded = true
            didChange = true
        }

        if assetsChanged || didChange {
            rebuildActiveAssets()
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
        let filtered: [LightboxAsset] = switch selectedFilter {
        case .all:
            sourceAssets.filter { !$0.isDeleted }
        case .tag(let tag):
            sourceAssets.filter { !$0.isDeleted && $0.tags.contains(tag) }
        case .trash:
            sourceAssets.filter(\.isDeleted)
        }

        guard !query.isEmpty else {
            cachedActiveAssets = sortedAssets(filtered)
            return
        }

        cachedActiveAssets = sortedAssets(filtered.filter(query.matches))
    }

    private var searchResultAssetsForActiveQuery: [LightboxAsset]? {
        guard hasSearchQuery,
              !isViewingTrash,
              let searchResultAssets
        else {
            return nil
        }
        return searchResultAssets
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        clearSearchResults()
        searchStatus = nil

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty,
              !isViewingTrash,
              let source = selectedSource
        else {
            return
        }

        let query = LightboxSearchQuery.parse(trimmedSearchText)
        guard !query.isEmpty else { return }

        let searchFolder = currentFolderURL
        let sourceID = source.id
        let sourceRootURL = source.rootURL
        let currentFolderPath = currentFolderURL.standardizedFileURL.path
        searchStatus = LightboxSearchStatus(isSearching: true)

        searchTask = Task.detached(priority: .utility) { [weak self, query, searchFolder, sourceID, sourceRootURL, currentFolderPath, trimmedSearchText] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            let result = LocalImageSource.searchAssets(
                in: searchFolder,
                sourceID: sourceID,
                rootURL: sourceRootURL,
                query: query,
                recursive: true
            )

            let didApplySearchResults = await MainActor.run { () -> Bool in
                guard let self,
                      !Task.isCancelled,
                      self.selectedSourceID == sourceID,
                      self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSearchText,
                      self.currentFolderURL.standardizedFileURL.path == currentFolderPath
                else {
                    return false
                }

                self.searchResultAssets = result.assets
                self.searchResultFolderEntries = result.folders
                self.searchStatus = LightboxSearchStatus(isSearching: false, limitReached: result.limitReached)
                self.rebuildActiveAssets()
                return true
            }
            guard didApplySearchResults else { return }

            let metadataTargets = result.assets
                .prefix(Self.searchMetadataRefreshLimit)
                .compactMap { asset -> AssetMetadataTarget? in
                    guard !asset.metadataLoaded, let url = asset.sourceURL else { return nil }
                    return AssetMetadataTarget(
                        id: asset.id,
                        url: url,
                        shouldLoadDimensions: true,
                        shouldLoadTags: false
                    )
                }
            guard !metadataTargets.isEmpty else { return }

            let metadataStore = LightboxIndexStore()
            var batch: [AssetMetadataUpdate] = []
            var processedCount = 0
            for target in metadataTargets {
                guard !Task.isCancelled else { return }
                guard let size = ImageProbe.dimensions(for: target.url) else { continue }
                processedCount += 1
                batch.append(AssetMetadataUpdate(
                    id: target.id,
                    url: target.url,
                    width: size.width,
                    height: size.height,
                    tags: nil
                ))

                if batch.count >= 48 {
                    let updates = batch
                    batch.removeAll(keepingCapacity: true)
                    metadataStore.updateCachedMetadata(
                        sourceID: sourceID,
                        updates: updates.map {
                            IndexedAssetMetadata(
                                url: $0.url,
                                width: $0.width,
                                height: $0.height,
                                tags: nil
                            )
                        }
                    )
                    await MainActor.run {
                        self?.applySearchResultMetadataUpdates(
                            updates,
                            sourceID: sourceID,
                            folderPath: currentFolderPath,
                            searchText: trimmedSearchText
                        )
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
                        tags: nil
                    )
                }
            )
            await MainActor.run {
                self?.applySearchResultMetadataUpdates(
                    batch,
                    sourceID: sourceID,
                    folderPath: currentFolderPath,
                    searchText: trimmedSearchText
                )
            }
        }
    }

    private func clearSearchResults() {
        searchResultAssets = nil
        searchResultFolderEntries = nil
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
        let assetIDs = Set((assets + (searchResultAssets ?? []) + cachedActiveAssets).map(\.id))

        if let selectedAssetID, !assetIDs.contains(selectedAssetID) {
            self.selectedAssetID = nil
        }

        selectedAssetIDs = selectedAssetIDs.filter { assetIDs.contains($0) }
        if let selectionAnchorID, !assetIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = firstVisibleID(in: selectedAssetIDs)
        }

        if let previewAssetID, !assetIDs.contains(previewAssetID) {
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

    private func shouldClearTagFilterAfterRemoving(
        _ tag: String,
        targetIDs: Set<LightboxAsset.ID>
    ) -> Bool {
        guard selectedFilter == .tag(tag), !activeAssets.isEmpty else { return false }
        return activeAssets.allSatisfy { targetIDs.contains($0.id) }
    }

    private func clearCurrentTagFilterIfNeeded(
        _ shouldClear: Bool,
        removedTag tag: String,
        targetAssets: [LightboxAsset],
        updatedTagsByID: [LightboxAsset.ID: [String]]
    ) {
        guard shouldClear,
              !targetAssets.isEmpty,
              targetAssets.allSatisfy({ updatedTagsByID[$0.id]?.contains(tag) == false })
        else {
            return
        }

        selectedFilter = .all
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

    private func writeColorTags(_ tags: [String], to asset: inout LightboxAsset) {
        let sortedTags = MacColorTag.sort(tags.filter(MacColorTag.isColorTag))
        guard let url = asset.sourceURL else {
            asset.tags = sortedTags
            return
        }

        if FinderTagStore.setColorTags(sortedTags, for: url) {
            asset.tags = sortedTags
        }
    }

    private func sourceKey(for asset: LightboxAsset) -> String? {
        asset.sourceURL?.standardizedFileURL.path
    }

    private func toggleSelection(_ asset: LightboxAsset) {
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
        let visibleIDs = activeAssets.map(\.id)
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
        selectedAssetIDs = ids
        selectedAssetID = primary
        selectionAnchorID = ids.isEmpty ? nil : anchor
    }

    private func firstVisibleID(in ids: Set<LightboxAsset.ID>) -> LightboxAsset.ID? {
        activeAssets.first { ids.contains($0.id) }?.id
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
