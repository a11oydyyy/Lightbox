import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Search, recursive results and their folder groups.
extension AppState {
    var searchAssetGroups: [SearchAssetGroup] {
        cachedSearchAssetGroups
    }

    static let collapsedGroupFoldersKey = "Lightbox.collapsedGroupFolders.v1"
    /// Enough for every folder anyone collapses by hand; the oldest go first.
    static let collapsedGroupFolderLimit = 2_000

    func isGroupCollapsed(_ groupID: SearchAssetGroup.ID) -> Bool {
        collapsedGroupFolderSet.contains(groupID)
    }

    func setGroup(_ groupID: SearchAssetGroup.ID, collapsed: Bool) {
        guard isGroupCollapsed(groupID) != collapsed else { return }
        var paths = collapsedGroupFolderPaths.filter { $0 != groupID }
        if collapsed { paths.append(groupID) }
        saveCollapsedGroupFolders(Array(paths.suffix(Self.collapsedGroupFolderLimit)))
    }

    func saveCollapsedGroupFolders(_ paths: [String]) {
        collapsedGroupFolderPaths = paths
        libraryDefaults.set(paths, forKey: Self.collapsedGroupFoldersKey)
    }

    func makeSearchAssetGroups(for activeAssets: [LightboxAsset]) -> [SearchAssetGroup] {
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

    private func searchGroupTitle(
        for folderURL: URL, path: String, sourceRoots: [(source: LibrarySource, path: String)]
    ) -> String {
        if let root = sourceRoots.filter({ path == $0.path || path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) {
            return path == root.path ? root.source.displayName : String(path.dropFirst(root.path.count + 1))
        }
        return folderURL.lastPathComponent.isEmpty ? path : folderURL.lastPathComponent
    }

    func applySearchResultMetadataUpdates(
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
            if let edited = update.hasCameraRawSettings { asset.hasCameraRawSettings = edited }
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
            if selectedFilter == .all, sortField != .tag, sortField != .dimensions, !attributeFilter.isActive {
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

    var searchResultAssetsForActiveQuery: [LightboxAsset]? {
        guard usesRecursiveResults, !isViewingTrash else { return nil }
        // Recursive results arrive incrementally; avoid mixing in direct-folder cards.
        return searchResultAssets ?? (includesSubfolders ? [] : nil)
    }

    func scheduleSearch(preservingResults: Bool = false, forceRefresh: Bool = false) {
        let scope = RecursiveSearchScope(
            sourceID: selectedSourceID,
            folderPath: currentFolderURL.standardizedFileURL.path,
            showsHiddenItems: showsHiddenItems,
            showsOtherFiles: showsOtherFiles
        )
        // A recursive scan already covers every name. Typing filters that snapshot,
        // including while it is arriving, without restarting NAS I/O or metadata work.
        if !forceRefresh, includesSubfolders, recursiveSearchScope == scope, searchStatus != nil {
            return
        }
        searchTask?.cancel()
        searchMetadata.cancel()
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
        let showsOtherFiles = showsOtherFiles
        searchStatus = LightboxSearchStatus(isSearching: true)

        searchTask = Task.detached(priority: .utility) { [weak self, scanQuery, searchFolder, sourceID, sourceRootURL, currentFolderPath, trimmedSearchText, showsHiddenItems, showsOtherFiles, recursive, generation] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let metadataSnapshot = SearchMetadataSnapshot(knownSearchAssets)
            // Sizes read in earlier sessions, so cards arrive with their shape.
            let storedDimensions = recursive
                ? LightboxIndexStore(databaseURL: indexDatabaseURL)
                    .storedImageDimensions(under: searchFolder.standardizedFileURL.path)
                : [:]

            let publishProgress: @Sendable (LightboxSearchScanResult) -> Void = { [weak self] partial in
                var partial = partial
                if !keepsVisibleSearchSnapshot {
                    partial.assets = SearchMetadataSnapshot.mergingStored(storedDimensions,
                        into: metadataSnapshot.mergingDimensions(into: partial.assets, keepingTags: recursive))
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
                    showsHiddenItems: showsHiddenItems, includesOtherFiles: showsOtherFiles,
                    onProgress: publishProgress
                )
            } else {
                scanned = LocalImageSource.searchAssets(
                    in: searchFolder, sourceID: sourceID, rootURL: sourceRootURL,
                    query: scanQuery, recursive: false, showsHiddenItems: showsHiddenItems,
                    includesOtherFiles: showsOtherFiles, skipsPackages: true, onProgress: publishProgress
                )
            }
            guard !Task.isCancelled else { return }
            scanned.assets = SearchMetadataSnapshot.mergingStored(storedDimensions,
                into: metadataSnapshot.mergingDimensions(into: scanned.assets, keepingTags: recursive))
            let result = scanned

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
                .compactMap { asset -> AssetMetadataTarget? in
                    guard recursive || !asset.metadataLoaded || asset.isImage, let url = asset.sourceURL else { return nil }
                    return AssetMetadataTarget(
                        id: asset.id,
                        url: url,
                        shouldLoadDimensions: !asset.metadataLoaded,
                        shouldLoadTags: recursive,
                        signature: asset.fileContentSignature,
                        shouldCheckCameraRaw: asset.isImage
                    )
                }
            guard !Task.isCancelled else { return }

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
                    discoveredCount: result.assets.count, visitedCount: result.visitedCount,
                    // Set with the results: a gap here reads as "metadata finished".
                    metadataTotal: metadataTargets.count
                )
                self.rebuildActiveAssets()
                self.rebuildActiveFolderEntries()
                self.removeDetachedSelection()
                if !metadataTargets.isEmpty {
                    self.searchMetadata.start(AssetMetadataLoader.Request(
                        targets: metadataTargets, sourceID: sourceID, folderURL: searchFolder,
                        refreshID: generation, startDelayMilliseconds: 0,
                        searchText: recursive ? nil : trimmedSearchText, pacing: .search
                    ))
                }
                return true
            }
            guard didApplySearchResults else { return }
        }
    }

    private func clearSearchResults() {
        searchResultAssets = nil
        searchResultFolderEntries = nil
        rebuildLibraryColorTags()
    }
}
