import Foundation

enum LibrarySourceKind: String, Codable, Hashable {
    // Kept for existing user data and index compatibility. UI presents this as Library.
    case favorites
    case external
}

struct LibrarySource: Identifiable, Codable, Hashable, Sendable {
    static let favoritesID = "favorites"
    static let localLibraryDisplayName = "Library"
    static let defaultStartupID = "default-downloads"

    var id: String
    var name: String
    var rootURL: URL
    var kind: LibrarySourceKind

    var isLocalLibrary: Bool {
        kind == .favorites
    }

    var usesConservativeExternalLoading: Bool {
        guard !isLocalLibrary else { return false }

        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        return !(rootPath == homePath || rootPath.hasPrefix(homePath + "/"))
    }

    var displayName: String {
        if isLocalLibrary {
            return Self.localLibraryDisplayName
        }
        return name.isEmpty ? Self.defaultExternalName(for: rootURL) : name
    }

    static func favorites(rootURL: URL) -> LibrarySource {
        LibrarySource(
            id: favoritesID,
            name: localLibraryDisplayName,
            rootURL: rootURL.standardizedFileURL,
            kind: .favorites
        )
    }

    static func defaultStartupSource() -> LibrarySource {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let rootURL = FileManager.default.fileExists(atPath: downloads.path) ? downloads : home
        return LibrarySource(
            id: defaultStartupID,
            name: defaultExternalName(for: rootURL),
            rootURL: rootURL.standardizedFileURL,
            kind: .external
        )
    }

    static func defaultExternalName(for rootURL: URL) -> String {
        let lastComponent = rootURL.standardizedFileURL.lastPathComponent
        return lastComponent.isEmpty ? rootURL.standardizedFileURL.path : lastComponent
    }
}

struct LibraryFolderEntry: Identifiable, Hashable, Sendable {
    var sourceID: LibrarySource.ID
    var url: URL
    var rootURL: URL
    var tags: [String] = []

    var id: String {
        "\(sourceID):\(url.standardizedFileURL.path)"
    }

    var name: String {
        url.lastPathComponent.isEmpty ? rootURL.lastPathComponent : url.lastPathComponent
    }

    var relativePath: String {
        url.relativePath(from: rootURL)
    }
}

enum LibraryFolderEntrySorter {
    static func sorted(
        _ items: [LibraryFolderEntry],
        field: GallerySortField,
        direction: GallerySortDirection
    ) -> [LibraryFolderEntry] {
        items.sorted { lhs, rhs in
            switch field {
            case .tag:
                compareTag(lhs, rhs, direction: direction) ?? tieBreak(lhs, rhs, direction: direction)
            case .time, .size, .fileName, .type:
                tieBreak(lhs, rhs, direction: direction)
            }
        }
    }

    private static func compareTag(
        _ lhs: LibraryFolderEntry,
        _ rhs: LibraryFolderEntry,
        direction: GallerySortDirection
    ) -> Bool? {
        let lhsRank = sortableTagRank(lhs)
        let rhsRank = sortableTagRank(rhs)
        guard lhsRank != rhsRank else { return nil }
        return direction == .ascending ? lhsRank < rhsRank : lhsRank > rhsRank
    }

    private static func sortableTagRank(_ folder: LibraryFolderEntry) -> Int {
        let sortedTags = MacColorTag.sort(folder.tags.filter(MacColorTag.isColorTag))
        guard let firstTag = sortedTags.first,
              let rank = MacColorTag.all.firstIndex(where: { $0.name == firstTag })
        else {
            return Int.max
        }
        return rank
    }

    private static func tieBreak(
        _ lhs: LibraryFolderEntry,
        _ rhs: LibraryFolderEntry,
        direction: GallerySortDirection
    ) -> Bool {
        compareText(lhs.name, rhs.name, direction: direction)
            ?? compareText(lhs.relativePath, rhs.relativePath, direction: direction)
            ?? compareText(lhs.id, rhs.id, direction: direction)
            ?? false
    }

    private static func compareText(
        _ lhs: String,
        _ rhs: String,
        direction: GallerySortDirection
    ) -> Bool? {
        let order = lhs.localizedStandardCompare(rhs)
        guard order != .orderedSame else { return nil }
        return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
    }
}

struct PathBreadcrumb: Identifiable, Hashable, Sendable {
    var id: String {
        url.standardizedFileURL.path
    }

    var title: String
    var url: URL
}

extension URL {
    func relativePath(from rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = standardizedFileURL.path

        guard path != rootPath,
              path.hasPrefix(rootPath + "/")
        else {
            return ""
        }

        return String(path.dropFirst(rootPath.count + 1))
    }
}
