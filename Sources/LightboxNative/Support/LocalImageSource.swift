import Darwin
import Foundation
import OSLog

struct LocalFolderSnapshot: Sendable {
    var entryCount: Int
    var folders: [LibraryFolderEntry]
    var assets: [LightboxAsset]
    var directoryReadSeconds: TimeInterval
    var classificationSeconds: TimeInterval
    var metadataProbeSeconds: TimeInterval
    var sortSeconds: TimeInterval
}

struct SystemTrashSnapshot: Sendable {
    var assets: [LightboxAsset]
    var inaccessibleFolders: [URL]
}

enum LocalImageSource {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "DirectoryScan")
    private static let supportedImageExtensions = Set([
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff",
        "raw", "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "rw2", "orf", "ori", "pef", "srw", "x3f", "erf", "rwl", "3fr",
        "mef", "mos", "mrw", "dcr", "kdc", "fff", "iiq", "ari", "bay"
    ])
    private static let pendingMetadataSize = CGSize(width: 1, height: 1)
    private static let folderSnapshotResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .addedToDirectoryDateKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey
    ]

    static func isSupportedImageURL(_ url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func loadAssets(
        in folder: URL,
        isDeleted: Bool = false,
        recursive: Bool = false,
        probeMetadata: Bool = true
    ) -> [LightboxAsset] {
        imageURLs(in: folder, recursive: recursive).enumerated().map { index, url in
            let fallbackSize = MockLibrary.importFallbackSizes[index % MockLibrary.importFallbackSizes.count]
            let size = probeMetadata ? ImageProbe.dimensions(for: url) ?? fallbackSize : fallbackSize
            let addedAt = addedDate(for: url) ?? .distantPast
            return LightboxAsset(
                originalName: url.lastPathComponent,
                width: size.width,
                height: size.height,
                tags: probeMetadata ? FinderTagStore.colorTags(for: url) : [],
                sourceURL: url,
                addedAt: addedAt,
                fileSize: fileSize(for: url),
                palette: MockPalette.imported[index % MockPalette.imported.count],
                deletedAt: isDeleted ? addedAt : nil,
                metadataLoaded: probeMetadata
            )
        }
        .sorted(by: sortByAddedDate)
    }

    static func loadSystemTrashAssets(in folders: [URL]) -> [LightboxAsset] {
        loadSystemTrashSnapshot(in: folders).assets
    }

    static func loadSystemTrashSnapshot(in folders: [URL]) -> SystemTrashSnapshot {
        var inaccessibleFolders: [URL] = []
        let assets = folders.flatMap { folder in
            let entries = directoryChildrenResult(
                in: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let imageURLs = entries.urls.filter(isSupportedImageURL)
            let imageNames = imageURLs
                .prefix(8)
                .map(\.lastPathComponent)
                .joined(separator: ",")
            let folderAssets = imageURLs.enumerated().map { index, url in
                let fallbackSize = MockLibrary.importFallbackSizes[index % MockLibrary.importFallbackSizes.count]
                let size = ImageProbe.dimensions(for: url) ?? fallbackSize
                let addedAt = addedDate(for: url) ?? .distantPast
                return LightboxAsset(
                    originalName: url.lastPathComponent,
                    width: size.width,
                    height: size.height,
                    tags: FinderTagStore.colorTags(for: url),
                    sourceURL: url,
                    addedAt: addedAt,
                    fileSize: fileSize(for: url),
                    palette: MockPalette.imported[index % MockPalette.imported.count],
                    deletedAt: addedAt,
                    metadataLoaded: true
                )
            }
            if entries.accessDenied {
                inaccessibleFolders.append(folder)
            }
            logger.info("system-trash folder scanned path=\(folder.path, privacy: .public) entries=\(entries.urls.count) assets=\(folderAssets.count) denied=\(entries.accessDenied) images=\(imageNames, privacy: .public)")
            return folderAssets
        }
        .sorted(by: sortByAddedDate)

        return SystemTrashSnapshot(assets: assets, inaccessibleFolders: inaccessibleFolders)
    }

    static func searchFolders(
        in folder: URL,
        sourceID: LibrarySource.ID,
        rootURL: URL,
        query: LightboxSearchQuery,
        recursive: Bool,
        maxResults: Int = 300,
        maxVisited: Int = 20_000
    ) -> LightboxSearchScanResult {
        let startedAt = Date()
        var folders: [LibraryFolderEntry] = []
        folders.reserveCapacity(min(maxResults, 64))
        var visitedCount = 0
        var limitReached = false

        func visit(_ url: URL) {
            guard !Task.isCancelled else { return }
            visitedCount += 1
            if visitedCount > maxVisited {
                limitReached = true
                return
            }

            guard query.mayMatchFolderName(url.lastPathComponent) else {
                return
            }

            let folder = LibraryFolderEntry(
                sourceID: sourceID,
                url: url.standardizedFileURL,
                rootURL: rootURL.standardizedFileURL,
                tags: []
            )
            guard query.matches(folder) else { return }
            if folders.count < maxResults {
                folders.append(folder)
                return
            }

            limitReached = true
        }

        func directoryEntries(in folder: URL) -> [POSIXDirectoryEntry] {
            let posix = posixDirectoryEntries(in: folder, options: [.skipsHiddenFiles]).urls
            if !posix.isEmpty { return posix }
            return directoryChildren(
                in: folder,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ).map { POSIXDirectoryEntry(url: $0, isDirectory: nil, isRegularFile: nil) }
        }

        func isDirectory(_ entry: POSIXDirectoryEntry) -> Bool {
            if let isDirectory = entry.isDirectory {
                return isDirectory
            }
            let values = try? entry.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                return false
            }
            return values?.isDirectory == true
        }

        if recursive {
            var stack = [folder.standardizedFileURL]
            while let directory = stack.popLast() {
                guard !Task.isCancelled, !limitReached else { break }
                for entry in directoryEntries(in: directory) {
                    guard !Task.isCancelled, !limitReached else { break }
                    guard isDirectory(entry) else { continue }
                    visit(entry.url)
                    stack.append(entry.url)
                }
            }
        } else {
            for entry in directoryEntries(in: folder) {
                guard isDirectory(entry) else { continue }
                visit(entry.url)
            }
        }

        let sortedFolders = sortedSearchFolders(folders)
        logger.info("folder-search complete path=\(folder.path, privacy: .public) recursive=\(recursive) visited=\(visitedCount) folders=\(sortedFolders.count) limit=\(limitReached) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
        return LightboxSearchScanResult(
            assets: [],
            folders: sortedFolders,
            visitedCount: visitedCount,
            limitReached: limitReached
        )
    }

    static func loadFolderSnapshot(
        in folder: URL,
        sourceID: LibrarySource.ID,
        rootURL: URL,
        probeMetadata: Bool = true,
        initialMetadataLimit: Int = 0,
        cachedDimensions: [String: CachedAssetDimensions] = [:]
    ) -> LocalFolderSnapshot {
        let readStartedAt = Date()
        var entries = posixDirectoryEntries(in: folder.standardizedFileURL, options: [.skipsHiddenFiles]).urls
        if entries.isEmpty {
            entries = directoryChildrenResult(
                in: folder,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ).urls.map { POSIXDirectoryEntry(url: $0, isDirectory: nil, isRegularFile: nil) }
        }
        let directoryReadSeconds = Date().timeIntervalSince(readStartedAt)
        let classificationKeys = Set(folderSnapshotClassificationKeys(probeMetadata: probeMetadata))

        var folders: [LibraryFolderEntry] = []
        var assets: [LightboxAsset] = []
        folders.reserveCapacity(min(entries.count, 64))
        assets.reserveCapacity(entries.count)

        let classifyStartedAt = Date()
        for entry in entries {
            let url = entry.url
            let values = try? url.resourceValues(forKeys: classificationKeys)
            if entry.isDirectory ?? (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                folders.append(LibraryFolderEntry(
                    sourceID: sourceID,
                    url: url.standardizedFileURL,
                    rootURL: rootURL.standardizedFileURL,
                    tags: FinderTagStore.colorTags(for: url)
                ))
                continue
            }

            guard isSupportedImageURL(url) else {
                continue
            }
            if let isRegularFile = entry.isRegularFile, !isRegularFile {
                continue
            }

            let index = assets.count
            let fallbackSize = MockLibrary.importFallbackSizes[index % MockLibrary.importFallbackSizes.count]
            let cachedSize = cachedDimensions[url.standardizedFileURL.path]
            let size: CGSize
            let metadataLoaded: Bool
            if probeMetadata {
                size = ImageProbe.dimensions(for: url) ?? fallbackSize
                metadataLoaded = true
            } else if let cachedSize {
                size = CGSize(width: cachedSize.width, height: cachedSize.height)
                metadataLoaded = true
            } else {
                size = Self.pendingMetadataSize
                metadataLoaded = false
            }
            let addedAt = addedDate(from: values) ?? .distantPast
            assets.append(LightboxAsset(
                originalName: url.lastPathComponent,
                width: size.width,
                height: size.height,
                tags: probeMetadata ? FinderTagStore.colorTags(for: url) : [],
                sourceURL: url,
                addedAt: addedAt,
                fileSize: fileSize(from: values),
                palette: MockPalette.imported[index % MockPalette.imported.count],
                metadataLoaded: metadataLoaded
            ))
        }
        let classificationSeconds = Date().timeIntervalSince(classifyStartedAt)

        let sortStartedAt = Date()
        let sortedFolders = folders.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        var sortedAssets = assets.sorted(by: sortByAddedDate)
        let sortSeconds = Date().timeIntervalSince(sortStartedAt)

        let metadataProbeStartedAt = Date()
        var metadataProbeCount = 0
        if !probeMetadata, initialMetadataLimit > 0 {
            for index in sortedAssets.indices {
                guard metadataProbeCount < initialMetadataLimit else { break }
                guard !sortedAssets[index].metadataLoaded else { continue }
                guard let url = sortedAssets[index].sourceURL else {
                    continue
                }
                metadataProbeCount += 1
                guard
                      let size = ImageProbe.dimensions(for: url)
                else {
                    continue
                }
                sortedAssets[index].width = size.width
                sortedAssets[index].height = size.height
                sortedAssets[index].metadataLoaded = true
            }
        }
        let metadataProbeSeconds = Date().timeIntervalSince(metadataProbeStartedAt)

        logger.info("folder-scan complete path=\(folder.path, privacy: .public) probe=\(probeMetadata) cachedDimensions=\(cachedDimensions.count) initialProbe=\(metadataProbeCount)/\(initialMetadataLimit) entries=\(entries.count) folders=\(sortedFolders.count) assets=\(sortedAssets.count) read=\(directoryReadSeconds, format: .fixed(precision: 2))s classify=\(classificationSeconds, format: .fixed(precision: 2))s metadataProbe=\(metadataProbeSeconds, format: .fixed(precision: 2))s sort=\(sortSeconds, format: .fixed(precision: 2))s")

        return LocalFolderSnapshot(
            entryCount: entries.count,
            folders: sortedFolders,
            assets: sortedAssets,
            directoryReadSeconds: directoryReadSeconds,
            classificationSeconds: classificationSeconds,
            metadataProbeSeconds: metadataProbeSeconds,
            sortSeconds: sortSeconds
        )
    }

    static func searchAssets(
        in folder: URL,
        sourceID: LibrarySource.ID,
        rootURL: URL,
        query: LightboxSearchQuery,
        recursive: Bool,
        maxResults: Int = 2_000,
        maxFolderResults: Int = 300,
        maxVisited: Int = 20_000
    ) -> LightboxSearchScanResult {
        let startedAt = Date()

        var assets: [LightboxAsset] = []
        assets.reserveCapacity(min(maxResults, 256))
        var folders: [LibraryFolderEntry] = []
        folders.reserveCapacity(min(maxFolderResults, 64))
        var visitedCount = 0
        var traversalLimitReached = false
        var resultLimitReached = false

        func directoryEntries(in folder: URL) -> [POSIXDirectoryEntry] {
            let posix = posixDirectoryEntries(in: folder, options: [.skipsHiddenFiles]).urls
            if !posix.isEmpty { return posix }
            return directoryChildren(
                in: folder,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ).map { POSIXDirectoryEntry(url: $0, isDirectory: nil, isRegularFile: nil) }
        }

        func isDirectory(_ entry: POSIXDirectoryEntry) -> Bool {
            if let isDirectory = entry.isDirectory {
                return isDirectory
            }
            let values = try? entry.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                return false
            }
            return values?.isDirectory == true
        }

        func visit(_ entry: POSIXDirectoryEntry, knownIsDirectory: Bool? = nil) -> Bool {
            guard !Task.isCancelled else { return true }
            let url = entry.url
            visitedCount += 1
            if visitedCount > maxVisited {
                traversalLimitReached = true
                resultLimitReached = true
                return true
            }

            let mayMatchFolder = query.mayMatchFolderName(url.lastPathComponent)
            let mayMatchAsset = isSupportedImageURL(url) && query.mayMatchAssetName(url.lastPathComponent)
            guard mayMatchFolder || mayMatchAsset else {
                return false
            }

            let entryIsDirectory = knownIsDirectory ?? isDirectory(entry)
            if entryIsDirectory {
                guard mayMatchFolder else { return false }
                let folder = LibraryFolderEntry(
                    sourceID: sourceID,
                    url: url.standardizedFileURL,
                    rootURL: rootURL.standardizedFileURL,
                    tags: []
                )
                guard query.matches(folder) else { return false }
                if folders.count < maxFolderResults {
                    folders.append(folder)
                } else {
                    resultLimitReached = true
                }
                return false
            }

            guard mayMatchAsset else { return false }
            if let isRegularFile = entry.isRegularFile, !isRegularFile { return false }

            let fallbackSize = MockLibrary.importFallbackSizes[assets.count % MockLibrary.importFallbackSizes.count]
            let values = try? url.resourceValues(forKeys: [
                .addedToDirectoryDateKey,
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey
            ])
            let asset = LightboxAsset(
                originalName: url.lastPathComponent,
                width: fallbackSize.width,
                height: fallbackSize.height,
                tags: FinderTagStore.colorTags(for: url),
                sourceURL: url,
                addedAt: addedDate(from: values) ?? .distantPast,
                fileSize: fileSize(from: values),
                palette: MockPalette.imported[assets.count % MockPalette.imported.count],
                metadataLoaded: false
            )

            guard query.matches(asset) else { return false }
            assets.append(asset)
            if assets.count >= maxResults {
                traversalLimitReached = true
                resultLimitReached = true
                return true
            }
            return false
        }

        if recursive {
            var stack = [folder.standardizedFileURL]
            while let directory = stack.popLast() {
                guard !Task.isCancelled, !traversalLimitReached else { break }
                for entry in directoryEntries(in: directory) {
                    guard !Task.isCancelled, !traversalLimitReached else { break }
                    let entryIsDirectory = isDirectory(entry)
                    if entryIsDirectory {
                        if visit(entry, knownIsDirectory: true) {
                            break
                        }
                        stack.append(entry.url)
                    } else if visit(entry, knownIsDirectory: false) {
                        break
                    }
                }
            }
        } else {
            for entry in directoryEntries(in: folder) {
                if visit(entry) {
                    break
                }
            }
        }

        let sortedAssets = assets.sorted { lhs, rhs in
            let lhsParent = lhs.sourceURL?.deletingLastPathComponent().path ?? ""
            let rhsParent = rhs.sourceURL?.deletingLastPathComponent().path ?? ""
            if lhsParent != rhsParent {
                return lhsParent.localizedStandardCompare(rhsParent) == .orderedAscending
            }
            return lhs.originalName.localizedStandardCompare(rhs.originalName) == .orderedAscending
        }
        let sortedFolders = sortedSearchFolders(folders)
        logger.info("search scan complete path=\(folder.path, privacy: .public) recursive=\(recursive) visited=\(visitedCount) folders=\(sortedFolders.count) results=\(sortedAssets.count) limit=\(resultLimitReached) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
        return LightboxSearchScanResult(
            assets: sortedAssets,
            folders: sortedFolders,
            visitedCount: visitedCount,
            limitReached: resultLimitReached
        )
    }

    private static func folderSnapshotClassificationKeys(probeMetadata: Bool) -> [URLResourceKey] {
        guard probeMetadata else {
            return [
                .isDirectoryKey,
                .addedToDirectoryDateKey,
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey
            ]
        }
        return folderSnapshotResourceKeys
    }

    private static func sortedSearchFolders(
        _ folders: [LibraryFolderEntry]
    ) -> [LibraryFolderEntry] {
        folders.sorted {
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    static func imageURLs(in folder: URL) -> [URL] {
        imageURLs(in: folder, recursive: true)
    }

    static func imageURLs(in folder: URL, recursive: Bool) -> [URL] {
        let urls: [URL]

        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = directoryChildren(
                in: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        }

        return urls
            .filter { url in
                isSupportedImageURL(url)
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    private static func directoryChildren(
        in folder: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions
    ) -> [URL] {
        directoryChildrenResult(
            in: folder,
            includingPropertiesForKeys: keys,
            options: options
        ).urls
    }

    private struct DirectoryChildrenResult {
        var urls: [URL]
        var accessDenied: Bool
    }

    private struct POSIXDirectoryEntry {
        var url: URL
        var isDirectory: Bool?
        var isRegularFile: Bool?
    }

    private static func directoryChildrenResult(
        in folder: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions
    ) -> DirectoryChildrenResult {
        let standardizedFolder = folder.standardizedFileURL
        let fileManager = FileManager.default
        var accessDenied = false
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: standardizedFolder,
                includingPropertiesForKeys: keys,
                options: options
            )
            if !urls.isEmpty {
                return DirectoryChildrenResult(urls: urls, accessDenied: false)
            }
        } catch {
            accessDenied = true
            logger.error("directory url read failed path=\(standardizedFolder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        do {
            let names = try fileManager.contentsOfDirectory(atPath: standardizedFolder.path)
            let urls = childURLs(from: names, folder: standardizedFolder, options: options)
            if !urls.isEmpty {
                return DirectoryChildrenResult(urls: urls, accessDenied: accessDenied)
            }
        } catch {
            accessDenied = true
            logger.error("directory path read failed path=\(standardizedFolder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        let posixResult = posixDirectoryChildren(in: standardizedFolder, options: options)
        accessDenied = accessDenied || posixResult.accessDenied
        if !posixResult.urls.isEmpty {
            return DirectoryChildrenResult(urls: posixResult.urls, accessDenied: accessDenied)
        }

        return DirectoryChildrenResult(urls: [], accessDenied: accessDenied)
    }

    private static func childURLs(
        from names: [String],
        folder: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) -> [URL] {
        return names
            .filter { name in
                !(options.contains(.skipsHiddenFiles) && name.hasPrefix("."))
            }
            .map { name in
                folder.appendingPathComponent(name)
            }
    }

    private static func posixDirectoryChildren(
        in folder: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) -> DirectoryChildrenResult {
        let entries = posixDirectoryEntries(in: folder, options: options)
        return DirectoryChildrenResult(
            urls: entries.urls.map(\.url),
            accessDenied: entries.accessDenied
        )
    }

    private static func posixDirectoryEntries(
        in folder: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) -> (urls: [POSIXDirectoryEntry], accessDenied: Bool) {
        let path = folder.path
        guard let directory = opendir(path) else {
            let accessDenied = errno == EACCES || errno == EPERM
            logger.error("directory posix read failed path=\(path, privacy: .public) errno=\(errno)")
            return ([], accessDenied)
        }
        defer {
            closedir(directory)
        }

        var entries: [POSIXDirectoryEntry] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else {
                continue
            }
            guard !(options.contains(.skipsHiddenFiles) && name.hasPrefix(".")) else {
                continue
            }

            let type = entry.pointee.d_type
            let isDirectory: Bool?
            let isRegularFile: Bool?
            switch type {
            case UInt8(DT_DIR):
                isDirectory = true
                isRegularFile = false
            case UInt8(DT_REG):
                isDirectory = false
                isRegularFile = true
            default:
                isDirectory = nil
                isRegularFile = nil
            }
            entries.append(POSIXDirectoryEntry(
                url: folder.appendingPathComponent(name),
                isDirectory: isDirectory,
                isRegularFile: isRegularFile
            ))
        }

        return (entries, false)
    }

    static func folders(in folder: URL, sourceID: LibrarySource.ID, rootURL: URL) -> [LibraryFolderEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            return LibraryFolderEntry(
                sourceID: sourceID,
                url: url.standardizedFileURL,
                rootURL: rootURL.standardizedFileURL,
                tags: FinderTagStore.colorTags(for: url)
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func tags(for size: CGSize, base: [String] = []) -> [String] {
        base
    }

    private static func addedDate(from values: URLResourceValues?) -> Date? {
        values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate
    }

    static func addedDate(for url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey
        ]) else {
            return nil
        }

        return addedDate(from: values)
    }

    static func fileSize(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }

        return fileSize(from: values)
    }

    private static func fileSize(from values: URLResourceValues?) -> Int64? {
        values?.fileSize.map(Int64.init)
    }

    private static func sortByAddedDate(_ lhs: LightboxAsset, _ rhs: LightboxAsset) -> Bool {
        if lhs.addedAt != rhs.addedAt {
            return lhs.addedAt > rhs.addedAt
        }

        return lhs.originalName.localizedStandardCompare(rhs.originalName) == .orderedAscending
    }
}
