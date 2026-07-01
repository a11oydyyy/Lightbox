import Darwin
import Foundation
import OSLog

enum LightboxLibraryStore {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "LibraryStore")
    private static let libraryFolderKey = "Lightbox.libraryFolder"
    private static let migratedLegacyImportsKey = "Lightbox.migratedLegacyImports"
    private static let trashRestoreDestinationsKey = "Lightbox.trashRestoreDestinations"

    static var applicationSupportFolder: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox", isDirectory: true)
    }

    static var cacheFolder: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox", isDirectory: true)
    }

    static var defaultLibraryFolder: URL {
        applicationSupportFolder.appendingPathComponent("Library", isDirectory: true)
    }

    static var favoritesFolder: URL {
        libraryFolder
    }

    static var favoritesImportedFolder: URL {
        favoritesFolder.appendingPathComponent("Imported", isDirectory: true)
    }

    static var legacyImportsFolder: URL {
        applicationSupportFolder.appendingPathComponent("Imports", isDirectory: true)
    }

    static var primarySystemTrashFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    static var systemTrashFolders: [URL] {
        let uid = Int(getuid())
        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        let volumeTrashFolders = mountedVolumes.map {
            $0.appendingPathComponent(".Trashes/\(uid)", isDirectory: true)
        }

        var seenPaths = Set<String>()
        return ([primarySystemTrashFolder] + volumeTrashFolders).compactMap { folder in
            let standardized = folder.standardizedFileURL
            guard isExistingDirectory(standardized),
                  seenPaths.insert(standardized.path).inserted
            else {
                return nil
            }
            return standardized
        }
    }

    static var indexDatabaseURL: URL {
        cacheFolder.appendingPathComponent("Lightbox.sqlite", isDirectory: false)
    }

    static var libraryFolder: URL {
        guard let path = UserDefaults.standard.string(forKey: libraryFolderKey),
              !path.isEmpty
        else {
            return defaultLibraryFolder
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setLibraryFolder(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: libraryFolderKey)
    }

    static func prepareStorage() {
        createDirectory(defaultLibraryFolder)
        createDirectory(libraryFolder)
        createDirectory(favoritesImportedFolder)
        migrateLegacyImagesIfNeeded()
    }

    static func copyIntoLibrary(_ sourceURL: URL, libraryFolder: URL, preferredName: String? = nil) -> URL? {
        copyImage(sourceURL, into: libraryFolder, preferredName: preferredName)
    }

    static func copyDataIntoLibrary(
        _ data: Data,
        suggestedName: String?,
        pathExtension: String,
        libraryFolder: URL
    ) -> URL? {
        createDirectory(libraryFolder)

        let sourceName = sanitizedFileName(suggestedName) ?? "Image"
        let source = URL(fileURLWithPath: sourceName)
        let extensionToUse = source.pathExtension.isEmpty ? pathExtension : source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = uniqueDestination(
            baseName: baseName,
            pathExtension: extensionToUse,
            folder: libraryFolder
        )

        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    static func moveToSystemTrash(_ sourceURL: URL) -> Bool {
        let source = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            return false
        }

        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
            if let resultingURL {
                recordRestoreDestination(originalURL: source, trashURL: resultingURL as URL)
            }
            return true
        } catch {
            return false
        }
    }

    static func isSystemTrashURL(_ url: URL) -> Bool {
        let sourcePath = url.standardizedFileURL.path
        return systemTrashFolders.contains { folder in
            sourcePath == folder.path || sourcePath.hasPrefix(folder.path + "/")
        }
    }

    static func restoreFromSystemTrash(_ sourceURL: URL) async -> Bool {
        let source = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path),
              isSystemTrashURL(source)
        else {
            return false
        }

        return await Task.detached(priority: .userInitiated) {
            restoreFromSystemTrashSynchronously(source)
        }.value
    }

    private static func restoreFromSystemTrashSynchronously(_ source: URL) -> Bool {
        if restoreFromRecordedDestination(source) {
            return true
        }

        let restored = restoreWithFinder(source)
        if restored {
            clearRestoreDestination(forTrashURL: source)
        }
        return restored
    }

    static func restoreDestination(forTrashURL trashURL: URL, defaults: UserDefaults = .standard) -> URL? {
        let map = trashRestoreDestinations(defaults: defaults)
        guard let path = map[restoreDestinationKey(for: trashURL)] else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static func recordRestoreDestination(
        originalURL: URL,
        trashURL: URL,
        defaults: UserDefaults = .standard
    ) {
        var map = trashRestoreDestinations(defaults: defaults)
        map[restoreDestinationKey(for: trashURL)] = originalURL.standardizedFileURL.path
        defaults.set(map, forKey: trashRestoreDestinationsKey)
    }

    static func clearRestoreDestination(forTrashURL trashURL: URL, defaults: UserDefaults = .standard) {
        var map = trashRestoreDestinations(defaults: defaults)
        map.removeValue(forKey: restoreDestinationKey(for: trashURL))
        defaults.set(map, forKey: trashRestoreDestinationsKey)
    }

    static func restoreFromRecordedDestination(_ source: URL, defaults: UserDefaults = .standard) -> Bool {
        let source = source.standardizedFileURL
        guard let destination = restoreDestination(forTrashURL: source, defaults: defaults) else {
            return false
        }

        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard isExistingDirectory(parent) else {
            return false
        }

        let didAccessSource = source.startAccessingSecurityScopedResource()
        let didAccessDestination = parent.startAccessingSecurityScopedResource()
        defer {
            if didAccessSource {
                source.stopAccessingSecurityScopedResource()
            }
            if didAccessDestination {
                parent.stopAccessingSecurityScopedResource()
            }
        }

        let finalDestination: URL
        if FileManager.default.fileExists(atPath: destination.path) {
            finalDestination = uniqueDestination(
                baseName: destination.deletingPathExtension().lastPathComponent,
                pathExtension: destination.pathExtension,
                folder: parent
            )
        } else {
            finalDestination = destination
        }

        do {
            try FileManager.default.moveItem(at: source, to: finalDestination)
            clearRestoreDestination(forTrashURL: source, defaults: defaults)
            return true
        } catch {
            logger.error("recorded trash restore failed source=\(source.path, privacy: .public) destination=\(finalDestination.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func restoreWithFinder(_ source: URL) -> Bool {
        let escapedPath = source.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Finder"
            set trashItem to POSIX file "\(escapedPath)" as alias
            put back trashItem
        end tell
        """

        var error: NSDictionary?
        let result = NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
        return result != nil && error == nil
    }

    private static func trashRestoreDestinations(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: trashRestoreDestinationsKey) as? [String: String] ?? [:]
    }

    private static func restoreDestinationKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func migrateLegacyImagesIfNeeded() {
        let defaults = UserDefaults.standard

        if !defaults.bool(forKey: migratedLegacyImportsKey) {
            copyImages(from: legacyImportsFolder, into: defaultLibraryFolder)
            defaults.set(true, forKey: migratedLegacyImportsKey)
        }

    }

    private static func copyImages(from sourceFolder: URL, into destinationFolder: URL) {
        for url in LocalImageSource.imageURLs(in: sourceFolder) {
            _ = copyImage(url, into: destinationFolder)
        }
    }

    private static func copyImage(_ sourceURL: URL, into folder: URL, preferredName: String? = nil) -> URL? {
        let source = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }

        if source.path.hasPrefix(folder.standardizedFileURL.path + "/") {
            return source
        }

        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }

        createDirectory(folder)
        let preferredURL = sanitizedFileName(preferredName).map { URL(fileURLWithPath: $0) }
        let sourceName = preferredURL ?? source
        let pathExtension = sourceName.pathExtension.isEmpty ? source.pathExtension : sourceName.pathExtension
        let destination = uniqueDestination(
            baseName: sourceName.deletingPathExtension().lastPathComponent,
            pathExtension: pathExtension,
            folder: folder
        )

        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func uniqueDestination(baseName: String, pathExtension: String, folder: URL) -> URL {
        let cleanBaseName = baseName.isEmpty ? "Image" : baseName
        var candidate = folder.appendingPathComponent(cleanBaseName, isDirectory: false)
        if !pathExtension.isEmpty {
            candidate.appendPathExtension(pathExtension)
        }

        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(cleanBaseName)-\(suffix)", isDirectory: false)
            if !pathExtension.isEmpty {
                candidate.appendPathExtension(pathExtension)
            }
            suffix += 1
        }

        return candidate
    }

    private static func sanitizedFileName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func createDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

}
