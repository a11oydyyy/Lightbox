import Darwin
import Foundation

enum FileTransferService {
    static func perform(
        _ request: FileTransferRequest,
        progress: @escaping @Sendable (FileTransferProgressUpdate) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> FileTransferResult {
        let fileManager = FileManager.default
        let destinationFolder = request.destinationFolderURL.standardizedFileURL
        var successes: [FileTransferSuccess] = []
        var failures: [FileTransferFailure] = []
        var wasCancelled = false
        let sourceURLs = deduplicatedURLs(request.sourceURLs)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return FileTransferResult(
                requestID: request.id,
                operation: request.operation,
                successes: [],
                failures: sourceURLs.map {
                    FileTransferFailure(sourceURL: $0, message: "Destination folder is unavailable")
                },
                wasCancelled: false
            )
        }

        for sourceURL in sourceURLs {
            if shouldCancel() {
                wasCancelled = true
                break
            }
            let source = sourceURL.standardizedFileURL
            progress(
                FileTransferProgressUpdate(
                    completedCount: successes.count + failures.count,
                    totalCount: sourceURLs.count,
                    currentName: source.lastPathComponent
                )
            )

            guard fileManager.fileExists(atPath: source.path) else {
                failures.append(FileTransferFailure(sourceURL: source, message: "Source item is unavailable"))
                continue
            }

            if request.operation == .move,
               source.deletingLastPathComponent().standardizedFileURL.path == destinationFolder.path {
                successes.append(FileTransferSuccess(sourceURL: source, destinationURL: source))
                continue
            }

            do {
                let preferredDestination = try availableDestinationURL(
                    for: source,
                    in: destinationFolder,
                    operation: request.operation,
                    shouldCancel: shouldCancel
                )
                let outcome = try transferItem(
                    from: source,
                    to: preferredDestination,
                    operation: request.operation,
                    fileManager: fileManager,
                    shouldCancel: shouldCancel
                )
                if let failureMessage = outcome.failureMessage {
                    failures.append(
                        FileTransferFailure(
                            sourceURL: source,
                            message: failureMessage,
                            committedDestinationURL: outcome.destinationURL
                        )
                    )
                } else {
                    successes.append(FileTransferSuccess(sourceURL: source, destinationURL: outcome.destinationURL))
                }
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                failures.append(FileTransferFailure(sourceURL: source, message: error.localizedDescription))
            }

            progress(
                FileTransferProgressUpdate(
                    completedCount: successes.count + failures.count,
                    totalCount: sourceURLs.count,
                    currentName: source.lastPathComponent
                )
            )
        }

        return FileTransferResult(
            requestID: request.id,
            operation: request.operation,
            successes: successes,
            failures: failures,
            wasCancelled: wasCancelled
        )
    }

    private static func transferItem(
        from sourceURL: URL,
        to destinationURL: URL,
        operation: FileTransferOperation,
        fileManager: FileManager,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> FileTransferItemOutcome {
        if operation == .move {
            var moveDestination = destinationURL
            while true {
                guard !shouldCancel() else { throw CancellationError() }
                let renameResult = renameExclusively(from: sourceURL, to: moveDestination)
                if renameResult == 0 {
                    return FileTransferItemOutcome(destinationURL: moveDestination)
                }
                if errno == EEXIST {
                    moveDestination = try availableDestinationURL(
                        for: sourceURL,
                        in: destinationURL.deletingLastPathComponent(),
                        operation: operation,
                        shouldCancel: shouldCancel
                    )
                    continue
                }
                guard errno == EXDEV else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                break
            }
        }

        guard !shouldCancel() else { throw CancellationError() }
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".lightbox-transfer-\(UUID().uuidString)",
            isDirectory: sourceURL.hasDirectoryPath
        )
        do {
            try copyItemWithCancellation(
                from: sourceURL,
                to: temporaryURL,
                fileManager: fileManager,
                shouldCancel: shouldCancel
            )
            guard !shouldCancel() else { throw CancellationError() }

            var committedDestination = destinationURL
            while true {
                guard !shouldCancel() else { throw CancellationError() }
                let renameResult = renameExclusively(from: temporaryURL, to: committedDestination)
                if renameResult == 0 { break }
                guard errno == EEXIST else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                committedDestination = try availableDestinationURL(
                    for: sourceURL,
                    in: destinationURL.deletingLastPathComponent(),
                    operation: operation,
                    shouldCancel: shouldCancel
                )
            }

            if operation == .move {
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch {
                    return FileTransferItemOutcome(
                        destinationURL: committedDestination,
                        failureMessage: "Copied to destination, but the source item could not be removed: \(error.localizedDescription)"
                    )
                }
            }
            return FileTransferItemOutcome(destinationURL: committedDestination)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func copyItemWithCancellation(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        guard let state = copyfile_state_alloc() else {
            throw POSIXError(.ENOMEM)
        }
        defer { copyfile_state_free(state) }

        let cancellationContext = Unmanaged.passRetained(
            FileCopyCancellationContext(shouldCancel: shouldCancel)
        )
        defer { cancellationContext.release() }
        let callback: copyfile_callback_t = { _, _, _, _, _, context in
            guard let context else { return Int32(COPYFILE_CONTINUE) }
            let cancellation = Unmanaged<FileCopyCancellationContext>
                .fromOpaque(context)
                .takeUnretainedValue()
            return cancellation.shouldCancel()
                ? Int32(COPYFILE_QUIT)
                : Int32(COPYFILE_CONTINUE)
        }
        let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
        let callbackResult = copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            callbackPointer
        )
        guard callbackResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let contextResult = copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CTX),
            cancellationContext.toOpaque()
        )
        guard contextResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)
        if isDirectory.boolValue {
            flags |= copyfile_flags_t(COPYFILE_RECURSIVE)
        }

        let copyResult = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return copyfile(sourcePath, destinationPath, state, flags)
            }
        }
        guard copyResult == 0 else {
            let copyError = errno
            if shouldCancel() {
                throw CancellationError()
            }
            throw POSIXError(POSIXErrorCode(rawValue: copyError) ?? .EIO)
        }
    }

    private static func renameExclusively(from sourceURL: URL, to destinationURL: URL) -> Int32 {
        sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
    }

    static func availableDestinationURL(
        for sourceURL: URL,
        in destinationFolderURL: URL,
        operation: FileTransferOperation,
        shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> URL {
        guard !shouldCancel() else { throw CancellationError() }
        let source = sourceURL.standardizedFileURL
        let destinationFolder = destinationFolderURL.standardizedFileURL
        let directDestination = destinationFolder.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: source.hasDirectoryPath
        )
        if try !destinationEntryExists(at: directDestination) {
            return directDestination
        }

        let pathExtension = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        let firstSuffix = operation == .copy ? " copy" : " 2"
        var suffix = firstSuffix
        var index = 2

        while true {
            guard !shouldCancel() else { throw CancellationError() }
            let filename = pathExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + pathExtension
            let candidate = destinationFolder.appendingPathComponent(
                filename,
                isDirectory: source.hasDirectoryPath
            )
            if try !destinationEntryExists(at: candidate) {
                return candidate
            }
            suffix = operation == .copy ? " copy \(index)" : " \(index + 1)"
            index += 1
        }
    }

    // fileExists follows symlinks, but an exclusive rename treats even a
    // dangling symlink as an occupied directory entry.
    private static func destinationEntryExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}

private struct FileTransferItemOutcome: Sendable {
    var destinationURL: URL
    var failureMessage: String?
}

private final class FileCopyCancellationContext: @unchecked Sendable {
    let shouldCancel: @Sendable () -> Bool

    init(shouldCancel: @escaping @Sendable () -> Bool) {
        self.shouldCancel = shouldCancel
    }
}
