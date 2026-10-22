import Darwin
import Foundation
import OSLog

/// Finder 的「放回原處」不提供結果路徑；這種結果不能猜測重做目標。
enum TrashRestoreResult: Sendable {
    case restored(URL)
    case restoredByFinder
    case failed

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

enum LightboxLibraryStore {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "LibraryStore")
    private static let trashRestoreDestinationsKey = "Lightbox.trashRestoreDestinations"

    static var cacheFolder: URL {
        // Measurements and tests point this elsewhere, away from the app's own cache.
        if let override = ProcessInfo.processInfo.environment["LIGHTBOX_CACHE_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                LightboxRuntime.cacheDirectoryName(for: Bundle.main.bundleIdentifier),
                isDirectory: true
            )
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

    /// Where the item landed in the Trash, or nil when it was not moved.
    static func moveToSystemTrash(_ sourceURL: URL) -> URL? {
        let source = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
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
            guard let resultingURL else { return source }
            recordRestoreDestination(originalURL: source, trashURL: resultingURL as URL)
            return resultingURL as URL
        } catch {
            return nil
        }
    }

    static func isSystemTrashURL(_ url: URL) -> Bool {
        let sourcePath = url.standardizedFileURL.path
        return systemTrashFolders.contains { folder in
            sourcePath == folder.path || sourcePath.hasPrefix(folder.path + "/")
        }
    }

    static func restoreFromSystemTrash(_ sourceURL: URL) async -> TrashRestoreResult {
        let source = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path),
              isSystemTrashURL(source)
        else {
            return .failed
        }

        return await Task.detached(priority: .userInitiated) {
            restoreFromSystemTrashSynchronously(source)
        }.value
    }

    private static func restoreFromSystemTrashSynchronously(_ source: URL) -> TrashRestoreResult {
        if let destination = restoreFromRecordedDestination(source) {
            return .restored(destination)
        }

        let restored = restoreWithFinder(source)
        if restored {
            clearRestoreDestination(forTrashURL: source)
        }
        return restored ? .restoredByFinder : .failed
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

    static func restoreFromRecordedDestination(_ source: URL, defaults: UserDefaults = .standard) -> URL? {
        let source = source.standardizedFileURL
        guard let destination = restoreDestination(forTrashURL: source, defaults: defaults) else {
            return nil
        }

        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard isExistingDirectory(parent) else {
            return nil
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
            return finalDestination
        } catch {
            logger.error("recorded trash restore failed source=\(source.path, privacy: .public) destination=\(finalDestination.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
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

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

}
