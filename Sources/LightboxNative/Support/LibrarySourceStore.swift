import Foundation

enum LibrarySourceStore {
    private static let externalSourcesKey = "Lightbox.full.externalSources"
    private static let selectedSourceKey = "Lightbox.full.selectedSource"
    private static let lastSessionKey = "Lightbox.full.lastSession"

    static func loadSources(defaults: UserDefaults = .standard) -> [LibrarySource] {
        loadExternalSources(defaults: defaults)
    }

    static func saveExternalSources(
        _ sources: [LibrarySource],
        defaults: UserDefaults = .standard
    ) {
        let externalSources = sources.filter { $0.kind == .external }
        guard let data = try? JSONEncoder().encode(externalSources) else { return }
        defaults.set(data, forKey: externalSourcesKey)
    }

    static func selectedSourceID(
        default defaultID: LibrarySource.ID,
        defaults: UserDefaults = .standard
    ) -> LibrarySource.ID {
        defaults.string(forKey: selectedSourceKey) ?? defaultID
    }

    static func saveSelectedSourceID(
        _ id: LibrarySource.ID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(id, forKey: selectedSourceKey)
    }

    static func loadLastSession(defaults: UserDefaults = .standard) -> LibrarySourceSession? {
        guard let data = defaults.data(forKey: lastSessionKey) else {
            return nil
        }

        return try? JSONDecoder().decode(LibrarySourceSession.self, from: data)
    }

    static func saveLastSession(
        source: LibrarySource,
        folderURL: URL,
        defaults: UserDefaults = .standard
    ) {
        let session = LibrarySourceSession(
            sourceID: source.id,
            sourceName: source.displayName,
            sourceRootPath: source.rootURL.standardizedFileURL.path,
            sourceKind: source.kind,
            folderPath: folderURL.standardizedFileURL.path
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: lastSessionKey)
    }

    static func makeExternalSource(rootURL: URL) -> LibrarySource {
        let standardizedURL = rootURL.standardizedFileURL
        return LibrarySource(
            id: UUID().uuidString,
            name: LibrarySource.defaultExternalName(for: standardizedURL),
            rootURL: standardizedURL,
            kind: .external
        )
    }

    private static func loadExternalSources(defaults: UserDefaults) -> [LibrarySource] {
        guard let data = defaults.data(forKey: externalSourcesKey),
              let decoded = try? JSONDecoder().decode([LibrarySource].self, from: data)
        else {
            return []
        }

        return decoded.compactMap { source in
            guard source.kind == .external else {
                return nil
            }

            var normalized = source
            if normalized.name.isEmpty || normalized.name == "Library" {
                normalized.name = LibrarySource.defaultExternalName(for: normalized.rootURL)
            }
            return normalized
        }
    }
}

struct LibrarySourceSession: Codable, Equatable {
    var sourceID: LibrarySource.ID
    var sourceName: String
    var sourceRootPath: String
    var sourceKind: LibrarySourceKind
    var folderPath: String

    var sourceRootURL: URL {
        URL(fileURLWithPath: sourceRootPath, isDirectory: true).standardizedFileURL
    }

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true).standardizedFileURL
    }
}
