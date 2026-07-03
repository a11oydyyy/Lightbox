import SwiftUI

enum GalleryScrollDirection {
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
        permitsFullThumbnailPromotion: Bool = true
    ) -> ImageCacheQuality {
        guard isPrioritized else { return baseQuality }
        guard permitsFullThumbnailPromotion else {
            switch baseQuality {
            case .thumbnailFast:
                return .thumbnailBalanced
            case .thumbnailBalanced:
                return .thumbnailBalanced
            case .thumbnail, .preview, .comparison:
                return baseQuality
            }
        }
        guard prefersFastRawThumbnails else { return .thumbnail }

        switch baseQuality {
        case .thumbnailFast:
            return .thumbnailBalanced
        case .thumbnailBalanced:
            return .thumbnailBalanced
        case .thumbnail, .preview, .comparison:
            return baseQuality
        }
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

struct GalleryView: View {
    var isResizingSidebar = false

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frozenColumns: Int?
    @State private var lastViewportWidth: CGFloat = 0
    @State private var assetFrames: [LightboxAsset.ID: CGRect] = [:]
    @State private var folderRowFrame: CGRect?
    @State private var selectionRect: CGRect?
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 1
    @State private var scrollViewportHeight: CGFloat = 1
    @State private var scrollDirection: GalleryScrollDirection = .stationary
    @State private var scrollIndicatorVisible = false
    @State private var scrollVisibilityGeneration = 0
    @State private var scrollFadeTask: Task<Void, Never>?
    @State private var contentVisible = true

    private let horizontalPadding: CGFloat = 18

    // Changes only on real navigation (source / folder / filter), not when the
    // asset array mutates during metadata streaming — so the entrance plays on
    // navigation, never on every background metadata batch.
    private var navigationToken: String {
        "\(appState.selectedSourceID)|\(appState.currentFolderURL.path)|\(appState.selectedFilter.identityKey)"
    }

    // Container-level entrance: a single gentle fade + settle for the whole grid,
    // instead of a per-card cascade that would replay as cells scroll into a lazy stack.
    private func playContentEntrance() {
        contentVisible = false
        DispatchQueue.main.async {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                contentVisible = true
            }
        }
    }

    // Quiet empty state for a folder with nothing to show. Shown only
    // when there are no images and no subfolders, and we're not loading/trash.
    private var showsEmptyState: Bool {
        !appState.isViewingTrash
            && appState.libraryLoadingStatus == nil
            && appState.searchStatus?.isSearching != true
            && appState.activeAssets.isEmpty
            && visibleFolderEntries.isEmpty
    }

    private var hasSearchQuery: Bool {
        appState.hasSearchQuery
    }

    private var visibleFolderEntries: [LibraryFolderEntry] {
        guard appState.showFolderCards, !appState.isViewingTrash else { return [] }
        return appState.activeFolderEntries
    }

    private var emptyStateSymbol: String {
        hasSearchQuery ? "magnifyingglass" : "photo.on.rectangle.angled"
    }

    private var emptyStateTitle: String {
        appState.localized(hasSearchQuery ? .noMatches : .noImagesHere)
    }

    var body: some View {
        GeometryReader { viewport in
            let folderHorizontalPadding = horizontalPadding + imageColumnInset(viewportWidth: viewport.size.width)
            let activeAssets = appState.activeAssets
            let performanceProfile = GalleryPerformanceProfile.current
            let prefersFastRawThumbnails = prefersFastRawThumbnails(activeAssets: activeAssets)
            let loadableAssetIDs = imageLoadAssetIDs(
                activeAssets: activeAssets,
                viewportHeight: viewport.size.height,
                prefersFastRawThumbnails: prefersFastRawThumbnails,
                performanceProfile: performanceProfile
            )
            let prioritizedAssetIDs = GalleryImagePriorityPlanner.prioritizedAssetIDs(
                activeAssets: activeAssets,
                assetFrames: assetFrames,
                viewportHeight: viewport.size.height,
                scrollDirection: scrollDirection,
                maxPrioritizedAssetCount: performanceProfile.maxPrioritizedAssetCount
            )
            let thumbnailQuality = galleryThumbnailQuality(assetCount: activeAssets.count, performanceProfile: performanceProfile)
            let permitsFullThumbnailPromotion = galleryPermitsFullThumbnailPromotion(
                assetCount: activeAssets.count,
                performanceProfile: performanceProfile
            )
            let usesReducedHover = appState.libraryLoadingStatus != nil || performanceProfile.reducesHoverEffects
            let assetMenuTitles = AssetContextMenuTitles(appState: appState)
            let visibleFolders = visibleFolderEntries
            let searchGroups = appState.hasSearchQuery ? appState.searchAssetGroups : []
            let shouldGroupSearchAssets = appState.hasSearchQuery && searchGroups.count > 1
            let showsSearchLimitHint = appState.searchStatus?.limitReached == true

            ZStack(alignment: .trailing) {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ScrollOffsetProbe()

                        if !visibleFolders.isEmpty {
                            FolderRowView(
                                folders: visibleFolders,
                                showInFinderTitle: appState.localized(.showInFinder),
                                showsRelativePath: appState.hasSearchQuery
                            ) { folder in
                                appState.openFolder(folder)
                            } reveal: { folder in
                                appState.revealFolderInFinder(folder)
                            }
                            .padding(.top, 70)
                            .padding(.horizontal, folderHorizontalPadding)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FolderRowFrameProbe())
                        }

                        if showsSearchLimitHint {
                            SearchLimitHint(message: appState.localized(.searchResultsLimited))
                                .padding(.top, visibleFolders.isEmpty ? 70 : 0)
                                .padding(.horizontal, horizontalPadding)
                                .padding(.bottom, 14)
                        }

                        Group {
                            if shouldGroupSearchAssets {
                                LazyVStack(spacing: 18) {
                                    ForEach(searchGroups) { group in
                                        VStack(alignment: .leading, spacing: 10) {
                                            SearchGroupHeader(title: group.title, count: group.assets.count)
                                                .padding(.horizontal, horizontalPadding)

                                            assetGrid(
                                                activeAssets: group.assets,
                                                viewportWidth: viewport.size.width,
                                                loadableAssetIDs: loadableAssetIDs,
                                                prioritizedAssetIDs: prioritizedAssetIDs,
                                                thumbnailQuality: thumbnailQuality,
                                                permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                                                prefersFastRawThumbnails: prefersFastRawThumbnails,
                                                usesReducedHover: usesReducedHover,
                                                performanceProfile: performanceProfile,
                                                menuTitles: assetMenuTitles
                                            )
                                            .padding(.horizontal, horizontalPadding)
                                        }
                                    }
                                }
                            } else {
                                assetGrid(
                                    activeAssets: activeAssets,
                                    viewportWidth: viewport.size.width,
                                    loadableAssetIDs: loadableAssetIDs,
                                    prioritizedAssetIDs: prioritizedAssetIDs,
                                    thumbnailQuality: thumbnailQuality,
                                    permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                                    prefersFastRawThumbnails: prefersFastRawThumbnails,
                                    usesReducedHover: usesReducedHover,
                                    performanceProfile: performanceProfile,
                                    menuTitles: assetMenuTitles
                                )
                                .padding(.horizontal, horizontalPadding)
                            }
                        }
                        .padding(.top, visibleFolders.isEmpty && !showsSearchLimitHint ? 70 : 0)
                        .padding(.bottom, 92)
                        .background(ContentHeightProbe())
                        .opacity(contentVisible ? 1 : 0)
                        .offset(y: contentVisible ? 0 : 8)
                        .animation(MotionTokens.ifAllowed(MotionTokens.thumbnailScale, reduceMotion: reduceMotion), value: appState.thumbnailWidth)
                        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.galleryLayoutMode)
                    }
                }
                .scrollIndicators(.hidden)
                .id(navigationToken)
                .coordinateSpace(name: "GalleryScroll")
                .contextMenu {
                    backgroundContextMenu
                }
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    updateAssetFramesIfNeeded(frames)
                }
                .onPreferenceChange(PreviewSpaceAssetFramePreferenceKey.self) { frames in
                    appState.updatePreviewSpaceAssetFrames(frames)
                }
                .onPreferenceChange(FolderRowFramePreferenceKey.self) { frame in
                    folderRowFrame = frame
                }
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    noteScroll(
                        offset: offset,
                        contentHeight: scrollContentHeight,
                        viewportHeight: viewport.size.height
                    )
                }
                .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
                    noteScroll(
                        offset: scrollOffset,
                        contentHeight: height,
                        viewportHeight: viewport.size.height
                    )
                }
                .onAppear {
                    playContentEntrance()
                    lastViewportWidth = viewport.size.width
                }
                .onChange(of: navigationToken) { _ in
                    assetFrames = [:]
                    folderRowFrame = nil
                    selectionRect = nil
                    appState.updatePreviewSpaceAssetFrames([:])
                    playContentEntrance()
                }
                .onChange(of: viewport.size.width) { width in
                    lastViewportWidth = width
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

                if !activeAssets.isEmpty {
                    RubberBandSelectionLayer(
                        assetFrames: assetFrames,
                        excludedFrames: folderExclusionFrames,
                        visibleAssetIDs: activeAssets.map(\.id),
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

                FloatingScrollIndicator(
                    viewportHeight: viewport.size.height,
                    contentHeight: scrollContentHeight,
                    fraction: scrollFraction,
                    isVisible: scrollIndicatorVisible
                )
                .padding(.trailing, 10)

                if let status = appState.libraryLoadingStatus {
                    GalleryLoadingIndicator(label: appState.loadingStatusText(status))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.top, 70)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
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
                    .padding(.top, 70)
                    .transition(.opacity.combined(with: .lightboxBlurReplace))
                }

                if showsEmptyState {
                    GalleryEmptyState(
                        symbol: emptyStateSymbol,
                        title: emptyStateTitle
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.top, 70)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }

                if appState.searchStatus?.isSearching == true {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.top, 70)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "GallerySelectionSpace")
            .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.libraryLoadingStatus)
            .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: showsEmptyState)
        }
    }

    private func imageLoadAssetIDs(
        activeAssets: [LightboxAsset],
        viewportHeight: CGFloat,
        prefersFastRawThumbnails: Bool,
        performanceProfile: GalleryPerformanceProfile
    ) -> Set<LightboxAsset.ID> {
        let initialWindow = performanceProfile.initialImageLoadWindow(prefersFastRawThumbnails: prefersFastRawThumbnails)
        var ids = Set(activeAssets.prefix(initialWindow).map(\.id))
        guard !assetFrames.isEmpty else {
            return ids
        }

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

    private var scrollFraction: CGFloat {
        let available = max(1, scrollContentHeight - scrollViewportHeight)
        return min(1, max(0, scrollOffset / available))
    }

    private func noteScroll(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        guard !isResizingSidebar else { return }
        let nextOffset = max(0, offset)
        let nextViewportHeight = max(1, viewportHeight)
        let nextContentHeight = max(contentHeight, nextViewportHeight)
        let nextIndicatorVisible = nextContentHeight > nextViewportHeight + 12
        let offsetChanged = abs(nextOffset - scrollOffset) > 18
        let contentChanged = abs(nextContentHeight - scrollContentHeight) > 1 || abs(nextViewportHeight - scrollViewportHeight) > 1
        let visibilityChanged = nextIndicatorVisible != scrollIndicatorVisible

        guard offsetChanged || contentChanged || visibilityChanged else {
            return
        }

        if nextOffset > scrollOffset + 8 {
            scrollDirection = .down
        } else if nextOffset < scrollOffset - 8 {
            scrollDirection = .up
        }
        scrollOffset = nextOffset
        scrollContentHeight = nextContentHeight
        scrollViewportHeight = nextViewportHeight

        if nextIndicatorVisible {
            scrollIndicatorVisible = true
            scrollVisibilityGeneration += 1
            let generation = scrollVisibilityGeneration
            scrollFadeTask?.cancel()
            scrollFadeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(760))
                guard !Task.isCancelled, generation == scrollVisibilityGeneration else { return }
                scrollIndicatorVisible = false
            }
        } else {
            scrollFadeTask?.cancel()
            scrollIndicatorVisible = false
        }
    }

    private func updateAssetFramesIfNeeded(_ frames: [LightboxAsset.ID: CGRect]) {
        // Avoid a per-frame preference→state→re-render storm while the sidebar
        // is being dragged (rubber-band selection isn't active then anyway).
        guard !isResizingSidebar else { return }
        guard !frames.isEmpty else {
            if !assetFrames.isEmpty {
                assetFrames = [:]
            }
            return
        }

        guard frames.count == assetFrames.count,
              Set(frames.keys) == Set(assetFrames.keys),
              let previousTop = assetFrames.values.map(\.minY).min(),
              let nextTop = frames.values.map(\.minY).min(),
              let previousWidth = assetFrames.values.first?.width,
              let nextWidth = frames.values.first?.width
        else {
            assetFrames = frames
            return
        }

        if abs(nextTop - previousTop) > 24 || abs(nextWidth - previousWidth) > 1 {
            assetFrames = frames
        }
    }

    private var folderExclusionFrames: [CGRect] {
        guard appState.showFolderCards,
              !appState.folderEntries.isEmpty,
              !appState.isViewingTrash,
              let folderRowFrame
        else {
            return []
        }

        return [folderRowFrame]
    }

    private func galleryThumbnailQuality(assetCount: Int, performanceProfile: GalleryPerformanceProfile) -> ImageCacheQuality {
        let usesConservativeExternalLoading = appState.selectedSource?.usesConservativeExternalLoading == true
        return performanceProfile.thumbnailQuality(
            assetCount: assetCount,
            usesConservativeExternalLoading: usesConservativeExternalLoading
        )
    }

    private func galleryPermitsFullThumbnailPromotion(assetCount: Int, performanceProfile: GalleryPerformanceProfile) -> Bool {
        let usesConservativeExternalLoading = appState.selectedSource?.usesConservativeExternalLoading == true
        return performanceProfile.permitsFullThumbnailPromotion(
            assetCount: assetCount,
            usesConservativeExternalLoading: usesConservativeExternalLoading
        )
    }

    private func prefersFastRawThumbnails(activeAssets: [LightboxAsset]) -> Bool {
        guard appState.selectedSource?.usesConservativeExternalLoading == true,
              activeAssets.count >= 500
        else {
            return false
        }

        let sample = Array(activeAssets.prefix(120))
        guard !sample.isEmpty else { return false }
        let rawCount = sample.reduce(0) { count, asset in
            guard let ext = asset.sourceURL?.pathExtension.lowercased(),
                  Self.rawImageExtensions.contains(ext)
            else {
                return count
            }
            return count + 1
        }

        return Double(rawCount) / Double(sample.count) >= 0.60
    }

    private static let rawImageExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf",
        "fff", "iiq", "k25", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf",
        "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "x3f"
    ]

    @ViewBuilder
    private func assetGrid(
        activeAssets: [LightboxAsset],
        viewportWidth: CGFloat,
        loadableAssetIDs: Set<LightboxAsset.ID>,
        prioritizedAssetIDs: Set<LightboxAsset.ID>,
        thumbnailQuality: ImageCacheQuality,
        permitsFullThumbnailPromotion: Bool,
        prefersFastRawThumbnails: Bool,
        usesReducedHover: Bool,
        performanceProfile: GalleryPerformanceProfile,
        menuTitles: AssetContextMenuTitles
    ) -> some View {
        let metrics = galleryMetrics(viewportWidth: viewportWidth)

        switch appState.galleryLayoutMode {
        case .masonry:
            let columns = masonryColumns(for: activeAssets, columnCount: metrics.columns, itemWidth: metrics.itemWidth)
            HStack(alignment: .top, spacing: SpacingTokens.regular) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, columnAssets in
                    LazyVStack(spacing: SpacingTokens.regular) {
                        ForEach(columnAssets) { asset in
                            assetCard(
                                asset,
                                itemWidth: metrics.itemWidth,
                                itemHeight: metrics.itemWidth / max(0.35, asset.aspectRatio),
                                loadableAssetIDs: loadableAssetIDs,
                                prioritizedAssetIDs: prioritizedAssetIDs,
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
            .frame(maxWidth: .infinity, alignment: .center)

        case .grid:
            let columns = Array(
                repeating: GridItem(.fixed(metrics.itemWidth), spacing: SpacingTokens.regular),
                count: metrics.columns
            )
            LazyVGrid(columns: columns, alignment: .center, spacing: SpacingTokens.regular) {
                ForEach(activeAssets) { asset in
                    assetCard(
                        asset,
                        itemWidth: metrics.itemWidth,
                        itemHeight: metrics.itemWidth,
                        loadableAssetIDs: loadableAssetIDs,
                        prioritizedAssetIDs: prioritizedAssetIDs,
                        thumbnailQuality: thumbnailQuality,
                        permitsFullThumbnailPromotion: permitsFullThumbnailPromotion,
                        prefersFastRawThumbnails: prefersFastRawThumbnails,
                        usesReducedHover: usesReducedHover,
                        performanceProfile: performanceProfile,
                        menuTitles: menuTitles
                    )
                }
            }
            .frame(width: metrics.usedWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func assetCard(
        _ asset: LightboxAsset,
        itemWidth: CGFloat,
        itemHeight: CGFloat,
        loadableAssetIDs: Set<LightboxAsset.ID>,
        prioritizedAssetIDs: Set<LightboxAsset.ID>,
        thumbnailQuality: ImageCacheQuality,
        permitsFullThumbnailPromotion: Bool,
        prefersFastRawThumbnails: Bool,
        usesReducedHover: Bool,
        performanceProfile: GalleryPerformanceProfile,
        menuTitles: AssetContextMenuTitles
    ) -> some View {
        return AssetCardView(
            asset: asset,
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
                permitsFullThumbnailPromotion: permitsFullThumbnailPromotion
            ),
            loadsImage: loadableAssetIDs.contains(asset.id),
            compareTrayLabel: appState.compareTrayLabel(for: asset.id),
            isPreviewSourceHidden: appState.previewSourceHiddenAssetID == asset.id,
            isInteractionEnabled: !appState.hasActiveOverlay,
            compareMenuTitle: compareMenuTitle(for: asset),
            menuTitles: menuTitles,
            usesReducedHover: usesReducedHover,
            isComparePulse: appState.compareTrayPulseID == asset.id,
            showsPressFeedback: !appState.hasExplicitSelection,
            onClick: { click in
                appState.handleAssetClick(
                    asset,
                    modifiers: click.modifierFlags,
                    click: click,
                    sourceFrame: appState.previewSpaceFrame(for: asset.id) ?? assetFrames[asset.id]
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
            }
        )
        .equatable()
        .id(asset.id)
        .frame(width: itemWidth, height: itemHeight)
        .background(AssetFrameProbe(id: asset.id))
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

    private func imageColumnInset(viewportWidth: CGFloat) -> CGFloat {
        galleryMetrics(viewportWidth: viewportWidth).leadingInset
    }

    private func galleryMetrics(viewportWidth: CGFloat) -> (columns: Int, itemWidth: CGFloat, usedWidth: CGFloat, leadingInset: CGFloat) {
        let availableWidth = max(1, viewportWidth - horizontalPadding * 2)
        let spacing = SpacingTokens.regular
        let computedColumns = max(1, Int((availableWidth + spacing) / (appState.thumbnailWidth + spacing)))
        // While resizing the sidebar, hold the column count steady (only itemWidth
        // shrinks) so images don't jump between columns every frame; re-column on release.
        let columns = isResizingSidebar ? (frozenColumns ?? computedColumns) : computedColumns
        let maxItemWidth = floor((availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let itemWidth = min(appState.thumbnailWidth, maxItemWidth)
        let usedWidth = CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing
        let leadingInset = max(0, floor((availableWidth - usedWidth) / 2))
        return (columns, itemWidth, usedWidth, leadingInset)
    }

    @ViewBuilder
    private var backgroundContextMenu: some View {
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
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(1)

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Capsule())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(), hoverScale: 1.018, glowOpacity: 0.14))
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
        .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 4)
    }
}

private struct GalleryEmptyState: View {
    var symbol: String
    var title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary.opacity(0.34))

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.46))
        }
        .allowsHitTesting(false)
    }
}

private struct SearchGroupHeader: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.70))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.72))
                .monospacedDigit()

            Rectangle()
                .fill(.secondary.opacity(0.16))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(Color.primary.opacity(0.52))

            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.66))
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
        .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 4)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct GalleryLoadingIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lightboxGlassOpacity) private var glassOpacity

    var label: String

    var body: some View {
        let materialOpacity = GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity)
        let fillOpacity = GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme)
        let strokeOpacity = GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity)
        let shadowOpacity = GlassTokens.floatingCapsuleShadowOpacity(glassOpacity)

        HStack(spacing: 9) {
            LightboxLoadingSpinner()

            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .monospacedDigit()
        }
        .padding(.horizontal, 13)
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
        .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 4)
            .allowsHitTesting(false)
    }
}

private struct LightboxLoadingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0.18, to: 0.82)
            .stroke(
                Color.primary.opacity(0.62),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
            )
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 0.82).repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = true
            }
            .onDisappear {
                isRotating = false
            }
            .accessibilityHidden(true)
    }
}

private struct FolderRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Lightbox.folderTileWidth") private var folderTileWidth: Double = 180
    private static let bulkFolderInteractionThreshold = 160

    var folders: [LibraryFolderEntry]
    var showInFinderTitle: String
    var showsRelativePath = false
    var open: (LibraryFolderEntry) -> Void
    var reveal: (LibraryFolderEntry) -> Void

    // The slider controls the minimum tile width; adaptive columns then stretch
    // to consume the row so wide windows do not leave a large blank gutter.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(folderTileWidth)), spacing: 10, alignment: .leading)]
    }

    var body: some View {
        let usesBulkInteractionMode = folders.count >= Self.bulkFolderInteractionThreshold
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(folders) { folder in
                FolderCardView(
                    folder: folder,
                    showInFinderTitle: showInFinderTitle,
                    showsRelativePath: showsRelativePath,
                    usesBulkInteractionMode: usesBulkInteractionMode,
                    open: open,
                    reveal: reveal
                )
            }
        }
        .transaction { transaction in
            if usesBulkInteractionMode {
                transaction.animation = nil
            }
        }
        .animation(
            usesBulkInteractionMode ? nil : MotionTokens.ifAllowed(MotionTokens.thumbnailScale, reduceMotion: reduceMotion),
            value: folderTileWidth
        )
    }
}

private struct FolderCardView: View {
    var folder: LibraryFolderEntry
    var showInFinderTitle: String
    var showsRelativePath: Bool
    var usesBulkInteractionMode: Bool
    var open: (LibraryFolderEntry) -> Void
    var reveal: (LibraryFolderEntry) -> Void

    @State private var loadedTags: [String]?

    private var resolvedTags: [String] {
        MacColorTag.sort((loadedTags ?? folder.tags).filter(MacColorTag.isColorTag))
    }

    private var tagLoadID: String {
        "\(folder.url.standardizedFileURL.path):\(folder.tags.joined(separator: ","))"
    }

    var body: some View {
        let tags = resolvedTags
        let tint = folderTint(tags)
        let iconColor = tint?.opacity(0.92) ?? Color.secondary

        Button {
            open(folder)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(showsRelativePath ? 1 : 2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsRelativePath,
                       !folder.relativePath.isEmpty,
                       folder.relativePath != folder.name {
                        Text(folder.relativePath)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                FolderTagDots(tags: tags)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
                    .fill(folderFillColor(tint))
            }
            .overlay {
                RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
                    .stroke(folderStrokeColor(tint), lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(
            shape: RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous),
            hoverScale: usesBulkInteractionMode ? 1.0 : 1.018,
            glowOpacity: usesBulkInteractionMode ? 0.04 : 0.13
        ))
        .contextMenu {
            Button {
                reveal(folder)
            } label: {
                Text(showInFinderTitle)
            }
        }
        .help(folder.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folderAccessibilityLabel(tags))
        .task(id: tagLoadID) {
            await loadTagsIfNeeded()
        }
    }

    private func loadTagsIfNeeded() async {
        let inlineTags = MacColorTag.sort(folder.tags.filter(MacColorTag.isColorTag))
        if !inlineTags.isEmpty {
            loadedTags = inlineTags
            return
        }

        if let cached = SidebarFolderTagCache.shared.cachedTags(for: folder.url) {
            loadedTags = cached
            return
        }

        let tags = await SidebarFolderTagCache.shared.tags(for: folder.url)
        guard !Task.isCancelled else { return }
        loadedTags = tags
    }

    private func folderAccessibilityLabel(_ tags: [String]) -> String {
        let sortedTags = MacColorTag.sort(tags.filter(MacColorTag.isColorTag))
        guard !sortedTags.isEmpty else { return folder.name }
        return ([folder.name] + sortedTags).joined(separator: ", ")
    }

    private func folderTint(_ tags: [String]) -> Color? {
        guard let firstName = tags.first,
              let tag = MacColorTag.all.first(where: { $0.name == firstName })
        else {
            return nil
        }

        return tag.color
    }

    private func folderFillColor(_ tint: Color?) -> Color {
        if let tint {
            return tint.opacity(0.075)
        }

        return Color(nsColor: .controlBackgroundColor).opacity(0.48)
    }

    private func folderStrokeColor(_ tint: Color?) -> Color {
        if let tint {
            return tint.opacity(0.22)
        }

        return .black.opacity(0.06)
    }
}

private struct FolderTagDots: View {
    var tags: [String]

    private var visibleTags: [MacColorTag] {
        MacColorTag.all.filter { tags.contains($0.name) }
    }

    var body: some View {
        HStack(spacing: MacTagDotMetrics.sidebarSpacing) {
            ForEach(visibleTags.prefix(3)) { tag in
                Circle()
                    .fill(tag.color)
                    .frame(
                        width: MacTagDotMetrics.folderCardDotDiameter,
                        height: MacTagDotMetrics.folderCardDotDiameter
                    )
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.78), lineWidth: MacTagDotMetrics.folderCardStrokeWidth)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
        }
        .frame(minWidth: visibleTags.isEmpty ? 0 : 30, alignment: .trailing)
        .allowsHitTesting(false)
    }
}

private struct AssetFrameProbe: View {
    var id: LightboxAsset.ID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: AssetFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named("GallerySelectionSpace"))]
            )
            .preference(
                key: PreviewSpaceAssetFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named("PreviewSpace"))]
            )
        }
    }
}

private struct FolderRowFrameProbe: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: FolderRowFramePreferenceKey.self,
                value: proxy.frame(in: .named("GallerySelectionSpace"))
            )
        }
    }
}

private struct AssetFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LightboxAsset.ID: CGRect] = [:]

    static func reduce(value: inout [LightboxAsset.ID: CGRect], nextValue: () -> [LightboxAsset.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PreviewSpaceAssetFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LightboxAsset.ID: CGRect] = [:]

    static func reduce(value: inout [LightboxAsset.ID: CGRect], nextValue: () -> [LightboxAsset.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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

private struct SelectionCounterText: View {
    @Environment(\.colorScheme) private var colorScheme
    var count: Int

    var body: some View {
        Text("\(count) selected")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .shadow(color: colorScheme == .dark ? .black.opacity(0.62) : .white.opacity(0.86), radius: 5, y: 1)
            .shadow(color: colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.18), radius: 1.5, y: 1)
    }
}

private struct ScrollOffsetProbe: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ScrollOffsetPreferenceKey.self,
                value: max(0, -proxy.frame(in: .named("GalleryScroll")).minY)
            )
        }
        .frame(height: 0)
    }
}

private struct ContentHeightProbe: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ContentHeightPreferenceKey.self,
                value: proxy.frame(in: .named("GalleryScroll")).maxY
            )
        }
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
