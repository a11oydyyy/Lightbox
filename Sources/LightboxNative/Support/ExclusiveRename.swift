import Darwin
import Foundation

/// A rename that never replaces what is already at the destination.
///
/// `renamex_np(RENAME_EXCL)` does this atomically, but exFAT, FAT and some
/// network volumes refuse it (ENOTSUP), and photo drives are often exFAT.
/// 不支援時，普通檔案以獨佔建立的目的檔完成拷貝後才移除來源。
/// 不使用「先檢查再 rename」：兩者之間仍可能出現別人的同名檔。
enum ExclusiveRename {
    /// 0 when renamed, else the errno (EEXIST when the destination is taken).
    static func rename(_ source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
                let error = errno
                guard error == ENOTSUP || error == EINVAL else { return error }
                return copyExclusively(from, to: to)
            }
        }
    }

    /// Forces a file's data to stable storage: `F_FULLFSYNC`, else `fsync` on
    /// volumes that do not implement it. nil when flushed, else the errno.
    static func flushToDisk(_ descriptor: Int32) -> Int32? {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return nil }
        let unsupported = errno
        guard unsupported == ENOTSUP || unsupported == EINVAL || unsupported == ENOTTY else { return unsupported }
        return fsync(descriptor) == 0 ? nil : errno
    }

    /// Flushes a file, or every regular file under a directory tree, then the
    /// directories themselves where the volume allows. nil when all flushed.
    static func flushTree(at url: URL) -> Int32? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { return errno }
            defer { close(descriptor) }
            return flushToDisk(descriptor)
        case S_IFDIR:
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return EIO }
            for name in names {
                if let failure = flushTree(at: url.appendingPathComponent(name)) { return failure }
            }
            return nil
        default:
            return nil
        }
    }

    /// A directory cannot be copied like a file. `mkdir` claims the name
    /// exclusively (EEXIST when taken), and `rename` onto an *empty* directory
    /// is allowed by POSIX and refuses a non-empty one (ENOTEMPTY), so nothing
    /// that is already there can be replaced except a directory someone else
    /// emptied and left in our placeholder's place in that instant.
    static func renameDirectoryExclusively(_ from: UnsafePointer<CChar>, to: UnsafePointer<CChar>) -> Int32 {
        guard mkdir(to, 0o700) == 0 else { return errno }
        var placeholder = stat()
        let owned = lstat(to, &placeholder) == 0
        if Darwin.rename(from, to) == 0 { return 0 }
        let failure = errno
        // rmdir only removes an empty directory, so it cannot take anything else with it.
        if owned { _ = rmdir(to) }
        return failure
    }

    private static func copyExclusively(_ from: UnsafePointer<CChar>, to: UnsafePointer<CChar>) -> Int32 {
        let input = open(from, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { return errno }
        defer { close(input) }
        var source = stat()
        guard fstat(input, &source) == 0 else { return errno }
        if source.st_mode & S_IFMT == S_IFDIR { return renameDirectoryExclusively(from, to: to) }
        // 其他類型（符號連結等）不能用檔案拷貝模擬；維持失敗，避免覆蓋。
        guard source.st_mode & S_IFMT == S_IFREG else { return ENOTSUP }
        let output = open(to, O_WRONLY | O_CREAT | O_EXCL, source.st_mode & 0o777)
        guard output >= 0 else { return errno }
        defer { close(output) }
        func stillOwnsDestination() -> Bool {
            var descriptor = stat(), path = stat()
            return fstat(output, &descriptor) == 0 && lstat(to, &path) == 0
                && descriptor.st_dev == path.st_dev && descriptor.st_ino == path.st_ino
        }
        if fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 {
            let failure = errno
            if stillOwnsDestination() { _ = unlink(to) }
            return failure
        }
        guard stillOwnsDestination() else { return EEXIST }
        // 資料真正寫入磁碟後才移除來源；失敗時保留來源，並只清掉自己建立的目的檔。
        if let flushError = flushToDisk(output) {
            if stillOwnsDestination() { _ = unlink(to) }
            return flushError
        }
        if unlink(from) != 0 {
            let failure = errno
            if stillOwnsDestination() { _ = unlink(to) }
            return failure
        }
        return 0
    }
}
