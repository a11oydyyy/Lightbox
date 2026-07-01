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

    static func loadAssets(libraryFolder: URL) -> [LightboxAsset] {
        let sources = imageURLs(in: libraryFolder).map {
            (url: $0, isDeleted: false)
        } + LightboxLibraryStore.systemTrashFolders.flatMap { trashFolder in
            imageURLs(in: trashFolder, recursive: false)
        }.map {
            (url: $0, isDeleted: true)
        }

        return sources.enumerated().map { index, source in
            let url = source.url
            let size = ImageProbe.dimensions(for: url) ?? MockLibrary.importFallbackSizes[index % MockLibrary.importFallbackSizes.count]
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
                deletedAt: source.isDeleted ? addedAt : nil
            )
        }
        .sorted(by: sortByAddedDate)
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

    static func loadFolderSnapshot(
        in folder: URL,
        sourceID: LibrarySource.ID,
        rootURL: URL,
        probeMetadata: Bool = true,
        initialMetadataLimit: Int = 0,
        cachedDimensions: [String: CachedAssetDimensions] = [:]
    ) -> LocalFolderSnapshot {
        let readStartedAt = Date()
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: folderSnapshotResourceKeys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            let elapsed = Date().timeIntervalSince(readStartedAt)
            logger.error("folder-scan read failed path=\(folder.path, privacy: .public) seconds=\(elapsed, format: .fixed(precision: 2)) error=\(String(describing: error), privacy: .public)")
            return LocalFolderSnapshot(
                entryCount: 0,
                folders: [],
                assets: [],
                directoryReadSeconds: elapsed,
                classificationSeconds: 0,
                metadataProbeSeconds: 0,
                sortSeconds: 0
            )
        }
        let directoryReadSeconds = Date().timeIntervalSince(readStartedAt)

        var folders: [LibraryFolderEntry] = []
        var assets: [LightboxAsset] = []
        folders.reserveCapacity(min(urls.count, 64))
        assets.reserveCapacity(urls.count)

        let classifyStartedAt = Date()
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(folderSnapshotResourceKeys))
            if values?.isDirectory == true {
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

        logger.info("folder-scan complete path=\(folder.path, privacy: .public) probe=\(probeMetadata) cachedDimensions=\(cachedDimensions.count) initialProbe=\(metadataProbeCount)/\(initialMetadataLimit) entries=\(urls.count) folders=\(sortedFolders.count) assets=\(sortedAssets.count) read=\(directoryReadSeconds, format: .fixed(precision: 2))s classify=\(classificationSeconds, format: .fixed(precision: 2))s metadataProbe=\(metadataProbeSeconds, format: .fixed(precision: 2))s sort=\(sortSeconds, format: .fixed(precision: 2))s")

        return LocalFolderSnapshot(
            entryCount: urls.count,
            folders: sortedFolders,
            assets: sortedAssets,
            directoryReadSeconds: directoryReadSeconds,
            classificationSeconds: classificationSeconds,
            metadataProbeSeconds: metadataProbeSeconds,
            sortSeconds: sortSeconds
        )
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
        let path = folder.path
        guard let directory = opendir(path) else {
            let accessDenied = errno == EACCES || errno == EPERM
            logger.error("directory posix read failed path=\(path, privacy: .public) errno=\(errno)")
            return DirectoryChildrenResult(urls: [], accessDenied: accessDenied)
        }
        defer {
            closedir(directory)
        }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else {
                continue
            }
            names.append(name)
        }

        return DirectoryChildrenResult(
            urls: childURLs(from: names, folder: folder, options: options),
            accessDenied: false
        )
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
