import Foundation

enum SidebarLocationID: String, CaseIterable, Codable, Hashable, Identifiable {
    case applications
    case desktop
    case documents
    case downloads
    case movies
    case music
    case pictures
    case iCloudDrive
    case volumes

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .applications:
            "app"
        case .desktop:
            "desktopcomputer"
        case .documents:
            "doc"
        case .downloads:
            "arrow.down.circle"
        case .movies:
            "film"
        case .music:
            "music.note"
        case .pictures:
            "photo.on.rectangle"
        case .iCloudDrive:
            "icloud"
        case .volumes:
            "externaldrive"
        }
    }

    var defaultURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .applications:
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .desktop:
            return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents:
            return home.appendingPathComponent("Documents", isDirectory: true)
        case .downloads:
            return home.appendingPathComponent("Downloads", isDirectory: true)
        case .movies:
            return home.appendingPathComponent("Movies", isDirectory: true)
        case .music:
            return home.appendingPathComponent("Music", isDirectory: true)
        case .pictures:
            return home.appendingPathComponent("Pictures", isDirectory: true)
        case .iCloudDrive:
            return home
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        case .volumes:
            return URL(fileURLWithPath: "/Volumes", isDirectory: true)
        }
    }
}

struct SidebarVolume: Identifiable, Hashable, Sendable {
    var url: URL
    var displayName: String

    var id: String {
        url.standardizedFileURL.path
    }
}
