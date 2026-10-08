import Foundation

enum FolderPathOpenResult: Equatable, Sendable {
    case opened
    case unavailable
    case cancelled
}

enum DirectoryAccessResolver {
    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    static func existingDirectory(
        _ url: URL,
        probe: @escaping @Sendable (URL) -> Bool = isDirectory
    ) async throws -> Bool {
        let existing = try await FileActionResolver.existingURLs([url], exists: probe)
        return !existing.isEmpty
    }
}
