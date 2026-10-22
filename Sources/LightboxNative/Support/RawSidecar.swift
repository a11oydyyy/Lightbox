import Darwin
import Foundation

/// The `.xmp` files Camera Raw, Lightroom and Bridge keep beside a RAW file
/// for its develop settings and rating: `IMG_1.xmp`, or sometimes
/// `IMG_1.CR3.xmp`. Renaming, trashing and moving a RAW takes them along, as
/// Bridge does, so its edits are not left behind. Other formats keep theirs
/// inside the file; a JPEG beside a RAW of the same name never takes the RAW's.
enum RawSidecar {
    /// Where a sidecar of `url` would be; empty for files other than RAW.
    static func candidates(for url: URL) -> [URL] {
        guard LightboxAsset.rawImageExtensions.contains(url.pathExtension.lowercased()) else { return [] }
        return [url.deletingPathExtension().appendingPathExtension("xmp"), url.appendingPathExtension("xmp")]
    }

    /// The sidecars of `url` on disk. Blocks on file I/O.
    static func existing(for url: URL) -> [URL] {
        candidates(for: url).filter { candidate in
            var status = stat()
            return candidate.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &status) == 0 } ?? false }
                && (status.st_mode & S_IFMT) == S_IFREG
        }
    }

    /// The name `sidecar` (of `file`) takes when `file` is named `newName`.
    static func name(of sidecar: URL, for file: URL, whenNamed newName: String) -> String {
        let sidecarExtension = sidecar.pathExtension
        if sidecar.deletingPathExtension().lastPathComponent == file.lastPathComponent {
            return newName + "." + sidecarExtension
        }
        return (newName as NSString).deletingPathExtension + "." + sidecarExtension
    }

    /// `items` plus a rename for each sidecar of a RAW among them, unless the
    /// batch already renames that sidecar itself. Blocks on file I/O.
    static func addingSidecars(to items: [FileRenameItem]) -> [FileRenameItem] {
        var listed = Set(items.map { $0.url.standardizedFileURL.path })
        var result = items
        for item in items where item.newName != item.url.lastPathComponent {
            for sidecar in existing(for: item.url) where listed.insert(sidecar.standardizedFileURL.path).inserted {
                result.append(FileRenameItem(url: sidecar, newName: name(of: sidecar, for: item.url, whenNamed: item.newName)))
            }
        }
        return result
    }

    /// `urls` without the sidecars of RAW files also in it: those go with their RAW.
    static func withoutCompanions(_ urls: [URL]) -> [URL] {
        let companions = Set(urls.flatMap(candidates(for:)).map(\.standardizedFileURL.path))
        return urls.filter { !companions.contains($0.standardizedFileURL.path) }
    }
}
