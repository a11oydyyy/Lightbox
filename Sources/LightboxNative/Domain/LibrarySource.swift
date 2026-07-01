import Foundation

enum LibrarySourceKind: String, Codable, Hashable {
    // Kept for existing user data and index compatibility. UI presents this as Library.
    case favorites
    case external
}

struct LibrarySource: Identifiable, Codable, Hashable, Sendable {
    static let favoritesID = "favorites"
    static let localLibraryDisplayName = "Library"

    var id: String
    var name: String
    var rootURL: URL
    var kind: LibrarySourceKind

    var isLocalLibrary: Bool {
        kind == .favorites
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
