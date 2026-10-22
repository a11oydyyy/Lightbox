import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Loading the current folder: refresh, monitoring, metadata, the visible items and sorting.
extension AppState {
    var isRefreshingGallery: Bool {
        libraryLoadingStatus != nil || searchStatus?.isSearching == true
    }

    func refreshGalleryFromGesture() {
        guard !isShowingStartPage, !hasActiveOverlay, !isRefreshingGallery else { return }
        refreshLibrary(preservingVisibleSnapshot: true)
    }

    var activeAssets: [LightboxAsset] {
        cachedActiveAssets
    }

    var isViewingTrash: Bool {
        selectedFilter == .trash
    }

    /// The tab's scope in the grid; the list and the trash show one folder.
    var includesSubfolders: Bool { galleryLayoutMode == .recursive && galleryViewMode == .grid && !isViewingTrash }

    var usesRecursiveResults: Bool { !isViewingTrash && (hasSearchQuery || includesSubfolders) }

    var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeFolderEntries: [LibraryFolderEntry] {
        cachedActiveFolderEntries
    }

    var activeAssetIDs: Set<LightboxAsset.ID> { cachedActiveAssetIDs }

    var activeAssetIDList: [LightboxAsset.ID] { cachedActiveAssetIDList }

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
        let cancelledMetadataTask = assetMetadata.isRunning
        refreshTask?.cancel()
        libraryLoadTask?.cancel()
        assetMetadata.cancel()
        refreshSerial += 1
        let refreshID = refreshSerial
        if includesSubfolders {
            // A slow top-level folder snapshot must not delay recursive image results.
            scheduleSearch(preservingResults: preservingVisibleSnapshot, forceRefresh: true)
        }
        libraryLoadingStatus = LibraryLoadingStatus(phase: .scanning, processed: 0, total: nil,
                                                    isBackground: preservingVisibleSnapshot)
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
        let showsOtherFiles = showsOtherFiles
        let tabID = activeTabID
        libraryLoadTask = Task.detached(priority: .userInitiated) { [weak self, source, showsHiddenItems, showsOtherFiles] in
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
                includesOtherFiles: showsOtherFiles,
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
            // The index keeps whatever the last scan listed; show only what
            // the current settings list.
            let visibleAssets = snapshot.assets.filter { asset in
                guard showsOtherFiles || asset.isImage else { return false }
                guard !showsHiddenItems, let url = asset.sourceURL else { return true }
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

    /// Refreshes after the shown folder's contents changed (directory monitor,
    /// trash, restore, transfers). The same folder stays on screen, so keep
    /// what is visible and its known dimensions until the rescan replaces
    /// them: a plain refresh emptied recursive results, flashing the gallery.
    func scheduleLibraryRefresh() {
        Self.logger.info("refresh schedule debounce folder=\(self.currentFolderURL.path, privacy: .public) trash=\(self.isViewingTrash)")
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.refreshLibrary(preservingVisibleSnapshot: true)
        }
    }

    /// Routes the folder watcher's changes and the metadata loader's batches
    /// back here. Called once from `init`.
    func connectLibraryLoading() {
        folderWatcher.onChange = { [weak self] in self?.scheduleLibraryRefresh() }
        assetMetadata.onBatch = { [weak self] updates, processed, request in
            self?.applyAssetMetadataUpdates(updates, processedCount: processed, request: request)
        }
        searchMetadata.onBatch = { [weak self] updates, processed, request in
            guard let self else { return }
            self.applySearchResultMetadataUpdates(
                updates,
                sourceID: request.sourceID,
                folderPath: request.folderURL.standardizedFileURL.path,
                searchText: request.searchText,
                generation: request.refreshID
            )
            if self.searchGeneration == request.refreshID {
                self.searchStatus?.metadataProcessed = processed
            }
        }
        assetMetadata.onFinish = { [weak self] request, elapsed in
            self?.finishAssetMetadataRefresh(request, elapsed: elapsed)
        }
    }

    func restartLibraryMonitor() {
        guard !isShowingStartPage else {
            folderWatcher.stop()
            return
        }
        let monitoredURL = isViewingTrash ? LightboxLibraryStore.primarySystemTrashFolder : currentFolderURL
        if !isViewingTrash, selectedSourceUsesConservativeExternalLoading {
            folderWatcher.stop()
            Self.logger.info("monitor skipped external source path=\(monitoredURL.path, privacy: .public)")
            return
        }
        // The trash lists images only.
        if folderWatcher.watch(monitoredURL, includingSubfolders: includesSubfolders,
                               includingOtherFiles: showsOtherFiles && !isViewingTrash) {
            Self.logger.info("monitor restart path=\(monitoredURL.path, privacy: .public) trash=\(self.isViewingTrash)")
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
        let targets = AssetMetadataLoader.targets(
            for: snapshot, metadataLimit: metadataLimit, tagLimit: tagLimit, loadsFinderTags: loadsFinderTags
        )
        guard !targets.isEmpty else {
            Self.logger.info("refresh[\(refreshID)] metadata skipped no assets")
            return
        }
        Self.logger.info("refresh[\(refreshID)] metadata begin total=\(targets.count) dimensionLimit=\(metadataLimit) tagLimit=\(tagLimit) tags=\(loadsFinderTags) delayMs=\(startDelayMilliseconds) folder=\(folderURL.path, privacy: .public)")
        assetMetadata.start(AssetMetadataLoader.Request(
            targets: targets, sourceID: sourceID, folderURL: folderURL,
            refreshID: refreshID, startDelayMilliseconds: startDelayMilliseconds
        ))
    }

    func startCompleteAssetTagRefresh() {
        guard !isViewingTrash,
              !assets.isEmpty,
              let source = selectedSource
        else {
            return
        }

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
        request: AssetMetadataLoader.Request
    ) {
        let totalCount = request.targets.count
        let refreshID = request.refreshID
        guard !isViewingTrash,
              selectedSourceID == request.sourceID,
              currentFolderURL.standardizedFileURL.path == request.folderURL.standardizedFileURL.path
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
            // Only real changes: a revisit reads the same tags and stored
            // sizes back, and each change re-filters the whole gallery.
            if let width = update.width, let height = update.height,
               nextAssets[index].width != width || nextAssets[index].height != height
                || !nextAssets[index].metadataLoaded {
                nextAssets[index].width = width
                nextAssets[index].height = height
                nextAssets[index].metadataLoaded = true
                changed = true
            }
            if let tags = update.tags, nextAssets[index].tags != tags {
                nextAssets[index].tags = tags
                changed = true
            }
            if let edited = update.hasCameraRawSettings, nextAssets[index].hasCameraRawSettings != edited {
                nextAssets[index].hasCameraRawSettings = edited
                changed = true
            }
        }

        if changed {
            assets = nextAssets
        }
    }

    /// Whether sizes are still being read for what is on screen: a size
    /// filter hides those images until theirs arrive.
    var isReadingImageSizes: Bool {
        assetMetadata.isRunning || searchStatus?.isLoadingMetadata == true
    }

    private func finishAssetMetadataRefresh(_ request: AssetMetadataLoader.Request, elapsed: TimeInterval) {
        // `isReadingImageSizes` changed; nothing published says so.
        objectWillChange.send()
        guard !isViewingTrash,
              selectedSourceID == request.sourceID,
              currentFolderURL.standardizedFileURL.path == request.folderURL.standardizedFileURL.path
        else {
            Self.logger.info("refresh[\(request.refreshID)] metadata finish ignored")
            return
        }

        Self.logger.info("refresh[\(request.refreshID)] metadata finish seconds=\(elapsed, format: .fixed(precision: 2))")
    }

    func rebuildActiveAssets() {
        let result = GalleryContentFilter.visibleAssets(
            from: searchResultAssetsForActiveQuery ?? assets,
            filter: selectedFilter,
            attributes: attributeFilter,
            query: LightboxSearchQuery.parse(searchText),
            field: sortField,
            direction: sortDirection,
            reusing: sortedUnfilteredSnapshot
        )
        if let sorted = result.sorted { sortedUnfilteredSnapshot = sorted }
        setCachedActiveAssets(result.assets)
    }

    private func setCachedActiveAssets(_ nextAssets: [LightboxAsset]) {
        // Folder groups show only for search and subfolder results; working
        // them out takes a URL operation per image on every rebuild.
        let grouped = usesRecursiveResults
        guard cachedActiveAssets != nextAssets || cachedSearchAssetGroupsAreGrouped != grouped else { return }
        cachedActiveAssetIDList = nextAssets.map(\.id)
        cachedActiveAssetIDs = Set(cachedActiveAssetIDList)
        cachedSearchAssetGroups = grouped ? makeSearchAssetGroups(for: nextAssets) : []
        cachedSearchAssetGroupsAreGrouped = grouped
        activeAssetsRevision &+= 1
        cachedActiveAssets = nextAssets
    }

    func rebuildActiveFolderEntries() {
        setCachedActiveFolderEntries(GalleryContentFilter.visibleFolders(
            folders: folderEntries,
            searchFolders: searchResultFolderEntries,
            query: LightboxSearchQuery.parse(searchText),
            hasSearchQuery: hasSearchQuery,
            isViewingTrash: isViewingTrash,
            field: sortField,
            direction: sortDirection
        ))
    }

    private func setCachedActiveFolderEntries(_ nextEntries: [LibraryFolderEntry]) {
        guard cachedActiveFolderEntries != nextEntries else { return }
        cachedActiveFolderEntries = nextEntries
    }

    func rebuildLibraryColorTags() {
        let nextTags = GalleryContentFilter.colorTags(in: assets + (searchResultAssetsForActiveQuery ?? []))
        guard cachedLibraryColorTags != nextTags else { return }
        cachedLibraryColorTags = nextTags
    }

    private func sourceKey(for asset: LightboxAsset) -> String? {
        asset.sourceURL?.standardizedFileURL.path
    }
}
