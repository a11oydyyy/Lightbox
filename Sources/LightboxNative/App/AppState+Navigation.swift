import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Locations, sources, folders, the sidebar, pins and the path bar.
extension AppState {
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

    func refreshSidebarDestinations() {
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

    func startSidebarVolumeMonitoring() {
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
        if let status = libraryLoadingStatus, !status.isBackground {
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
        tabSession.updateActive { $0.isStartPage = false }
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
        tabSession.updateActive { $0.isStartPage = false }
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

    func sourceMatches(_ lhs: LibrarySource, _ rhs: LibrarySource) -> Bool {
        lhs.id == rhs.id || lhs.rootURL.standardizedFileURL.path == rhs.rootURL.standardizedFileURL.path
    }

    func bestSource(containing folderURL: URL) -> LibrarySource? {
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

    func saveCurrentFolderSession() {
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
    func clearContentForFolderNavigation() {
        searchTask?.cancel()
        searchMetadata.cancel()
        searchGeneration &+= 1
        recursiveSearchScope = nil
        searchText = ""
        attributeFilter = GalleryAttributeFilter()
        searchStatus = nil
        searchResultAssets = nil
        searchResultFolderEntries = nil
        assets = []
        folderEntries = []
        clearSelection()
        galleryKeyboardFocusID = nil
    }

    func copyCurrentPathToClipboard() {
        let path = currentPathForCopy
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        Self.logger.info("path copied path=\(path, privacy: .public)")
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
}
