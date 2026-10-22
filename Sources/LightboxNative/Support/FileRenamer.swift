import Darwin
import Foundation

/// A file and the name it should have, in the same folder.
struct FileRenameItem: Equatable, Sendable {
    var url: URL
    var newName: String

    var target: URL { url.deletingLastPathComponent().appendingPathComponent(newName) }
}

/// A rename that happened.
struct FileRenameMove: Equatable, Sendable {
    var from: URL
    var to: URL
}

/// A renamed folder: where anything inside it now is.
struct FolderRenameMove: Equatable, Sendable {
    var from: URL
    var to: URL

    /// `url` under its new path, or nil when it is not the folder or inside it.
    func moved(_ url: URL) -> URL? {
        let fromPath = from.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == fromPath { return to.standardizedFileURL }
        guard path.hasPrefix(fromPath + "/") else { return nil }
        let rest = String(path.dropFirst(fromPath.count + 1))
        return to.standardizedFileURL.appendingPathComponent(rest, isDirectory: url.hasDirectoryPath)
    }

    /// A path string under its new path, as `moved(_:)`.
    func moved(path: String) -> String? {
        moved(URL(fileURLWithPath: path))?.path
    }
}

/// Why a rename cannot go ahead. The names are the new names involved.
enum FileRenameIssue: Error, Equatable, Sendable {
    case empty
    case invalidCharacter
    case leadingDot
    case tooLong
    case duplicate(String)
    case exists(String)
    case failed(String)
}

/// How a batch rename builds the new names. Extensions are always kept.
enum BatchRenameRule: Equatable, Sendable {
    case replace(find: String, with: String)
    case add(text: String, atEnd: Bool)
    /// `name` then a number from `start`, zero-padded to the widest number.
    case format(name: String, start: Int)
}

/// Renames files in place without ever replacing another file. A batch is
/// all or nothing: a failure part-way puts back the renames already done.
enum FileRenamer {
    // MARK: Names

    static func names(for names: [String], rule: BatchRenameRule) -> [String] {
        let lastNumber: Int
        if case .format(_, let start) = rule { lastNumber = start + max(0, names.count - 1) } else { lastNumber = 0 }
        let width = String(lastNumber).count
        return names.enumerated().map { index, name in
            let (base, ext) = split(name)
            let newBase: String
            switch rule {
            case .replace(let find, let replacement):
                newBase = find.isEmpty ? base : base.replacingOccurrences(of: find, with: replacement)
            case .add(let text, let atEnd):
                newBase = atEnd ? base + text : text + base
            case .format(let prefix, let start):
                let number = String(start + index)
                let padded = String(repeating: "0", count: max(0, width - number.count)) + number
                newBase = prefix.isEmpty ? padded : "\(prefix) \(padded)"
            }
            return ext.isEmpty ? newBase : "\(newBase).\(ext)"
        }
    }

    /// The name before its extension, and the extension (empty when none).
    static func split(_ name: String) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return (name, "") }
        return ((name as NSString).deletingPathExtension, ext)
    }

    // MARK: Checks

    /// Checks names alone, without the disk: shape, length and clashes
    /// within the batch. Clashes with other files are found when renaming.
    static func issue(in items: [FileRenameItem]) -> FileRenameIssue? {
        var seen = Set<String>()
        for item in items {
            if let issue = issue(inName: item.newName) { return issue }
            guard seen.insert(key(item.target)).inserted else { return .duplicate(item.newName) }
        }
        return nil
    }

    static func issue(inName name: String) -> FileRenameIssue? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if name.contains("/") || name.contains(":") { return .invalidCharacter }
        if name.hasPrefix(".") { return .leadingDot }
        if name.utf8.count > Int(NAME_MAX) { return .tooLong }
        return nil
    }

    /// File systems on the Mac usually ignore case and Unicode composition.
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Renaming

    /// Renames the items whose names change, and the `.xmp` sidecars of RAW
    /// files with them (`RawSidecar`). Blocks on file I/O; call off the main
    /// thread.
    static func perform(_ items: [FileRenameItem], includingSidecars: Bool = true) -> Result<[FileRenameMove], FileRenameIssue> {
        if let issue = issue(in: items) { return .failure(issue) }
        let items = includingSidecars ? RawSidecar.addingSidecars(to: items) : items
        if let issue = issue(in: items) { return .failure(issue) }
        let moves = items.filter { $0.newName != $0.url.lastPathComponent }
            .map { FileRenameMove(from: $0.url.standardizedFileURL, to: $0.target.standardizedFileURL) }
        guard !moves.isEmpty else { return .success([]) }

        // A name that another file in the batch is giving up, or a change of
        // case only, goes through a temporary name first.
        let sourceKeys = Set(moves.map { key($0.from) })
        var done: [FileRenameMove] = []
        var pending: [(current: URL, move: FileRenameMove)] = []
        for (index, move) in moves.enumerated() {
            guard sourceKeys.contains(key(move.to)) else {
                pending.append((move.from, move))
                continue
            }
            let temporary = move.from.deletingLastPathComponent()
                .appendingPathComponent(".lightbox-rename-\(UUID().uuidString)-\(index)")
            if let error = rename(move.from, to: temporary) {
                rollBack(done)
                return .failure(issue(for: error, name: move.to.lastPathComponent))
            }
            done.append(FileRenameMove(from: move.from, to: temporary))
            pending.append((temporary, move))
        }
        for (current, move) in pending {
            if let error = rename(current, to: move.to) {
                rollBack(done)
                return .failure(issue(for: error, name: move.to.lastPathComponent))
            }
            done.append(FileRenameMove(from: current, to: move.to))
        }
        return .success(moves)
    }

    // MARK: Folders

    /// Creates `name` in `parent`; never reuses an existing item. Blocks on
    /// file I/O; call off the main thread.
    static func createFolder(named name: String, in parent: URL) -> Result<URL, FileRenameIssue> {
        if let issue = issue(inName: name) { return .failure(issue) }
        let url = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let result = url.withUnsafeFileSystemRepresentation { mkdir($0, 0o777) }
        guard result == 0 else { return .failure(issue(for: errno, name: name)) }
        return .success(url)
    }

    /// Removes a folder this app created, only while it is still empty: the
    /// undo of New Folder. Anything put inside keeps it on disk.
    static func removeEmptyFolder(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { rmdir($0) } == 0
    }

    /// The renames that put `moves` back.
    static func reversal(of moves: [FileRenameMove]) -> [FileRenameItem] {
        moves.map { FileRenameItem(url: $0.to, newName: $0.from.lastPathComponent) }
    }

    /// Never replaces an existing file.
    private static func rename(_ source: URL, to target: URL) -> Int32? {
        let result = source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        return result == 0 ? nil : errno
    }

    private static func rollBack(_ done: [FileRenameMove]) {
        for move in done.reversed() {
            _ = rename(move.to, to: move.from)
        }
    }

    private static func issue(for error: Int32, name: String) -> FileRenameIssue {
        error == EEXIST ? .exists(name) : .failed(name)
    }
}
