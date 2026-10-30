import AppKit
import SwiftUI

enum GalleryScrollDirection: Equatable {
    case stationary
    case up
    case down
}

struct GalleryImagePriorityPlanner {
    static let maxPrioritizedAssetCount = 36

    static func displayQuality(
        baseQuality: ImageCacheQuality,
        isPrioritized: Bool,
        prefersFastRawThumbnails: Bool = false,
        permitsFullThumbnailPromotion: Bool = true,
        isSettledVisible: Bool = false,
        requiredPixelSize: CGFloat = .infinity
    ) -> ImageCacheQuality {
        let quality = sharpQuality(
            baseQuality: baseQuality, isPrioritized: isPrioritized,
            prefersFastRawThumbnails: prefersFastRawThumbnails,
            permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
            isSettledVisible: isSettledVisible, requiredPixelSize: requiredPixelSize
        )
        // Cards scrolling past or waiting offscreen show whatever preview the
        // file embeds (cheap, even over a network share); visible cards get a
        // sharp image once scrolling settles. A sharper image already decoded
        // keeps showing, since the cache serves the best tier it has.
        guard !isSettledVisible, quality == .thumbnailFast || quality == .thumbnailBalanced else { return quality }
        return .thumbnailEmbedded
    }

    private static func sharpQuality(
        baseQuality: ImageCacheQuality,
        isPrioritized: Bool,
        prefersFastRawThumbnails: Bool,
        permitsFullThumbnailPromotion: Bool,
        isSettledVisible: Bool,
        requiredPixelSize: CGFloat
    ) -> ImageCacheQuality {
        // Storage and library size limit work while moving, not final on-screen quality.
        // Keep sufficient decoded pixels while moving and at rest. Small cards
        // must not repeatedly alternate between 480- and 1024-pixel requests.
        if requiredPixelSize <= CGFloat(baseQuality.maxPixelSize) { return baseQuality }
        if isSettledVisible {
            return requiredPixelSize <= CGFloat(ImageCacheQuality.thumbnailBalanced.maxPixelSize)
                ? .thumbnailBalanced : .thumbnail
        }
        guard isPrioritized else { return baseQuality }
        guard permitsFullThumbnailPromotion else {
            switch baseQuality {
            case .thumbnailEmbedded, .thumbnailFast:
                return .thumbnailBalanced
            case .thumbnailBalanced:
                return .thumbnailBalanced
            case .thumbnail, .preview, .comparison:
                return baseQuality
            }
        }
        guard prefersFastRawThumbnails else { return .thumbnail }

        switch baseQuality {
        case .thumbnailEmbedded, .thumbnailFast:
            return .thumbnailBalanced
        case .thumbnailBalanced:
            return .thumbnailBalanced
        case .thumbnail, .preview, .comparison:
            return baseQuality
        }
    }

    static func isVisible(_ frame: CGRect?, viewportHeight: CGFloat) -> Bool {
        guard let frame, viewportHeight > 0 else { return false }
        return frame.maxY > 0 && frame.minY < viewportHeight
    }

    static func prioritizedAssetIDs(
        activeAssets: [LightboxAsset],
        assetFrames: [LightboxAsset.ID: CGRect],
        viewportHeight: CGFloat,
        scrollDirection: GalleryScrollDirection,
        maxPrioritizedAssetCount: Int = Self.maxPrioritizedAssetCount
    ) -> Set<LightboxAsset.ID> {
        guard !assetFrames.isEmpty else {
            return Set(activeAssets.prefix(24).map(\.id))
        }

        let viewportHeight = max(1, viewportHeight)
        let leadingMargin: CGFloat
        let trailingMargin: CGFloat
        switch scrollDirection {
        case .stationary:
            leadingMargin = viewportHeight * 0.35
            trailingMargin = viewportHeight * 0.35
        case .up:
            leadingMargin = viewportHeight * 0.70
            trailingMargin = viewportHeight * 0.20
        case .down:
            leadingMargin = viewportHeight * 0.20
            trailingMargin = viewportHeight * 0.70
        }

        let priorityRange = (-leadingMargin)...(viewportHeight + trailingMargin)
        var candidates: [(id: LightboxAsset.ID, distance: CGFloat)] = []
        let focusY: CGFloat
        switch scrollDirection {
        case .stationary:
            focusY = viewportHeight * 0.5
        case .up:
            focusY = 0
        case .down:
            focusY = viewportHeight
        }
        for (id, frame) in assetFrames where frame.maxY >= priorityRange.lowerBound && frame.minY <= priorityRange.upperBound {
            candidates.append((id: id, distance: abs(frame.midY - focusY)))
        }

        var ids = Set(candidates
            .sorted { $0.distance < $1.distance }
            .prefix(maxPrioritizedAssetCount)
            .map(\.id))
        if ids.isEmpty {
            ids.formUnion(activeAssets.prefix(24).map(\.id))
        }
        return ids
    }
}

struct GalleryAssetFrameLifecycle {
    private static let scrollUpdateThreshold: CGFloat = 24
    private static let comparisonTolerance: CGFloat = 0.5

    static func activeFrames(
        _ frames: [LightboxAsset.ID: CGRect],
        activeAssetIDs: Set<LightboxAsset.ID>
    ) -> [LightboxAsset.ID: CGRect] {
        frames.reduce(into: [:]) { result, entry in
            guard activeAssetIDs.contains(entry.key) else { return }
            result[entry.key] = entry.value
        }
    }

    static func replacementFrames(
        current: [LightboxAsset.ID: CGRect],
        incoming: [LightboxAsset.ID: CGRect],
        activeAssetIDs: Set<LightboxAsset.ID>
    ) -> [LightboxAsset.ID: CGRect]? {
        let next = activeFrames(incoming, activeAssetIDs: activeAssetIDs)
        guard current != next else { return nil }
        guard Set(current.keys) == Set(next.keys),
              let firstID = next.keys.first,
              let firstCurrentFrame = current[firstID],
              let firstNextFrame = next[firstID]
        else {
            return next
        }

        let verticalShift = firstNextFrame.minY - firstCurrentFrame.minY
        let isUniformVerticalTranslation = next.allSatisfy { id, nextFrame in
            guard let currentFrame = current[id] else { return false }
            return abs(nextFrame.minX - currentFrame.minX) <= comparisonTolerance
                && abs(nextFrame.width - currentFrame.width) <= comparisonTolerance
                && abs(nextFrame.height - currentFrame.height) <= comparisonTolerance
                && abs((nextFrame.minY - currentFrame.minY) - verticalShift) <= comparisonTolerance
        }

        if isUniformVerticalTranslation, abs(verticalShift) <= scrollUpdateThreshold {
            return nil
        }
        return next
    }
}

struct GalleryAssetFrameSnapshot: Equatable {
    var selectionFrames: [LightboxAsset.ID: CGRect] = [:]
    var previewFrames: [LightboxAsset.ID: CGRect] = [:]

    mutating func merge(_ next: GalleryAssetFrameSnapshot) {
        selectionFrames.merge(next.selectionFrames, uniquingKeysWith: { _, new in new })
        previewFrames.merge(next.previewFrames, uniquingKeysWith: { _, new in new })
    }
}

@MainActor
final class GalleryFrameUpdateCoordinator {
    private var snapshot = GalleryAssetFrameSnapshot()
    private var pendingActiveAssetIDs: Set<LightboxAsset.ID> = []
    private var task: Task<Void, Never>?

    func submit(
        _ snapshot: GalleryAssetFrameSnapshot,
        activeAssetIDs: Set<LightboxAsset.ID>,
        apply: @escaping @MainActor (GalleryAssetFrameSnapshot, Set<LightboxAsset.ID>) -> Void
    ) {
        self.snapshot.merge(snapshot)
        pendingActiveAssetIDs = activeAssetIDs
        guard task == nil else { return }

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            apply(self.snapshot, self.pendingActiveAssetIDs)
        }
    }

    func flush(apply: @MainActor (GalleryAssetFrameSnapshot, Set<LightboxAsset.ID>) -> Void) {
        task?.cancel()
        task = nil
        apply(snapshot, pendingActiveAssetIDs)
    }

    func remove(
        _ assetID: LightboxAsset.ID,
        activeAssetIDs: Set<LightboxAsset.ID>,
        apply: @escaping @MainActor (GalleryAssetFrameSnapshot, Set<LightboxAsset.ID>) -> Void
    ) {
        snapshot.selectionFrames.removeValue(forKey: assetID)
        snapshot.previewFrames.removeValue(forKey: assetID)
        submit(GalleryAssetFrameSnapshot(), activeAssetIDs: activeAssetIDs, apply: apply)
    }

    func cancel() {
        task?.cancel()
        task = nil
        snapshot = GalleryAssetFrameSnapshot()
        pendingActiveAssetIDs = []
    }
}

@MainActor
final class GalleryMasonryColumnCache {
    private struct Key: Equatable {
        var columnCount: Int
        var itemWidthTenths: Int
    }

    private struct Entry {
        var key: Key
        var revision: Int
        var assets: [LightboxAsset]
        var columns: [[LightboxAsset]]
    }

    // Keep each search group warm without retaining every intermediate resize width.
    private var columnsByIdentity: [String: Entry] = [:]

    func columns(
        identity: String,
        revision: Int,
        assets: [LightboxAsset],
        columnCount: Int,
        itemWidth: CGFloat,
        preservesColumnAssignment: Bool = false,
        compute: () -> [[LightboxAsset]]
    ) -> [[LightboxAsset]] {
        let key = Key(
            columnCount: columnCount,
            itemWidthTenths: Int((itemWidth * 10).rounded())
        )
        if preservesColumnAssignment, var cached = columnsByIdentity[identity],
           cached.revision == revision, cached.key.columnCount == columnCount {
            // A continuous zoom resizes the same cards until the column count
            // changes. Re-packing them at each pointer sample creates needless
            // identity moves and lazy-stack layout work.
            cached.key = key
            columnsByIdentity[identity] = cached
            return cached.columns
        }
        if var cached = columnsByIdentity[identity], cached.key == key {
            if cached.revision == revision { return cached.columns }
            // A metadata update in one recursive folder must not reflow every folder.
            // Compare full assets once per revision so cached card metadata stays current.
            if cached.assets == assets {
                cached.revision = revision
                columnsByIdentity[identity] = cached
                return cached.columns
            }
            // Tag/name/file-signature updates should refresh cards without re-packing
            // every masonry column. Only order and aspect ratio determine geometry.
            if cached.assets.count == assets.count,
               zip(cached.assets, assets).allSatisfy({ $0.id == $1.id && $0.aspectRatio == $1.aspectRatio }) {
                let updated = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                cached.columns = cached.columns.map { $0.map { updated[$0.id] ?? $0 } }
                cached.assets = assets
                cached.revision = revision
                columnsByIdentity[identity] = cached
                return cached.columns
            }
        }

        let columns = compute()
        columnsByIdentity[identity] = Entry(key: key, revision: revision, assets: assets, columns: columns)
        return columns
    }

    func retain(identities: Set<String>) {
        columnsByIdentity = columnsByIdentity.filter { identities.contains($0.key) }
    }

    func removeAll() {
        columnsByIdentity.removeAll(keepingCapacity: true)
    }
}

struct GalleryPerformanceProfile: Equatable {
    var isCompatibilityMode: Bool

    static var current: GalleryPerformanceProfile {
        GalleryPerformanceProfile(isCompatibilityMode: LightboxRuntime.usesCompatibilityPerformanceMode)
    }

    var maxPrioritizedAssetCount: Int {
        isCompatibilityMode ? 24 : GalleryImagePriorityPlanner.maxPrioritizedAssetCount
    }

    var reducesHoverEffects: Bool {
        isCompatibilityMode
    }

    func initialImageLoadWindow(prefersFastRawThumbnails: Bool) -> Int {
        if isCompatibilityMode {
            return prefersFastRawThumbnails ? 20 : 30
        }
        return prefersFastRawThumbnails ? 30 : 48
    }

    func preloadMargin(viewportHeight: CGFloat, prefersFastRawThumbnails: Bool) -> CGFloat {
        let multiplier: CGFloat
        if isCompatibilityMode {
            multiplier = prefersFastRawThumbnails ? 0.35 : 0.55
        } else {
            multiplier = prefersFastRawThumbnails ? 0.55 : 1.0
        }
        return viewportHeight * multiplier
    }

    func thumbnailQuality(assetCount: Int, usesConservativeExternalLoading: Bool) -> ImageCacheQuality {
        if isCompatibilityMode {
            if assetCount >= 260 || (usesConservativeExternalLoading && assetCount >= 160) {
                return .thumbnailFast
            }
            if assetCount >= 80 || (usesConservativeExternalLoading && assetCount >= 48) {
                return .thumbnailBalanced
            }
            return .thumbnail
        }

        if assetCount >= 700 || (usesConservativeExternalLoading && assetCount >= 320) {
            return .thumbnailFast
        }
        if assetCount >= 240 || (usesConservativeExternalLoading && assetCount >= 80) {
            return .thumbnailBalanced
        }
        return .thumbnail
    }

    func permitsFullThumbnailPromotion(assetCount: Int, usesConservativeExternalLoading: Bool) -> Bool {
        guard !isCompatibilityMode else { return false }
        return !(usesConservativeExternalLoading && assetCount >= 80)
    }
}

private struct GalleryPendingGroupScroll {
    let token = UUID()
    var assetID: LightboxAsset.ID
    var groupID: String
    var anchor: UnitPoint
    var navigationToken: String
}

/// Thumbnail size, selection, keyboard focus and the preview's image publish
/// on their own objects, not on `AppState`, so the gallery observes them
/// directly. They are handed to `GalleryContentView` as observed objects
/// (rather than observed from a wrapper around its body) so that each change
/// invalidates the whole gallery view: the masonry grid only rebuilds its
/// cards when its parent does.
struct GalleryView: View {
    var isResizingSidebar = false

    @EnvironmentObject private var appState: AppState

    var body: some View {
        GalleryContentView(
            isResizingSidebar: isResizingSidebar,
            thumbnailScale: appState.thumbnailScale,
            selection: appState.selection,
            keyboardFocus: appState.keyboardFocus,
            preview: appState.preview
        )
    }
}

private struct GalleryContentView: View {
    var isResizingSidebar: Bool
    @ObservedObject var thumbnailScale: ThumbnailScaleState
    @ObservedObject var selection: GallerySelectionState
    @ObservedObject var keyboardFocus: GalleryKeyboardFocusState
    @ObservedObject var preview: PreviewPresentationState

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @LightboxViewState private var frozenColumns: Int?
    @LightboxViewState private var lastViewportWidth: CGFloat = 0
    /// Keyboard and tab-restore targets for the virtual grid, which scrolls by
    /// its own known card rects instead of `ScrollViewProxy.scrollTo`.
    @LightboxViewState private var masonryReveal: GalleryRevealRequest?
    @LightboxViewState private var revealGeneration = 0
    @LightboxViewState private var lastViewportHeight: CGFloat = 0
    @LightboxViewState private var scrollGeometry = GalleryScrollGeometry()
    @LightboxViewState private var selectionRect: CGRect?
    @LightboxViewState private var restoredScrollGeneration = -1
    /// A tab's saved position being scrolled back to: the anchor is not
    /// recorded until it lands, or the top of the new scroll view would
    /// overwrite it.
    @LightboxViewState private var pendingRestoreReveal: Int?
    @LightboxViewState private var frameUpdateCoordinator = GalleryFrameUpdateCoordinator()
    @LightboxViewState private var masonryColumnCache = GalleryMasonryColumnCache()
    @LightboxViewState private var masonryPlacementCache = GalleryMasonryPlacementCache()
    @LightboxViewState private var storagePerformanceCache = GalleryStoragePerformanceCache()
    @LightboxViewState private var pendingGroupScroll: GalleryPendingGroupScroll?
    /// Set only by the pull gesture: ordinary folder loads report progress in
    /// the header title and must not open the refresh spinner above the grid.
    @LightboxViewState private var isPullRefreshing = false

    private let horizontalPadding = GalleryThumbnailSizing.horizontalPadding
    /// With the sidebar open, its resize strip already separates the panel from
    /// the gallery. Trimming the leading gutter by that strip makes the gap from
    /// the panel to the first image equal the right-hand gutter.
    private var leadingPadding: CGFloat {
        appState.sidebarCollapsed ? horizontalPadding : horizontalPadding - SidebarMetrics.resizeHandleWidth
    }
    /// First row of images (or the search hint) when no folder section sits
    /// above it: the 52pt header plus the same gutter as the sides.
    private var imagesTopInset: CGFloat { 52 + horizontalPadding }

    // Changes only on real navigation (source / folder / filter), not when the
    // asset array mutates during metadata streaming — so the scroll view resets
    // on navigation, never on every background metadata batch.
    private var navigationToken: String {
        "\(appState.activeTabID.uuidString)|\(appState.selectedSourceID)|\(appState.currentFolderURL.path)|\(appState.selectedFilter.identityKey)"
    }

    private var scrollRestoreAvailabilityToken: String {
        let anchorID = appState.activeTabScrollAnchorAssetID
        let isAvailable = anchorID.map { id in appState.activeAssetIDs.contains(id) } ?? true
        return "\(appState.scrollRestoreGeneration)|\(isAvailable)"
    }

    // Quiet empty state for a folder with nothing to show. Shown only
    // when there are no images and no subfolders, and we're not loading/trash.
    private var showsEmptyState: Bool {
        !appState.isViewingTrash
            && appState.libraryLoadingStatus == nil
            && appState.searchStatus?.isSearching != true
            && !(appState.searchStatus?.isLoadingMetadata == true && appState.selectedFilter != .all)
            && appState.activeAssets.isEmpty
            && visibleFolderEntries.isEmpty
            && !(appState.attributeFilter.needsMetadataPass && appState.isReadingImageSizes)
    }

    private var hasSearchQuery: Bool {
        appState.hasSearchQuery
    }

    private var visibleFolderEntries: [LibraryFolderEntry] {
        guard appState.showFolderCards, !appState.isViewingTrash else { return [] }
        return appState.activeFolderEntries
    }

    private var emptyStateSymbol: String {
        if appState.attributeFilter.isActive { return "line.3.horizontal.decrease" }
        return hasSearchQuery ? "magnifyingglass" : "photo.on.rectangle.angled"
    }

    private var emptyStateTitle: String {
        if appState.attributeFilter.isActive { return FilterText(appState.appLanguage).noMatches }
        return appState.localized(hasSearchQuery ? .noMatches : .noImagesHere)
    }

    var body: some View {
        GeometryReader { viewport in
            let geometryNavigationToken = navigationToken
            // Reset before constructing cells so the first geometry callback
            // cannot discard their freshly registered image-loading states.
            let _ = prepareGeometry(for: geometryNavigationToken)
            let folderHorizontalPadding = leadingPadding
            let folderGridMetrics = galleryMetrics(viewportWidth: viewport.size.width)
            let activeAssets = appState.activeAssets
            let activeAssetIDs = appState.activeAssetIDs
            let performanceProfile = GalleryPerformanceProfile.current
            let prefersFastRawThumbnails = prefersFastRawThumbnails(activeAssets: activeAssets)
            let plan = scrollGeometry.renderPlan ?? makeRenderPlan(viewportHeight: viewport.size.height)
            let loadableAssetIDs = plan.loadableAssetIDs
            let prioritizedAssetIDs = plan.prioritizedAssetIDs
            let settledVisibleAssetIDs = plan.settledVisibleAssetIDs
            let thumbnailQuality = galleryThumbnailQuality(assetCount: activeAssets.count, performanceProfile: performanceProfile)
            let permitsFullThumbnailPromotion = galleryPermitsFullThumbnailPromotion(
                assetCount: activeAssets.count,
                performanceProfile: performanceProfile
            ) && !scrollGeometry.isScrolling && !appState.isScalingThumbnails
            let usesReducedHover = appState.libraryLoadingStatus != nil || performanceProfile.reducesHoverEffects
            let assetMenuTitles = AssetContextMenuTitles(appState: appState)
            let visibleFolders = visibleFolderEntries
            let searchGroups = appState.usesRecursiveResults ? appState.searchAssetGroups : []
            let shouldGroupSearchAssets = groupsSearchAssets
            let showsSearchLimitHint = appState.searchStatus?.limitReached == true

            ZStack(alignment: .trailing) {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                    VStack(spacing: 0) {

                        if !visibleFolders.isEmpty {
                            FolderRowView(
                                folders: visibleFolders,
                                availableWidth: folderGridMetrics.usedWidth,
                                columnGuide: FolderColumnGuide(count: folderGridMetrics.columns,
                                    width: folderGridMetrics.itemWidth, spacing: SpacingTokens.regular),
                                title: appState.localized(.folders),
                                showInFinderTitle: appState.localized(.showInFinder),
                                openInNewTabTitle: appState.localized(.openInNewTab),
                                renameTitle: appState.renameText.menuItem,
                                expandedTitle: appState.localized(.expandedState),
                                collapsedTitle: appState.localized(.collapsedState),
                                selectedFolderID: appState.selectedGalleryFolderID,
                                summaries: appState.folderSummaries,
                                imageCountText: { appState.folderImageCountText($0) },
                                clearSelection: { appState.clearSelection() },
                                showsRelativePath: appState.hasSearchQuery
                            ) { folder in
                                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                                    appState.openFolderInNewTab(folder)
                                } else {
                                    appState.openFolder(folder)
                                }
                            } openInNewTab: { folder in
                                appState.openFolderInNewTab(folder)
                            } rename: { folder in
                                appState.beginRename(folder)
                            } reveal: { folder in
                                appState.revealFolderInFinder(folder)
                            }
                            .equatable()
                            .padding(.top, 58)
                            .padding(.leading, folderHorizontalPadding + folderGridMetrics.leadingInset)
                            .padding(.trailing, horizontalPadding)
                            // Same 18pt as the gutters between the folder section and the images.
                            .padding(.bottom, horizontalPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FolderRowFrameProbe())
                        }

                        if showsSearchLimitHint {
                            SearchLimitHint(message: appState.localized(appState.includesSubfolders ? .recursiveResultsIncomplete : .searchResultsLimited))
                                .padding(.top, visibleFolders.isEmpty ? imagesTopInset : 0)
                                .padding(.leading, leadingPadding).padding(.trailing, horizontalPadding)
                                .padding(.bottom, 14)
                        }

                        Group {
                            if shouldGroupSearchAssets {
                                LazyVStack(spacing: 18) {
                                    ForEach(searchGroups) { group in
                                        VStack(alignment: .leading, spacing: 10) {
                                            SearchGroupHeader(
                                                title: group.title,
                                                count: group.assets.count,
                                                isExpanded: !appState.isGroupCollapsed(group.id)
                                            ) {
                                                if appState.isGroupCollapsed(group.id) {
                                                    appState.setGroup(group.id, collapsed: false)
                                                } else {
                                                    appState.setGroup(group.id, collapsed: true)
                                                    for asset in group.assets { scrollGeometry.remove(asset.id) }
                                                    refreshRenderPlan(viewportHeight: viewport.size.height)
                                                    if group.assets.contains(where: { $0.id == appState.galleryKeyboardFocusID }) {
                                                        appState.galleryKeyboardFocusID = nil
                                                    }
                                                }
                                            }
                                            .modifier(GalleryColumnFrame(metrics: galleryMetrics(
                                                viewportWidth: viewport.size.width,
                                                minimumColumns: min(GalleryThumbnailSizing.maximumZoomColumnCount, max(1, group.assets.count))
                                            )))
                                            .padding(.leading, leadingPadding).padding(.trailing, horizontalPadding)
                                            .background(SearchGroupHeaderFrameProbe(id: group.id))

                                            if !appState.isGroupCollapsed(group.id) {
                                                assetGrid(
                                                    activeAssets: group.assets,
                                                    activeAssetIDs: activeAssetIDs,
                                                    cacheIdentity: group.id,
                                                    viewportWidth: viewport.size.width,
                                                    loadableAssetIDs: loadableAssetIDs,
                                                    prioritizedAssetIDs: prioritizedAssetIDs,
                                                    settledVisibleAssetIDs: settledVisibleAssetIDs,
                                                    thumbnailQuality: thumbnailQuality,
                                                    permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                                                    prefersFastRawThumbnails: prefersFastRawThumbnails,
                                                    usesReducedHover: usesReducedHover,
                                                    performanceProfile: performanceProfile,
                                                    menuTitles: assetMenuTitles
                                                )
                                                .padding(.leading, leadingPadding).padding(.trailing, horizontalPadding)
                                            }
                                        }
                                        .id(group.id)
                                    }
                                }
                            } else {
                                assetGrid(
                                    activeAssets: activeAssets,
                                    activeAssetIDs: activeAssetIDs,
                                    cacheIdentity: "active",
                                    reportsScrollAnchor: true,
                                    viewportWidth: viewport.size.width,
                                    loadableAssetIDs: loadableAssetIDs,
                                    prioritizedAssetIDs: prioritizedAssetIDs,
                                    settledVisibleAssetIDs: settledVisibleAssetIDs,
                                    thumbnailQuality: thumbnailQuality,
                                    permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                                    prefersFastRawThumbnails: prefersFastRawThumbnails,
                                    usesReducedHover: usesReducedHover,
                                    performanceProfile: performanceProfile,
                                    menuTitles: assetMenuTitles
                                )
                                .padding(.leading, leadingPadding).padding(.trailing, horizontalPadding)
                            }
                        }
                        .padding(.top, visibleFolders.isEmpty && !showsSearchLimitHint ? imagesTopInset : 0)
                        .padding(.bottom, 92)
                        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.galleryLayoutMode)
                    }
                    .coordinateSpace(name: "GalleryContent")
                    .background {
                        GalleryContentOriginProbe { origin in
                            guard prepareGeometry(for: geometryNavigationToken) else { return }
                            noteContentOrigin(origin, viewportHeight: viewport.size.height)
                        }
                    }
                    .background(GalleryScrollBarConfigurator { scrollGeometry.scrollView = $0 })
                    .background(GalleryRefreshControl(
                        isRefreshing: isPullRefreshing && appState.isRefreshingGallery,
                        isEnabled: !appState.hasActiveOverlay,
                        refresh: {
                            isPullRefreshing = true
                            appState.refreshGalleryFromGesture()
                        }
                    ))
                    }
                    .scrollIndicators(.automatic)
                    .id(navigationToken)
                    .coordinateSpace(name: "GalleryScroll")
                    .contextMenu {
                        backgroundContextMenu
                    }
                    .onPreferenceChange(FolderRowFramePreferenceKey.self) { frame in
                        guard prepareGeometry(for: geometryNavigationToken) else { return }
                        scrollGeometry.folderFrame = frame
                    }
                    .onPreferenceChange(SearchGroupHeaderFramePreferenceKey.self) { frames in
                        guard prepareGeometry(for: geometryNavigationToken) else { return }
                        scrollGeometry.groupHeaderFrames = frames
                        finishPendingGroupScroll(using: scrollProxy)
                    }
                    .onAppear {
                        guard prepareGeometry(for: geometryNavigationToken) else { return }
                        lastViewportWidth = viewport.size.width
                        lastViewportHeight = viewport.size.height
                        refreshRenderPlan(viewportHeight: viewport.size.height)
                        restoreScrollIfNeeded(using: scrollProxy)
                    }
                    .onChange(of: navigationToken) { _ in
                        pendingGroupScroll = nil
                        _ = prepareGeometry(for: navigationToken)
                        selectionRect = nil
                        restoreScrollIfNeeded(using: scrollProxy)
                    }
                    .onChange(of: appState.activeAssetsRevision) { _ in
                        masonryColumnCache.retain(identities: Set(appState.searchAssetGroups.map(\.id)).union(["active"]))
                        masonryPlacementCache.retain(identities: Set(appState.searchAssetGroups.map(\.id)).union(["active"]))
                        scrollGeometry.retain(activeAssetIDs: appState.activeAssetIDs)
                        refreshRenderPlan(viewportHeight: viewport.size.height)
                    }
                    .onChange(of: viewport.size.height) { height in
                        lastViewportHeight = height
                        refreshRenderPlan(viewportHeight: viewport.size.height)
                    }
                    .onChange(of: appState.galleryKeyboardScrollGeneration) { _ in
                        // A preview stepping to another image keeps that image's
                        // card in view underneath, so closing lands on it.
                        guard !appState.isComparing, let id = appState.galleryKeyboardFocusID else { return }
                        if let frame = appState.previewSpaceFrame(for: id),
                           frame.minY >= 52, frame.maxY <= viewport.size.height - 55 { return }
                        requestScroll(to: id, anchor: .center, using: scrollProxy)
                    }
                    .onChange(of: appState.isRefreshingGallery) { refreshing in
                        if !refreshing { isPullRefreshing = false }
                    }
                    .onChange(of: scrollRestoreAvailabilityToken) { _ in
                        restoreScrollIfNeeded(using: scrollProxy)
                    }
                    .onChange(of: viewport.size.width) { width in
                        lastViewportWidth = width
                    }
                    .onChange(of: appState.isScalingThumbnails) { scaling in
                        refreshRenderPlan(viewportHeight: viewport.size.height)
                        // Land the slider on the width the filled grid shows, so the
                        // next drag starts from what is on screen instead of jumping.
                        if !scaling {
                            let settledWidth = galleryMetrics(viewportWidth: viewport.size.width).itemWidth
                            appState.thumbnailWidth = GalleryThumbnailSizing.clampedStoredWidth(settledWidth)
                        }
                    }
                    .onChange(of: thumbnailScale.columnStepAnchor) { step in
                        // Keep the image that was at the top there once the
                        // new columns have laid out.
                        guard let step, appState.activeAssetIDs.contains(step.assetID) else { return }
                        DispatchQueue.main.async { requestScroll(to: step.assetID, anchor: .top, using: scrollProxy) }
                    }
                    .onChange(of: isResizingSidebar) { resizing in
                        if resizing {
                            frozenColumns = galleryMetrics(viewportWidth: lastViewportWidth).columns
                        } else {
                            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                                frozenColumns = nil
                            }
                        }
                    }
                }

                if !activeAssets.isEmpty {
                    RubberBandSelectionLayer(
                        assetFrames: [:],
                        frameProvider: { scrollGeometry.selectionFrames },
                        contentFrameProvider: { scrollGeometry.contentFrames },
                        contentOriginProvider: { scrollGeometry.origin.selection },
                        scrollViewProvider: { scrollGeometry.scrollView },
                        excludedFrameProvider: { scrollGeometry.exclusionFrames },
                        excludedFrames: [CGRect(
                            x: viewport.size.width - 16, y: 0,
                            width: 16, height: viewport.size.height
                        )],
                        activeAssetIDs: activeAssetIDs,
                        selectedAssetIDs: appState.selectedAssetIDs,
                        onSelectionRectChange: { rect in
                            selectionRect = rect
                        },
                        onSelectionChange: { ids in
                            appState.replaceSelection(with: ids)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let selectionRect {
                    RubberBandSelectionRect(rect: selectionRect)
                        .allowsHitTesting(false)
                }

                if appState.isViewingTrash,
                   appState.trashAccessDenied,
                   activeAssets.isEmpty,
                   appState.libraryLoadingStatus == nil {
                    TrashAccessHint(
                        message: appState.localized(.trashAccessDenied),
                        actionTitle: appState.localized(.openFullDiskAccess)
                    ) {
                        appState.openFullDiskAccessSettings()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, 58)
                    .transition(.opacity.combined(with: .lightboxBlurReplace))
                }

                if showsEmptyState {
                    GalleryEmptyState(
                        symbol: emptyStateSymbol,
                        title: emptyStateTitle,
                        actionTitle: appState.attributeFilter.isActive ? FilterText(appState.appLanguage).clear : nil
                    ) {
                        appState.attributeFilter = GalleryAttributeFilter()
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.top, 58)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }

            }
            .coordinateSpace(name: "GallerySelectionSpace")
            .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: showsEmptyState)
        }
        .onAppear {
            appState.setPreviewSpaceAssetFrameProvider { [scrollGeometry] in scrollGeometry.previewFrames }
        }
        .onDisappear {
            frameUpdateCoordinator.cancel()
            masonryColumnCache.removeAll()
            masonryPlacementCache.removeAll()
            scrollGeometry.clear()
            appState.setPreviewSpaceAssetFrameProvider(nil)
        }
    }

    private func imageLoadAssetIDs(
        activeAssets: [LightboxAsset],
        assetFrames: [LightboxAsset.ID: CGRect],
        viewportHeight: CGFloat,
        prefersFastRawThumbnails: Bool,
        performanceProfile: GalleryPerformanceProfile
    ) -> Set<LightboxAsset.ID> {
        let initialWindow = performanceProfile.initialImageLoadWindow(prefersFastRawThumbnails: prefersFastRawThumbnails)
        guard !assetFrames.isEmpty else {
            return Set(activeAssets.prefix(initialWindow).map(\.id))
        }
        var ids: Set<LightboxAsset.ID> = []

        let preloadMargin = performanceProfile.preloadMargin(
            viewportHeight: viewportHeight,
            prefersFastRawThumbnails: prefersFastRawThumbnails
        )
        let loadRange = (-preloadMargin)...(viewportHeight + preloadMargin)
        for (id, frame) in assetFrames {
            if frame.maxY >= loadRange.lowerBound && frame.minY <= loadRange.upperBound {
                ids.insert(id)
            }
        }
        return ids
    }

    // Probes from a replaced scroll subtree can finish after the new one appears.
    private func prepareGeometry(for token: String) -> Bool {
        guard token == navigationToken else { return false }
        if scrollGeometry.resetIfNeeded(navigationToken: token) {
            frameUpdateCoordinator.cancel()
            masonryColumnCache.removeAll()
            masonryPlacementCache.removeAll()
        }
        return true
    }

    private func noteContentOrigin(_ origin: GalleryContentOrigin, viewportHeight: CGFloat) {
        let previousOffset = scrollGeometry.origin.scrollOffset
        scrollGeometry.updateOrigin(origin)
        if origin.scrollOffset != previousOffset, !isResizingSidebar {
            let direction: GalleryScrollDirection = origin.scrollOffset > previousOffset ? .down : .up
            scrollGeometry.scrollDirection = direction
            scrollGeometry.isScrolling = true
            scrollGeometry.scheduleScrollSettled {
                scrollGeometry.isScrolling = false
                scrollGeometry.scrollDirection = .stationary
                refreshRenderPlan(viewportHeight: viewportHeight)
            }
        }
        let frames = scrollGeometry.selectionFrames
        refreshRenderPlan(viewportHeight: viewportHeight, assetFrames: frames)
        updateScrollAnchor()
    }

    private func flushPendingFrames() {
        frameUpdateCoordinator.flush { _, _ in
            let frames = scrollGeometry.selectionFrames
            refreshRenderPlan(viewportHeight: lastViewportHeight, assetFrames: frames)
            updateScrollAnchor()
        }
    }

    private func makeRenderPlan(
        viewportHeight: CGFloat,
        assetFrames: [LightboxAsset.ID: CGRect]? = nil
    ) -> GalleryRenderPlan {
        let assets = appState.activeAssets
        let frames = assetFrames ?? scrollGeometry.selectionFrames
        let profile = GalleryPerformanceProfile.current
        return GalleryRenderPlan(
            loadableAssetIDs: imageLoadAssetIDs(
                activeAssets: assets, assetFrames: frames, viewportHeight: viewportHeight,
                prefersFastRawThumbnails: prefersFastRawThumbnails(activeAssets: assets),
                performanceProfile: profile
            ),
            prioritizedAssetIDs: GalleryImagePriorityPlanner.prioritizedAssetIDs(
                activeAssets: assets, assetFrames: frames, viewportHeight: viewportHeight,
                scrollDirection: scrollGeometry.scrollDirection, maxPrioritizedAssetCount: profile.maxPrioritizedAssetCount
            ),
            settledVisibleAssetIDs: scrollGeometry.isScrolling ? [] : Set(frames.compactMap { id, frame in
                GalleryImagePriorityPlanner.isVisible(frame, viewportHeight: viewportHeight) ? id : nil
            })
        )
    }

    private func refreshRenderPlan(
        viewportHeight: CGFloat,
        assetFrames: [LightboxAsset.ID: CGRect]? = nil
    ) {
        let plan = makeRenderPlan(viewportHeight: viewportHeight, assetFrames: assetFrames)
        scrollGeometry.replaceRenderPlan(plan)
        let profile = GalleryPerformanceProfile.current
        scrollGeometry.imageLoading.update(
            plan: plan,
            baseQuality: galleryThumbnailQuality(assetCount: appState.activeAssets.count, performanceProfile: profile),
            prefersFastRawThumbnails: prefersFastRawThumbnails(activeAssets: appState.activeAssets),
            permitsFullThumbnailPromotion: galleryPermitsFullThumbnailPromotion(
                assetCount: appState.activeAssets.count, performanceProfile: profile
            ) && !scrollGeometry.isScrolling && !appState.isScalingThumbnails
        )
    }

    /// The virtual masonry grid reports its own anchor when it is the only
    /// grid; grouped results and the VoiceOver grid derive it from card frames.
    private var masonryReportsScrollAnchor: Bool {
        !voiceOverEnabled && !groupsSearchAssets
    }

    private var groupsSearchAssets: Bool {
        !appState.activeAssets.isEmpty && appState.usesRecursiveResults
            && (appState.includesSubfolders || appState.searchAssetGroups.count > 1)
    }

    /// Until the tab's saved position is restored the grid sits at the top;
    /// recording that would overwrite the position being restored.
    private var mayRecordScrollAnchor: Bool {
        restoredScrollGeneration == appState.scrollRestoreGeneration && pendingRestoreReveal == nil
    }

    private func recordScrollAnchor(_ assetID: LightboxAsset.ID?, scrollOffset: CGFloat) {
        guard mayRecordScrollAnchor else { return }
        let anchor = scrollOffset > 40 ? assetID : nil
        if anchor != appState.activeTabScrollAnchorAssetID {
            scrollRestoreLogger.info("anchor recorded offset=\(Int(scrollOffset)) anchor=\(anchor.map { String($0.suffix(24)) } ?? "nil", privacy: .public)")
        }
        appState.updateActiveTabScrollAnchor(anchor)
    }

    private func updateScrollAnchor() {
        // After a geometry reset the origin reads zero until the next report.
        guard !masonryReportsScrollAnchor, mayRecordScrollAnchor, scrollGeometry.hasOrigin else { return }
        guard scrollGeometry.origin.scrollOffset > 40 else {
            appState.updateActiveTabScrollAnchor(nil)
            return
        }

        // The card whose top is nearest the top of the scroll view: restoring
        // scrolls that same top back there, so the position does not creep.
        let offset = scrollGeometry.origin.scrollOffset
        let anchorID = scrollGeometry.contentFrames
            .filter { $0.value.maxY - offset >= 0 }
            .min { abs($0.value.minY - offset) < abs($1.value.minY - offset) }?
            .key
        appState.updateActiveTabScrollAnchor(anchorID)
    }

    private func restoreScrollIfNeeded(using proxy: ScrollViewProxy) {
        let generation = appState.scrollRestoreGeneration
        guard restoredScrollGeneration != generation else { return }
        guard let anchorID = appState.activeTabScrollAnchorAssetID else {
            restoredScrollGeneration = generation
            masonryReveal = nil
            return
        }
        guard appState.activeAssetIDs.contains(anchorID) else {
            scrollRestoreLogger.info("restore waiting generation=\(generation) anchor=\(String(anchorID.suffix(24)), privacy: .public) unavailable")
            return
        }
        scrollRestoreLogger.info("restore requested generation=\(generation) anchor=\(String(anchorID.suffix(24)), privacy: .public)")

        restoredScrollGeneration = generation
        let previousReveal = masonryReveal?.generation
        requestScroll(to: anchorID, anchor: .top, using: proxy)
        if let reveal = masonryReveal?.generation, reveal != previousReveal {
            pendingRestoreReveal = reveal
            // Release the anchor even if the reveal never reports back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if pendingRestoreReveal == reveal { pendingRestoreReveal = nil }
            }
        }
    }

    private func requestScroll(to id: LightboxAsset.ID, anchor: UnitPoint, using proxy: ScrollViewProxy) {
        pendingGroupScroll = nil
        guard appState.usesRecursiveResults,
              let group = appState.searchAssetGroups.first(where: { $0.assets.contains { $0.id == id } }),
              appState.includesSubfolders || appState.searchAssetGroups.count > 1 else {
            if voiceOverEnabled {
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: anchor) }
            } else {
                // Never reuse a generation: the grid ignores one it has
                // already revealed, and the request is cleared between tabs.
                revealGeneration &+= 1
                masonryReveal = GalleryRevealRequest(assetID: id, anchor: anchor, generation: revealGeneration)
            }
            return
        }
        // Showing an image inside a collapsed folder opens the folder for good.
        appState.setGroup(group.id, collapsed: false)
        let request = GalleryPendingGroupScroll(assetID: id, groupID: group.id,
            anchor: anchor, navigationToken: navigationToken)
        pendingGroupScroll = request
        if scrollGeometry.groupHeaderFrames[group.id] != nil {
            finishPendingGroupScroll(using: proxy)
        } else {
            // An unmounted LazyVStack group has no inner asset marker yet.
            // Reveal its known root first; the header preference confirms the
            // group's children exist before resolving the requested asset.
            DispatchQueue.main.async {
                guard pendingGroupScroll?.token == request.token,
                      navigationToken == request.navigationToken else { return }
                proxy.scrollTo(group.id, anchor: .top)
            }
        }
    }

    private func finishPendingGroupScroll(using proxy: ScrollViewProxy) {
        guard let request = pendingGroupScroll,
              request.navigationToken == navigationToken,
              scrollGeometry.groupHeaderFrames[request.groupID] != nil else { return }
        DispatchQueue.main.async {
            guard pendingGroupScroll?.token == request.token,
                  navigationToken == request.navigationToken,
                  appState.activeAssetIDs.contains(request.assetID) else { return }
            pendingGroupScroll = nil
            proxy.scrollTo(request.assetID, anchor: request.anchor)
        }
    }

    private func galleryThumbnailQuality(assetCount: Int, performanceProfile: GalleryPerformanceProfile) -> ImageCacheQuality {
        let usesConservativeExternalLoading = storagePerformance(activeAssets: appState.activeAssets).usesConservativeExternalLoading
        return performanceProfile.thumbnailQuality(
            assetCount: assetCount,
            usesConservativeExternalLoading: usesConservativeExternalLoading
        )
    }

    private func galleryPermitsFullThumbnailPromotion(assetCount: Int, performanceProfile: GalleryPerformanceProfile) -> Bool {
        let usesConservativeExternalLoading = storagePerformance(activeAssets: appState.activeAssets).usesConservativeExternalLoading
        return performanceProfile.permitsFullThumbnailPromotion(
            assetCount: assetCount,
            usesConservativeExternalLoading: usesConservativeExternalLoading
        )
    }

    private func storagePerformance(activeAssets: [LightboxAsset]) -> GalleryStoragePerformance {
        storagePerformanceCache.configuration(
            source: appState.selectedSource,
            usesConservativeExternalLoading: appState.selectedSourceUsesConservativeExternalLoading,
            activeAssets: activeAssets,
            revision: appState.activeAssetsRevision
        )
    }

    private func prefersFastRawThumbnails(activeAssets: [LightboxAsset]) -> Bool {
        storagePerformance(activeAssets: activeAssets).prefersFastRawThumbnails
    }

    @ViewBuilder
    private func assetGrid(
        activeAssets: [LightboxAsset],
        activeAssetIDs: Set<LightboxAsset.ID>,
        cacheIdentity: String,
        reportsScrollAnchor: Bool = false,
        viewportWidth: CGFloat,
        loadableAssetIDs: Set<LightboxAsset.ID>,
        prioritizedAssetIDs: Set<LightboxAsset.ID>,
        settledVisibleAssetIDs: Set<LightboxAsset.ID>,
        thumbnailQuality: ImageCacheQuality,
        permitsFullThumbnailPromotion: Bool,
        prefersFastRawThumbnails: Bool,
        usesReducedHover: Bool,
        performanceProfile: GalleryPerformanceProfile,
        menuTitles: AssetContextMenuTitles
    ) -> some View {
        let geometryNavigationToken = navigationToken
        let minimumColumns = min(
            GalleryThumbnailSizing.maximumZoomColumnCount,
            max(1, activeAssets.count)
        )
        let metrics = galleryMetrics(
            viewportWidth: viewportWidth,
            minimumColumns: minimumColumns
        )

        let columns = masonryColumnCache.columns(
            identity: cacheIdentity,
            revision: appState.activeAssetsRevision,
            assets: activeAssets,
            columnCount: metrics.columns,
            itemWidth: metrics.itemWidth,
            preservesColumnAssignment: appState.isScalingThumbnails || isResizingSidebar
        ) {
            masonryColumns(for: activeAssets, columnCount: metrics.columns, itemWidth: metrics.itemWidth)
        }
        if !voiceOverEnabled {
            let placement = masonryPlacementCache.placement(identity: cacheIdentity,
                revision: appState.activeAssetsRevision, columns: columns, itemWidth: metrics.itemWidth, assets: activeAssets)
            GalleryVirtualMasonryGrid(placement: placement, width: metrics.usedWidth,
                viewportHeight: lastViewportHeight, isScaling: appState.isScalingThumbnails,
                revealAssetIDs: Set([appState.galleryKeyboardFocusID, appState.activeTabScrollAnchorAssetID].compactMap { $0 }),
                revealRequest: masonryReveal,
                revealLanded: { generation in
                    if pendingRestoreReveal == generation {
                        scrollRestoreLogger.info("restore landed reveal=\(generation)")
                        pendingRestoreReveal = nil
                    }
                },
                topAssetChanged: reportsScrollAnchor ? { assetID, scrollOffset in
                    recordScrollAnchor(assetID, scrollOffset: scrollOffset)
                } : nil,
                framesChanged: { frames, removed, added, owner in
                    guard prepareGeometry(for: geometryNavigationToken) else { return }
                    for id in removed { _ = scrollGeometry.remove(id, owner: owner) }
                    for (id, frame) in frames where appState.activeAssetIDs.contains(id) {
                        _ = scrollGeometry.updateContentFrame(frame, for: id, owner: owner, registering: added.contains(id))
                    }
                    frameUpdateCoordinator.submit(.init(selectionFrames: frames), activeAssetIDs: activeAssetIDs) { _, _ in
                        refreshRenderPlan(viewportHeight: lastViewportHeight)
                        // Cards mount after the scroll that brought them in;
                        // the anchor must come from them, not the cards above.
                        updateScrollAnchor()
                    }
                }) { asset in
                assetCard(asset, itemWidth: metrics.itemWidth,
                    itemHeight: metrics.itemWidth / max(0.35, asset.aspectRatio),
                    activeAssetIDs: activeAssetIDs, loadableAssetIDs: loadableAssetIDs,
                    prioritizedAssetIDs: prioritizedAssetIDs, settledVisibleAssetIDs: settledVisibleAssetIDs,
                    thumbnailQuality: thumbnailQuality, permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                    prefersFastRawThumbnails: prefersFastRawThumbnails, usesReducedHover: usesReducedHover,
                    performanceProfile: performanceProfile, menuTitles: menuTitles, reportsOwnFrame: false)
            }
            .frame(width: metrics.usedWidth)
            .padding(.leading, metrics.leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
        HStack(alignment: .top, spacing: SpacingTokens.regular) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, columnAssets in
                LazyVStack(spacing: SpacingTokens.regular) {
                    ForEach(columnAssets) { asset in
                        assetCard(
                            asset,
                            itemWidth: metrics.itemWidth,
                            itemHeight: metrics.itemWidth / max(0.35, asset.aspectRatio),
                            activeAssetIDs: activeAssetIDs,
                            loadableAssetIDs: loadableAssetIDs,
                            prioritizedAssetIDs: prioritizedAssetIDs,
                            settledVisibleAssetIDs: settledVisibleAssetIDs,
                            thumbnailQuality: thumbnailQuality,
                            permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                            prefersFastRawThumbnails: prefersFastRawThumbnails,
                            usesReducedHover: usesReducedHover,
                            performanceProfile: performanceProfile,
                            menuTitles: menuTitles
                        )
                    }
                }
                .frame(width: metrics.itemWidth)
            }
        }
        .frame(width: metrics.usedWidth)
        .padding(.leading, metrics.leadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func assetCard(
        _ asset: LightboxAsset,
        itemWidth: CGFloat,
        itemHeight: CGFloat,
        activeAssetIDs: Set<LightboxAsset.ID>,
        loadableAssetIDs: Set<LightboxAsset.ID>,
        prioritizedAssetIDs: Set<LightboxAsset.ID>,
        settledVisibleAssetIDs: Set<LightboxAsset.ID>,
        thumbnailQuality: ImageCacheQuality,
        permitsFullThumbnailPromotion: Bool,
        prefersFastRawThumbnails: Bool,
        usesReducedHover: Bool,
        performanceProfile: GalleryPerformanceProfile,
        menuTitles: AssetContextMenuTitles,
        reportsOwnFrame: Bool = true
    ) -> some View {
        let geometryNavigationToken = navigationToken
        let requiredPixelSize = max(itemWidth, itemHeight) * (NSApp.mainWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let imageLoadingState = scrollGeometry.imageLoading.state(for: asset.id, requiredPixelSize: requiredPixelSize,
            initial: GalleryImageLoadingConfiguration(
                loadsImage: loadableAssetIDs.contains(asset.id),
                priority: prioritizedAssetIDs.contains(asset.id) ? .high : .low,
                quality: thumbnailQuality
            ))
        return AssetCardView(
            asset: asset,
            keyboardFocusRequested: appState.galleryKeyboardFocusID == asset.id,
            onKeyboard: { key, modifiers in
                flushPendingFrames()
                appState.handleGalleryKey(key, modifiers: modifiers, from: asset.id)
            },
            onPreviewArrow: { appState.handlePreviewArrowDuringKeyboardHandoff($0) },
            onActivate: {
                flushPendingFrames()
                appState.showPreview(for: asset, sourceFrame: appState.previewSpaceFrame(for: asset.id))
            },
            // Suppress the source card's selection glow while its preview is
            // presented/closing — otherwise the card un-hides (at the source-reveal
            // delay) still "selected" and the glow flashes for a few frames before
            // the close finishes and clears selection.
            isSelected: appState.isAssetHighlighted(asset)
                && !(appState.isPreviewPresented && appState.previewAssetID == asset.id),
            isExplicitlySelected: appState.selectedAssetIDs.contains(asset.id),
            showsSelectionControl: appState.hasExplicitSelection,
            imagePriority: prioritizedAssetIDs.contains(asset.id) ? .high : .low,
            imageQuality: GalleryImagePriorityPlanner.displayQuality(
                baseQuality: thumbnailQuality,
                isPrioritized: prioritizedAssetIDs.contains(asset.id),
                prefersFastRawThumbnails: prefersFastRawThumbnails,
                permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                isSettledVisible: settledVisibleAssetIDs.contains(asset.id)
            ),
            loadsImage: loadableAssetIDs.contains(asset.id),
            imageLoadingState: imageLoadingState,
            compareTrayLabel: appState.compareTrayLabel(for: asset.id),
            isPreviewSourceHidden: appState.previewSourceHiddenAssetID == asset.id,
            isInteractionEnabled: !appState.hasActiveOverlay,
            compareMenuTitle: compareMenuTitle(for: asset),
            menuTitles: menuTitles,
            usesReducedHover: usesReducedHover,
            isComparePulse: appState.compareTrayPulseID == asset.id,
            showsPressFeedback: !appState.hasExplicitSelection,
            dragSourceURLs: { appState.dragSourceURLs(for: asset) },
            onClick: { click in
                flushPendingFrames()
                appState.handleAssetClick(
                    asset,
                    modifiers: click.modifierFlags,
                    click: click,
                    sourceFrame: appState.previewSpaceFrame(for: asset.id) ?? click.windowTopLeftFrame
                )
            },
            onRestore: {
                appState.restore(asset)
            },
            onMoveToTrash: {
                appState.markDeleted(asset)
            },
            onApplyTag: { tag in
                appState.toggleTag(tag, to: asset)
            },
            onOpenWith: { applicationURL in
                appState.openWithApplication(asset, applicationURL: applicationURL)
            },
            onRevealInFinder: {
                appState.revealInFinder(asset)
            },
            onCopy: {
                appState.copyToClipboard(asset)
            },
            onShare: { view in
                appState.share(asset, from: view)
            },
            onAddToCompareTray: {
                appState.addSelectedToCompareTray(fallback: asset)
            },
            onRename: {
                appState.beginRename(fallback: asset)
            },
            onExportJPEG: {
                appState.beginJPEGExport(fallback: asset)
            },
            onQuickLook: {
                appState.showQuickLook(appState.operationTargetAssets(fallback: asset))
            },
            onSpace: {
                flushPendingFrames()
                appState.handleSpace(on: asset)
            }
        )
        .equatable()
        .id(asset.id)
        .frame(width: itemWidth, height: itemHeight)
        .background {
            if reportsOwnFrame {
            AssetFrameProbe(id: asset.id) { frame, owner, isInitial in
                guard prepareGeometry(for: geometryNavigationToken) else { return }
                guard scrollGeometry.updateContentFrame(frame, for: asset.id, owner: owner,
                    registering: isInitial) else { return }
                frameUpdateCoordinator.submit(.init(selectionFrames: [asset.id: frame]), activeAssetIDs: activeAssetIDs) { _, _ in
                    refreshRenderPlan(viewportHeight: lastViewportHeight)
                }
            } onDisappear: { owner in
                guard geometryNavigationToken == navigationToken,
                      geometryNavigationToken == scrollGeometry.navigationToken else { return }
                guard scrollGeometry.remove(asset.id, owner: owner) else { return }
                frameUpdateCoordinator.remove(asset.id, activeAssetIDs: activeAssetIDs) { _, _ in
                    refreshRenderPlan(viewportHeight: lastViewportHeight)
                }
            }
            }
        }
    }

    private func compareMenuTitle(for asset: LightboxAsset) -> String {
        if appState.selectedAssetIDs.count > 1, appState.selectedAssetIDs.contains(asset.id) {
            return appState.localized(.addSelectedToCompareTray)
        }

        return appState.localized(.addToCompareTray)
    }

    private func masonryColumns(
        for assets: [LightboxAsset],
        columnCount: Int,
        itemWidth: CGFloat
    ) -> [[LightboxAsset]] {
        var columns = Array(repeating: [LightboxAsset](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)

        for asset in assets {
            let column = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            columns[column].append(asset)
            heights[column] += itemWidth / max(0.35, asset.aspectRatio) + SpacingTokens.regular
        }

        return columns
    }

    private func galleryMetrics(
        viewportWidth: CGFloat,
        minimumColumns: Int = GalleryThumbnailSizing.maximumZoomColumnCount
    ) -> (columns: Int, itemWidth: CGFloat, usedWidth: CGFloat, leadingInset: CGFloat) {
        let availableWidth = max(1, viewportWidth - leadingPadding - horizontalPadding)
        appState.thumbnailScale.galleryAvailableWidth = availableWidth
        let spacing = SpacingTokens.regular
        let minimumColumns = max(1, minimumColumns)
        let effectiveThumbnailWidth = min(
            appState.thumbnailWidth,
            GalleryThumbnailSizing.maximumWidth(
                viewportWidth: viewportWidth,
                columnCount: minimumColumns
            )
        )
        // Dragging the slider scales cards continuously at the slider's width
        // (whole columns that fit, leading-aligned). At rest the grid takes the
        // nearest column count and its columns share the full width, so both
        // edges line up; releasing the slider animates between the two.
        let fittingColumns = (availableWidth + spacing) / (effectiveThumbnailWidth + spacing)
        let isScaling = appState.isScalingThumbnails
        let computedColumns = max(
            minimumColumns,
            isScaling ? Int(fittingColumns) : Int(fittingColumns.rounded())
        )
        // While resizing the sidebar, hold the column count steady (only itemWidth
        // changes) so images don't jump between columns every frame; re-column on release.
        let columns = isResizingSidebar ? (frozenColumns ?? computedColumns) : computedColumns
        let maxItemWidth = floor((availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let itemWidth = isScaling ? min(effectiveThumbnailWidth, maxItemWidth) : maxItemWidth
        let usedWidth = CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing
        // Whole-point card widths leave up to a point per column over; split it
        // so the left and right gutters match at rest.
        let leadingInset = isScaling ? 0 : floor((availableWidth - usedWidth) / 2)
        return (columns, itemWidth, usedWidth, leadingInset)
    }

    @ViewBuilder
    private var backgroundContextMenu: some View {
        Button {
            appState.beginNewFolder()
        } label: {
            Text(appState.renameText.newFolderMenuItem)
        }
        .disabled(!appState.canCreateFolder)
        Divider()
        Button {
            appState.revealCurrentFolderInFinder()
        } label: {
            Text(appState.localized(.showInFinder))
        }
    }
}

private struct TrashAccessHint: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lightboxGlassOpacity) private var glassOpacity

    var message: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        let materialOpacity = GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity)
        let fillOpacity = GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme)
        let strokeOpacity = GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity)
        let shadowOpacity = GlassTokens.floatingCapsuleShadowOpacity(glassOpacity)

        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .lineLimit(1)

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LightboxColorTokens.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Capsule())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Capsule()))
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: 34)
        .background(.ultraThinMaterial.opacity(materialOpacity), in: Capsule())
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
        }
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(strokeOpacity), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 3)
    }
}

private struct GalleryEmptyState: View {
    var symbol: String
    var title: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary.opacity(0.34))

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LightboxColorTokens.mutedText)

            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .allowsHitTesting(actionTitle != nil)
    }
}

private struct SearchGroupHeader: View {
    @EnvironmentObject private var appState: AppState
    var title: String
    var count: Int
    var isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LightboxColorTokens.mutedText)
                    .monospacedDigit()

                Rectangle()
                    .fill(.secondary.opacity(0.16))
                    .frame(height: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(LightboxTextHoverStyle(rest: LightboxColorTokens.secondaryText))
        .accessibilityValue(appState.localized(isExpanded ? .expandedState : .collapsedState))
    }
}

private struct SearchLimitHint: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lightboxGlassOpacity) private var glassOpacity

    var message: String

    var body: some View {
        let materialOpacity = GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity)
        let fillOpacity = GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme)
        let strokeOpacity = GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity)
        let shadowOpacity = GlassTokens.floatingCapsuleShadowOpacity(glassOpacity)

        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(LightboxColorTokens.mutedText)

            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.ultraThinMaterial.opacity(materialOpacity), in: Capsule())
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
        }
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(strokeOpacity), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 3)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct FolderRowView: View, Equatable {
    @LightboxViewState private var isExpanded = true

    var folders: [LibraryFolderEntry]
    var availableWidth: CGFloat
    var columnGuide: FolderColumnGuide? = nil
    var title: String
    var showInFinderTitle: String
    var openInNewTabTitle: String
    var renameTitle: String
    var expandedTitle: String
    var collapsedTitle: String
    var selectedFolderID: LibraryFolderEntry.ID?
    var summaries: FolderSummaryService? = nil
    var imageCountText: (Int) -> String = { "\($0)" }
    var clearSelection: () -> Void
    var showsRelativePath = false
    var open: (LibraryFolderEntry) -> Void
    var openInNewTab: (LibraryFolderEntry) -> Void
    var rename: ((LibraryFolderEntry) -> Void)?
    var reveal: (LibraryFolderEntry) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folders == rhs.folders && lhs.title == rhs.title && lhs.availableWidth == rhs.availableWidth
            && lhs.columnGuide == rhs.columnGuide
            && lhs.showInFinderTitle == rhs.showInFinderTitle
            && lhs.openInNewTabTitle == rhs.openInNewTabTitle && lhs.renameTitle == rhs.renameTitle
            && (lhs.rename == nil) == (rhs.rename == nil)
            && lhs.expandedTitle == rhs.expandedTitle && lhs.collapsedTitle == rhs.collapsedTitle
            && lhs.selectedFolderID == rhs.selectedFolderID && lhs.showsRelativePath == rhs.showsRelativePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isExpanded.toggle() } label: {
                // Chevron centered on the cover column; title on the names' edge.
                HStack(spacing: FolderGridPlacement.iconTextGap) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: FolderGridPlacement.thumbnailSize.width)
                    Text("\(title) · \(folders.count)")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.leading, FolderGridPlacement.contentInset)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(LightboxTextHoverStyle(rest: LightboxColorTokens.mutedText))
            .accessibilityValue(isExpanded ? expandedTitle : collapsedTitle)

            if isExpanded {
                NativeFolderGrid(
                    folders: folders, availableWidth: availableWidth, columnGuide: columnGuide,
                    showsRelativePath: showsRelativePath,
                    selectedFolderID: selectedFolderID,
                    showInFinderTitle: showInFinderTitle, openInNewTabTitle: openInNewTabTitle,
                    renameTitle: renameTitle,
                    clearSelection: clearSelection, open: open, openInNewTab: openInNewTab,
                    rename: rename, reveal: reveal,
                    summaries: summaries, imageCountText: imageCountText
                )
                .frame(height: FolderGridPlacement(count: folders.count, width: availableWidth,
                                                  showsRelativePath: showsRelativePath, columnGuide: columnGuide).height)
            }
        }
    }
}

private struct AssetFrameProbe: View {
    var id: LightboxAsset.ID
    var onUpdate: (CGRect, UUID, Bool) -> Void
    var onDisappear: (UUID) -> Void
    @LightboxViewState private var owner = UUID()

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("GalleryContent"))
            Color.clear
                .onAppear { onUpdate(frame, owner, true) }
                .onChange(of: frame) { onUpdate($0, owner, false) }
                .onDisappear { onDisappear(owner) }
        }
    }
}

private struct GalleryContentOriginProbe: View {
    var onUpdate: (GalleryContentOrigin) -> Void

    var body: some View {
        GeometryReader { proxy in
            let origin = GalleryContentOrigin(
                selection: proxy.frame(in: .named("GallerySelectionSpace")).origin,
                preview: proxy.frame(in: .named("PreviewSpace")).origin,
                scrollOffset: max(0, -proxy.frame(in: .named("GalleryScroll")).minY)
            )
            Color.clear
                .onAppear { onUpdate(origin) }
                .onChange(of: origin) { onUpdate($0) }
        }
    }
}

private struct FolderRowFrameProbe: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: FolderRowFramePreferenceKey.self,
                value: proxy.frame(in: .named("GalleryContent"))
            )
        }
    }
}

private struct FolderRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct SearchGroupHeaderFrameProbe: View {
    var id: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SearchGroupHeaderFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named("GalleryContent"))]
            )
        }
    }
}

private struct SearchGroupHeaderFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct RubberBandSelectionRect: View {
    var rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: RadiusTokens.small, style: .continuous)
            .fill(.gray.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: RadiusTokens.small, style: .continuous)
                    .stroke(.gray.opacity(0.72), lineWidth: 1)
            }
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }
}

/// Sizes a header row to its grid's columns and applies the same centering
/// inset, so it starts exactly where the grid's first column does.
private struct GalleryColumnFrame: ViewModifier {
    var metrics: (columns: Int, itemWidth: CGFloat, usedWidth: CGFloat, leadingInset: CGFloat)

    func body(content: Content) -> some View {
        content
            .frame(width: metrics.usedWidth)
            .padding(.leading, metrics.leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
