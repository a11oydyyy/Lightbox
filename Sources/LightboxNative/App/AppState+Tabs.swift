import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Tabs, back/forward history and tab persistence.
extension AppState {
    var activeTab: LightboxTab? { tabSession.activeTab }
    var canGoBack: Bool { tabSession.canGoBack }
    var canGoForward: Bool { tabSession.canGoForward }

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
        tabSession.insert(tab, after: index)
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
        duplicate.selectedAssetIDs = []
        duplicate.selectedAssetID = nil
        tabSession.insert(duplicate, after: index)
        activateTab(duplicate.id, capturingCurrent: false)
    }

    func canCloseTabsAfter(_ tabID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        return index + 1 < tabs.count
    }

    func canCloseOtherTabs(keeping tabID: UUID) -> Bool {
        tabs.contains { $0.id != tabID }
    }

    func closeOtherTabs(keeping tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        closeTabs(Set(tabs.filter { $0.id != tabID }.map(\.id)), keeping: tabID)
    }

    func closeTabsAfter(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        closeTabs(Set(tabs.dropFirst(index + 1).map(\.id)), keeping: tabID)
    }

    private func closeTabs(_ tabIDs: Set<UUID>, keeping tabID: UUID) {
        guard !tabIDs.isEmpty else { return }
        captureActiveTabState()
        let closesActiveTab = tabIDs.contains(activeTabID)
        tabSession.remove(tabIDs)
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

        if tabs.count == 1 {
            captureActiveTabState()
            let source = LibrarySource.defaultStartupSource()
            let resetTab = LightboxTab(source: source, folderURL: source.rootURL, isStartPage: true)
            tabSession.replaceAll(with: [resetTab])
            activateTab(resetTab.id, capturingCurrent: false)
            return
        }

        let closesActiveTab = tabID == activeTabID
        if closesActiveTab {
            captureActiveTabState()
        }
        tabSession.remove([tabID])

        if closesActiveTab {
            let replacementIndex = min(closingIndex, tabs.count - 1)
            activateTab(tabs[replacementIndex].id, capturingCurrent: false)
        } else {
            persistTabsImmediately()
        }
    }

    func reorderTabs(_ ids: [UUID], before target: UUID?) {
        guard tabSession.reorder(ids, before: target) else { return }
        persistTabsImmediately()
    }

    func goBack() {
        guard let destination = tabSession.stepBack(from: currentLocation) else { return }
        performHistoryNavigation(to: destination)
    }

    func goForward() {
        guard let destination = tabSession.stepForward(from: currentLocation) else { return }
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

    var activeTabIndex: Int? { tabSession.activeTabIndex }

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
        tabSession.activate(tab.id)
        selectedGalleryFolderID = nil
        galleryKeyboardFocusID = nil
        tabSession.update(tab.id) { $0.source = resolvedSource }
        temporarySource = sources.contains(where: { sourceMatches($0, resolvedSource) }) ? nil : resolvedSource
        selectedSourceID = resolvedSource.id
        currentFolderURL = tab.folderURL
        selectedFilter = tab.filter
        searchText = tab.searchText
        attributeFilter = tab.attributeFilter
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
        scrollRestoreLogger.info("tab applied cached=\(restoredContent) anchor=\(tab.scrollAnchorAssetID.map { String($0.suffix(24)) } ?? "nil", privacy: .public) generation=\(self.scrollRestoreGeneration)")
        Self.logger.info("tab applied cached=\(restoredContent) assets=\(self.cachedActiveAssets.count) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
    }

    private func cacheActiveTabContent() {
        guard let index = activeTabIndex, !isShowingStartPage, !isViewingTrash,
              libraryLoadingStatus == nil, searchStatus?.isSearching != true,
              !usesRecursiveResults || searchResultAssets != nil else { return }
        let snapshot = TabContentSnapshot(
            tab: tabs[index], showsHiddenItems: showsHiddenItems, showsOtherFiles: showsOtherFiles,
            includesSubfolders: includesSubfolders, assets: assets, folders: folderEntries,
            searchAssets: searchResultAssets, searchFolders: searchResultFolderEntries,
            searchStatus: searchStatus, activeAssets: cachedActiveAssets,
            activeIDs: cachedActiveAssetIDs, activeIDList: cachedActiveAssetIDList,
            groups: cachedSearchAssetGroups, activeFolders: cachedActiveFolderEntries,
            colorTags: cachedLibraryColorTags
        )
        // Retain metadata, not decoded pixels; `TabSession` bounds both tab
        // count and library size.
        tabSession.cacheContent(snapshot, for: activeTabID)
    }

    private func restoreTabContent(_ tab: LightboxTab) -> Bool {
        guard let snapshot = tabSession.cachedContent(for: tab.id),
              snapshot.tab.source.id == selectedSourceID,
              snapshot.tab.folderURL == currentFolderURL,
              snapshot.tab.searchText == searchText,
              snapshot.tab.filter == selectedFilter,
              snapshot.tab.attributeFilter == attributeFilter,
              snapshot.tab.sortField == sortField,
              snapshot.tab.sortDirection == sortDirection,
              snapshot.tab.layoutMode == galleryLayoutMode,
              snapshot.includesSubfolders == includesSubfolders,
              snapshot.showsHiddenItems == showsHiddenItems,
              snapshot.showsOtherFiles == showsOtherFiles else { return false }
        assets = snapshot.assets
        folderEntries = snapshot.folders
        searchResultAssets = snapshot.searchAssets
        searchResultFolderEntries = snapshot.searchFolders
        searchStatus = snapshot.searchStatus
        cachedActiveAssetIDs = snapshot.activeIDs
        cachedActiveAssetIDList = snapshot.activeIDList
        cachedSearchAssetGroups = snapshot.groups
        cachedSearchAssetGroupsAreGrouped = nil
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
        let tab = LightboxTab(
            source: source,
            folderURL: folderURL,
            filter: filter,
            sortField: .time,
            sortDirection: .descending,
            layoutMode: galleryLayoutMode,
            thumbnailWidth: thumbnailWidth
        )
        tabSession.insert(tab, after: activeTabIndex)
        activateTab(tab.id, capturingCurrent: false)
    }

    func captureActiveTabState() {
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
        snapshot.attributeFilter = attributeFilter
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
        tabSession.updateActive { $0 = snapshot }
        scheduleTabPersistence()
    }

    func recordNavigation(
        to source: LibrarySource,
        folderURL: URL,
        filter: LibraryFilter
    ) {
        guard !isApplyingTabState,
              !isPerformingHistoryNavigation,
              activeTabIndex != nil,
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

        tabSession.recordVisit(leaving: currentLocation)
        scheduleTabPersistence()
    }

    private func performHistoryNavigation(to destination: LightboxTabLocation) {
        cancelPendingFolderPath()
        closeOverlaysForTabSwitch()
        isPerformingHistoryNavigation = true
        isApplyingTabState = true
        clearContentForFolderNavigation()

        tabSession.updateActive { $0.isStartPage = destination.isStartPage }
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

    func resetScrollForNavigation() {
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

    func suspendActiveTabWork() {
        refreshTask?.cancel()
        refreshTask = nil
        libraryLoadTask?.cancel()
        libraryLoadTask = nil
        assetMetadata.cancel()
        indexWriteTask?.cancel()
        indexWriteTask = nil
        searchTask?.cancel()
        searchMetadata.cancel()
        searchGeneration &+= 1
        searchTask = nil
        recursiveSearchScope = nil
        folderWatcher.stop()
        libraryLoadingStatus = nil
        refreshSerial += 1
        ImageCache.shared.cancelOutstandingRequests(reason: "switch-tab")
    }

    private var folderSortPreferenceKey: String {
        let location = isViewingTrash ? "trash" : "folder:" + currentFolderURL.standardizedFileURL.path
        return "Lightbox.folderSort.v1." + location
    }

    func saveFolderSort() {
        guard !isShowingStartPage else { return }
        libraryDefaults.set(["field": sortField.rawValue, "direction": sortDirection.rawValue],
                            forKey: folderSortPreferenceKey)
    }

    func restoreFolderSort(resetUnconfigured: Bool = true) {
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

    func scheduleTabPersistence() {
        tabSession.scheduleSave()
    }

    func persistTabsImmediately() {
        tabSession.saveNow()
    }
}
