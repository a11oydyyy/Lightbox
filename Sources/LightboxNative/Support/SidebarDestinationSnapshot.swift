import Foundation

/// Built by the sidebar's background loaders, then reused during view updates.
struct SidebarDirectoryIdentity: Hashable, Sendable {
    let url: URL
    let path: String

    init(url: URL) {
        let normalized = url.standardizedFileURL
        self.url = normalized
        self.path = normalized.path
    }
}

struct SidebarTreeFolder: Identifiable, Sendable {
    let folder: LibraryFolderEntry
    let path: String

    var id: String { "\(folder.sourceID):\(path)" }

    init(folder: LibraryFolderEntry) {
        self.folder = folder
        self.path = folder.url.standardizedFileURL.path
    }
}

struct SidebarDestinationSnapshot: Sendable {
    var locations: [SidebarLocationID]
    var volumes: [SidebarVolume]
    var locationDirectories: [SidebarLocationID: SidebarDirectoryIdentity] = [:]

    static func load(visibleLocationIDs: Set<SidebarLocationID>) -> Self {
        let locations = SidebarLocationID.allCases.filter { location in
            !Task.isCancelled && visibleLocationIDs.contains(location)
                && location.defaultURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        let locationDirectories = Dictionary(uniqueKeysWithValues: locations.compactMap { location in
            location.defaultURL.map { (location, SidebarDirectoryIdentity(url: $0)) }
        })
        guard visibleLocationIDs.contains(.volumes), !Task.isCancelled else {
            return Self(locations: locations, volumes: [], locationDirectories: locationDirectories)
        }
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .isVolumeKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        let volumes = urls.compactMap { url -> SidebarVolume? in
            guard !Task.isCancelled else { return nil }
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.path != "/" else { return nil }
            let name = (try? standardizedURL.resourceValues(forKeys: [.volumeNameKey]).volumeName)
                ?? standardizedURL.lastPathComponent
            guard !name.isEmpty else { return nil }
            return SidebarVolume(url: standardizedURL, displayName: name)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return Self(locations: locations, volumes: volumes, locationDirectories: locationDirectories)
    }
}
