import Foundation
import Testing
@testable import LightboxNative

private func makeFolder(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let folder = parent.appendingPathComponent("ExclusiveRename-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

// Renames onto a free name, and never over a taken one.
@Test func exclusiveRenameNeverReplaces() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = folder.appendingPathComponent("a.jpg"), b = folder.appendingPathComponent("b.jpg")
    FileManager.default.createFile(atPath: a.path, contents: Data([1]))
    FileManager.default.createFile(atPath: b.path, contents: Data([2]))

    #expect(ExclusiveRename.rename(a, to: b) == EEXIST)
    #expect(try Data(contentsOf: b) == Data([2]))
    #expect(ExclusiveRename.rename(a, to: folder.appendingPathComponent("c.jpg")) == 0)
    #expect(!FileManager.default.fileExists(atPath: a.path))
}

// exFAT refuses RENAME_EXCL, so before the fallback every export, copy, move
// and rename onto such a drive failed. Run on request with
// LIGHTBOX_EXFAT_TEST=<a folder on an exFAT volume>.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_EXFAT_TEST"] != nil))
func fileOperationsWorkOnExFAT() throws {
    let volume = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIGHTBOX_EXFAT_TEST"]))
    let folder = try makeFolder(in: volume)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("DSC1.ARW")
    FileManager.default.createFile(atPath: source.path, contents: Data([0]))

    #expect(ExclusiveRename.rename(source, to: folder.appendingPathComponent("taken")) == 0)
    #expect(ExclusiveRename.rename(folder.appendingPathComponent("taken"), to: source) == 0)
    FileManager.default.createFile(atPath: folder.appendingPathComponent("other").path, contents: Data([9]))
    #expect(ExclusiveRename.rename(source, to: folder.appendingPathComponent("other")) == EEXIST)

    // Copy, then move, into a subfolder; then rename.
    let into = folder.appendingPathComponent("into", isDirectory: true)
    try FileManager.default.createDirectory(at: into, withIntermediateDirectories: false)
    for operation in [FileTransferOperation.copy, .move] {
        let result = FileTransferService.perform(
            FileTransferRequest(sourceURLs: [source], destinationFolderURL: into, operation: operation),
            progress: { _ in }, shouldCancel: { false })
        #expect(result.failures.isEmpty, "\(operation): \(result.failures.map(\.message))")
    }
    let moved = into.appendingPathComponent("DSC1 2.ARW")
    #expect(FileManager.default.fileExists(atPath: moved.path))
    #expect(try FileRenamer.perform([FileRenameItem(url: moved, newName: "Renamed.ARW")]).get().count == 1)

    // 多個寫入者同時搶同一個名稱，只能有一個成功；其餘來源必須保留。
    let contenders = (0..<12).map { folder.appendingPathComponent("race-\($0).jpg") }
    let destination = folder.appendingPathComponent("winner.jpg")
    for (index, url) in contenders.enumerated() { try Data([UInt8(index)]).write(to: url) }
    DispatchQueue.concurrentPerform(iterations: contenders.count) { index in
        let result = ExclusiveRename.rename(contenders[index], to: destination)
        #expect(result == 0 || result == EEXIST)
    }
    let winner = Int(try #require(Data(contentsOf: destination).first))
    for (index, url) in contenders.enumerated() {
        if index == winner { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        else { #expect(try Data(contentsOf: url) == Data([UInt8(index)])) }
    }
}

// MARK: Directory fallback (what exFAT needs; run directly so APFS covers it too)

private func directoryFallback(_ source: URL, _ destination: URL) -> Int32 {
    source.withUnsafeFileSystemRepresentation { from in
        destination.withUnsafeFileSystemRepresentation { to in
            ExclusiveRename.renameDirectoryExclusively(from!, to: to!)
        }
    }
}

@Test func directoryFallbackNeverReplacesAndLeavesNoPlaceholder() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fileManager = FileManager.default
    let source = folder.appendingPathComponent("src", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: false)
    try Data([1]).write(to: source.appendingPathComponent("a.jpg"))

    // Free name: moves with its contents.
    let free = folder.appendingPathComponent("free", isDirectory: true)
    #expect(directoryFallback(source, free) == 0)
    #expect(!fileManager.fileExists(atPath: source.path))
    #expect(try Data(contentsOf: free.appendingPathComponent("a.jpg")) == Data([1]))

    // Taken by a directory (even an empty one), a file, or a symlink: EEXIST, both untouched.
    let emptyTaken = folder.appendingPathComponent("empty", isDirectory: true)
    let fileTaken = folder.appendingPathComponent("file")
    let linkTaken = folder.appendingPathComponent("link")
    try fileManager.createDirectory(at: emptyTaken, withIntermediateDirectories: false)
    try Data([7]).write(to: fileTaken)
    try fileManager.createSymbolicLink(at: linkTaken, withDestinationURL: folder.appendingPathComponent("nowhere"))
    for taken in [emptyTaken, fileTaken, linkTaken] {
        #expect(directoryFallback(free, taken) == EEXIST)
        #expect(fileManager.fileExists(atPath: free.appendingPathComponent("a.jpg").path))
    }
    #expect(try fileManager.contentsOfDirectory(atPath: emptyTaken.path).isEmpty)
    #expect(try Data(contentsOf: fileTaken) == Data([7]))

    // A failing rename removes the placeholder it made: source missing.
    let missing = folder.appendingPathComponent("missing", isDirectory: true)
    let target = folder.appendingPathComponent("target", isDirectory: true)
    #expect(directoryFallback(missing, target) == ENOENT)
    #expect(!fileManager.fileExists(atPath: target.path))
}

@Test func exclusiveRenameMovesDirectoriesAndRefusesTakenNames() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = folder.appendingPathComponent("a", isDirectory: true), b = folder.appendingPathComponent("b", isDirectory: true)
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
    #expect(ExclusiveRename.rename(a, to: b) == EEXIST)
    #expect(ExclusiveRename.rename(a, to: folder.appendingPathComponent("c", isDirectory: true)) == 0)
}

// MARK: Flush

@Test func flushToDiskAndTreeSucceedOnFilesAndFolders() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let nested = folder.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([1, 2]).write(to: nested.appendingPathComponent("x.raw"))
    try Data([3]).write(to: folder.appendingPathComponent("y.raw"))
    #expect(ExclusiveRename.flushTree(at: folder) == nil)
    #expect(ExclusiveRename.flushTree(at: folder.appendingPathComponent("y.raw")) == nil)
    #expect(ExclusiveRename.flushTree(at: folder.appendingPathComponent("nope")) == ENOENT)
}

// The cross-volume move needs a second volume; gated on the same exFAT folder.
// The copy must be flushed before the source goes, and a failed flush keeps it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_EXFAT_TEST"] != nil))
func crossVolumeMoveKeepsTheSourceWhenTheFlushFails() throws {
    let volume = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIGHTBOX_EXFAT_TEST"]))
    let destination = try makeFolder(in: volume)
    let origin = try makeFolder()
    defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: origin) }
    let file = origin.appendingPathComponent("one.ARW"), tree = origin.appendingPathComponent("set", isDirectory: true)
    try Data([1]).write(to: file)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
    try Data([2]).write(to: tree.appendingPathComponent("two.ARW"))

    let failed = FileTransferService.perform(
        FileTransferRequest(sourceURLs: [file, tree], destinationFolderURL: destination, operation: .move),
        progress: { _ in }, shouldCancel: { false }, flush: { _ in EIO })
    #expect(failed.failures.count == 2)
    #expect(failed.failures.allSatisfy { $0.message.contains("kept") })
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("two.ARW").path))

    // Retrying finds the name taken by the unflushed-but-complete copies; clear them first.
    for name in try FileManager.default.contentsOfDirectory(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination.appendingPathComponent(name))
    }
    let moved = FileTransferService.perform(
        FileTransferRequest(sourceURLs: [file, tree], destinationFolderURL: destination, operation: .move),
        progress: { _ in }, shouldCancel: { false })
    #expect(moved.failures.isEmpty, "\(moved.failures.map(\.message))")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(!FileManager.default.fileExists(atPath: tree.path))
    #expect(try Data(contentsOf: destination.appendingPathComponent("set/two.ARW")) == Data([2]))
}

// Folder rename and a same-volume folder move on exFAT, where RENAME_EXCL is refused.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_EXFAT_TEST"] != nil))
func folderRenameAndMoveWorkOnExFAT() throws {
    let volume = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIGHTBOX_EXFAT_TEST"]))
    let folder = try makeFolder(in: volume)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fileManager = FileManager.default
    let source = folder.appendingPathComponent("Trip", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: false)
    try Data([5]).write(to: source.appendingPathComponent("a.ARW"))

    #expect(try FileRenamer.perform([FileRenameItem(url: source, newName: "Trip 2024")]).get().count == 1)
    let renamed = folder.appendingPathComponent("Trip 2024", isDirectory: true)
    #expect(try Data(contentsOf: renamed.appendingPathComponent("a.ARW")) == Data([5]))

    // Taken names are refused, empty or not, and the source stays.
    let taken = folder.appendingPathComponent("Taken", isDirectory: true)
    try fileManager.createDirectory(at: taken, withIntermediateDirectories: false)
    #expect(ExclusiveRename.rename(renamed, to: taken) == EEXIST)
    try Data([9]).write(to: taken.appendingPathComponent("keep"))
    #expect(ExclusiveRename.rename(renamed, to: taken) == EEXIST)
    #expect(try Data(contentsOf: taken.appendingPathComponent("keep")) == Data([9]))
    #expect(fileManager.fileExists(atPath: renamed.appendingPathComponent("a.ARW").path))

    // Same-volume folder move into another folder.
    let into = folder.appendingPathComponent("Into", isDirectory: true)
    try fileManager.createDirectory(at: into, withIntermediateDirectories: false)
    let result = FileTransferService.perform(
        FileTransferRequest(sourceURLs: [renamed], destinationFolderURL: into, operation: .move),
        progress: { _ in }, shouldCancel: { false })
    #expect(result.failures.isEmpty, "\(result.failures.map(\.message))")
    #expect(try Data(contentsOf: into.appendingPathComponent("Trip 2024/a.ARW")) == Data([5]))
    #expect(!fileManager.fileExists(atPath: renamed.path))
}
