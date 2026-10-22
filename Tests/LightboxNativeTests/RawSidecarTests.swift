import Foundation
import Testing
@testable import LightboxNative

private func makeFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func names(in folder: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
}

@Test func rawSidecarsBelongToRawFilesOnly() {
    let raw = URL(fileURLWithPath: "/p/IMG_1.CR3")
    #expect(RawSidecar.candidates(for: raw).map(\.lastPathComponent) == ["IMG_1.xmp", "IMG_1.CR3.xmp"])
    #expect(RawSidecar.candidates(for: URL(fileURLWithPath: "/p/IMG_1.JPG")).isEmpty)
    #expect(RawSidecar.name(of: URL(fileURLWithPath: "/p/IMG_1.xmp"), for: raw, whenNamed: "Trip.CR3") == "Trip.xmp")
    #expect(RawSidecar.name(of: URL(fileURLWithPath: "/p/IMG_1.CR3.xmp"), for: raw, whenNamed: "Trip.CR3") == "Trip.CR3.xmp")
    let urls = [raw, URL(fileURLWithPath: "/p/IMG_1.xmp"), URL(fileURLWithPath: "/p/other.xmp")]
    #expect(RawSidecar.withoutCompanions(urls).map(\.lastPathComponent) == ["IMG_1.CR3", "other.xmp"])
}

@Test func renamingARawRenamesItsSidecarsAndUndoPutsThemBack() throws {
    let folder = try makeFolder("SidecarRename")
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["IMG_1.CR3", "IMG_1.xmp", "IMG_1.JPG", "IMG_2.NEF", "IMG_2.NEF.xmp"] {
        try Data([1]).write(to: folder.appendingPathComponent(name))
    }
    let moves = try FileRenamer.perform([
        FileRenameItem(url: folder.appendingPathComponent("IMG_1.CR3"), newName: "Trip_1.CR3"),
        FileRenameItem(url: folder.appendingPathComponent("IMG_2.NEF"), newName: "Trip_2.NEF")
    ]).get()
    // The JPEG of the same shot keeps its name; the sidecars follow their RAW.
    #expect(names(in: folder) == ["Trip_1.CR3", "Trip_1.xmp", "IMG_1.JPG", "Trip_2.NEF", "Trip_2.NEF.xmp"])

    _ = try FileRenamer.perform(FileRenamer.reversal(of: moves)).get()
    #expect(names(in: folder) == ["IMG_1.CR3", "IMG_1.xmp", "IMG_1.JPG", "IMG_2.NEF", "IMG_2.NEF.xmp"])
}

@Test func renamingARawFailsRatherThanReplacingAnotherSidecar() throws {
    let folder = try makeFolder("SidecarRenameClash")
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["IMG_1.CR3", "IMG_1.xmp", "Trip.xmp"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
    let result = FileRenamer.perform([FileRenameItem(url: folder.appendingPathComponent("IMG_1.CR3"), newName: "Trip.CR3")])
    #expect(result == .failure(.exists("Trip.xmp")))
    #expect(names(in: folder) == ["IMG_1.CR3", "IMG_1.xmp", "Trip.xmp"])
}

@Test func movingAndCopyingARawTakesItsSidecar() throws {
    let root = try makeFolder("SidecarTransfer")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("from")
    let destination = root.appendingPathComponent("to")
    for folder in [source, destination] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for name in ["A.ARW", "A.xmp", "B.ARW", "B.xmp"] { try Data([1]).write(to: source.appendingPathComponent(name)) }
    // "B.ARW" is free at the destination but its sidecar's name is not: both take the next name.
    try Data([2]).write(to: destination.appendingPathComponent("B.xmp"))

    let moved = FileTransferService.perform(
        FileTransferRequest(sourceURLs: [source.appendingPathComponent("A.ARW"), source.appendingPathComponent("A.xmp"),
                                         source.appendingPathComponent("B.ARW")],
                            destinationFolderURL: destination, operation: .move),
        progress: { _ in })
    #expect(moved.failures.isEmpty)
    #expect(moved.successes.map(\.destinationURL.lastPathComponent) == ["A.ARW", "B 2.ARW"])
    #expect(names(in: source).isEmpty)
    #expect(names(in: destination) == ["A.ARW", "A.xmp", "B.xmp", "B 2.ARW", "B 2.xmp"])

    let copied = FileTransferService.perform(
        FileTransferRequest(sourceURLs: [destination.appendingPathComponent("A.ARW")], destinationFolderURL: source, operation: .copy),
        progress: { _ in })
    #expect(copied.failures.isEmpty)
    #expect(names(in: source) == ["A.ARW", "A.xmp"])
}

// Move to Trash takes the sidecar along; ⌘Z brings both back, redo trashes both again.
@MainActor
@Test func trashingARawTakesItsSidecarAndUndoBringsItBack() async throws {
    let root = try makeFolder("SidecarTrash")
    let work = root.appendingPathComponent("folder")
    let trash = FakeTrash(folder: root.appendingPathComponent("Trash"))
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trash.folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["IMG_1.CR3", "IMG_1.xmp", "IMG_1.JPG"] { try Data([1]).write(to: work.appendingPathComponent(name)) }
    let suite = "LightboxSidecarTrash-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager()
    undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         systemTrashMover: { trash.move($0) }, systemTrashRestorer: { trash.putBack($0) },
                         renameUndoManager: { undo })
    let source = LibrarySource.favorites(rootURL: work)
    state.sources = [source]
    state.chooseSource(source.id)
    await waitWhile { state.activeAssets.count != 2 || state.libraryLoadingStatus != nil }
    func waitFor(_ expected: Set<String>) async {
        await waitWhile { names(in: work) != expected }
        #expect(names(in: work) == expected)
    }

    let raw = try #require(state.activeAssets.first { $0.originalName == "IMG_1.CR3" })
    state.replaceSelection(with: [raw.id])
    undo.beginUndoGrouping()
    state.deleteSelectedAssets()
    undo.endUndoGrouping()
    await waitFor(["IMG_1.JPG"])
    #expect(names(in: trash.folder).count == 2)

    undo.undo()
    await waitFor(["IMG_1.CR3", "IMG_1.xmp", "IMG_1.JPG"])
    #expect(state.fileOperationAlert == nil)
    undo.redo()
    await waitFor(["IMG_1.JPG"])
}
