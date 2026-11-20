import Foundation
import Testing
@testable import LightboxNative

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StaleTemp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private final class Trashed: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func move(_ url: URL) -> URL? { lock.lock(); defer { lock.unlock() }; urls.append(url); return url }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

@Test func staleTemporaryItemsClassifyByName() {
    #expect(StaleTemporaryItems.kind(ofName: ".lightbox-transfer-\(UUID().uuidString)") == .partialCopy)
    #expect(StaleTemporaryItems.kind(ofName: ".lightbox-export-\(UUID().uuidString)") == .partialCopy)
    #expect(StaleTemporaryItems.kind(ofName: ".lightbox-rename-\(UUID().uuidString)-0") == .renamedOriginal)
    #expect(StaleTemporaryItems.kind(ofName: ".lightbox-other") == nil)
    #expect(StaleTemporaryItems.kind(ofName: "photo.jpg") == nil)
}

@Test func staleLeftoversAreTrashedOrReportedAndFreshOnesLeftAlone() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let transfer = ".lightbox-transfer-\(UUID().uuidString)"
    let export = ".lightbox-export-\(UUID().uuidString)"
    let rename = StaleTemporaryItems.renameTemporaryName(index: 0, original: "a.jpg")
    try Data([1]).write(to: folder.appendingPathComponent(transfer))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(export), withIntermediateDirectories: false)
    try Data([2]).write(to: folder.appendingPathComponent(rename))
    let names = [transfer, export, rename, "photo.jpg"]

    // Just created: an operation may be running, nothing is touched.
    let trash = Trashed()
    let fresh = StaleTemporaryItems.process(names: names, in: folder, trash: { trash.move($0) })
    #expect(fresh == StaleTemporaryItems.Outcome())
    #expect(trash.all.isEmpty)

    // Just inside the window: still untouched.
    let almost = StaleTemporaryItems.process(
        names: names, in: folder, now: Date().addingTimeInterval(StaleTemporaryItems.safetyWindow - 120), trash: { trash.move($0) })
    #expect(almost == StaleTemporaryItems.Outcome())

    // Past the window: partial copies go to the Trash, the renamed original is only reported.
    let later = Date().addingTimeInterval(StaleTemporaryItems.safetyWindow + 60)
    let outcome = StaleTemporaryItems.process(names: names, in: folder, now: later, trash: { trash.move($0) })
    #expect(Set(trash.all.map(\.lastPathComponent)) == [transfer, export])
    #expect(outcome.renamedOriginals.map(\.lastPathComponent) == [rename])
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(rename).path))
}

@Test func failedTrashMoveIsNotReportedAsTrashedAndMissingEntriesAreSkipped() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let transfer = ".lightbox-transfer-\(UUID().uuidString)"
    try Data([1]).write(to: folder.appendingPathComponent(transfer))
    let later = Date().addingTimeInterval(StaleTemporaryItems.safetyWindow + 60)
    let outcome = StaleTemporaryItems.process(
        names: [transfer, ".lightbox-export-gone"], in: folder, now: later, trash: { _ in nil })
    #expect(outcome.trashed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(transfer).path))
}

@Test func inUseItemsAreLeftAloneHoweverOldTheyLook() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let busy = ".lightbox-transfer-\(UUID().uuidString)"
    let idle = ".lightbox-transfer-\(UUID().uuidString)"
    let busyRename = StaleTemporaryItems.renameTemporaryName(index: 0, original: "a.jpg")
    for name in [busy, idle, busyRename] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
    StaleTemporaryItems.registerInUse(folder.appendingPathComponent(busy))
    StaleTemporaryItems.registerInUse(folder.appendingPathComponent(busyRename))
    let later = Date().addingTimeInterval(StaleTemporaryItems.safetyWindow + 60)
    let trash = Trashed()
    let outcome = StaleTemporaryItems.process(names: [busy, idle, busyRename], in: folder, now: later, trash: { trash.move($0) })
    #expect(trash.all.map(\.lastPathComponent) == [idle])
    #expect(outcome.renamedOriginals.isEmpty)

    StaleTemporaryItems.unregisterInUse(folder.appendingPathComponent(busy))
    StaleTemporaryItems.unregisterInUse(folder.appendingPathComponent(busyRename))
    #expect(!StaleTemporaryItems.isInUse(folder.appendingPathComponent(busy)))
    let after = StaleTemporaryItems.process(names: [busy, busyRename], in: folder, now: later, trash: { trash.move($0) })
    #expect(trash.all.map(\.lastPathComponent) == [idle, busy])
    #expect(after.renamedOriginals.map(\.lastPathComponent) == [busyRename])
}

@Test func renamerAndTransferRegisterTheirTemporariesOnlyWhileRunning() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = folder.appendingPathComponent("a.jpg"), b = folder.appendingPathComponent("b.jpg")
    try Data([1]).write(to: a); try Data([2]).write(to: b)
    // A swap goes through temporary names, which are free again afterwards.
    let result = FileRenamer.perform([FileRenameItem(url: a, newName: "b.jpg"), FileRenameItem(url: b, newName: "a.jpg")], includingSidecars: false)
    guard case .success = result else { Issue.record("rename failed"); return }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(names.sorted() == ["a.jpg", "b.jpg"])
}

@Test func renameTemporaryNamesRoundTrip() throws {
    let id = UUID()
    for original in ["a.jpg", "my-photo-1.final-v2.ARW", "名字 with spaces.jpg", "noext", "x-0-y.png", "1-2"] {
        let name = StaleTemporaryItems.renameTemporaryName(id: id, index: 12, original: original)
        #expect(StaleTemporaryItems.kind(ofName: name) == .renamedOriginal)
        #expect(StaleTemporaryItems.parseRenameLeftover(name) == .init(index: 12, original: original))
        #expect(StaleTemporaryItems.restoredName(forTemporaryName: name) == original)
    }
}

@Test func longRenameTemporaryNamesTruncateOnCharacterBoundaryKeepingExtension() {
    for unit in ["a", "名", "👩‍👩‍👧‍👦"] {
        let original = String(repeating: unit, count: 300) + ".jpeg"
        let name = StaleTemporaryItems.renameTemporaryName(index: 3, original: original)
        #expect(name.utf8.count <= Int(NAME_MAX))
        let parsed = StaleTemporaryItems.parseRenameLeftover(name)
        #expect(parsed?.index == 3)
        let restored = parsed?.original ?? ""
        #expect(restored.hasSuffix(".jpeg"))
        let base = String(restored.dropLast(5))
        #expect(!base.isEmpty && base.allSatisfy { String($0) == unit })
        #expect(String(decoding: Array(name.utf8), as: UTF8.self) == name)
    }
    // An extension too long to keep is cut with the rest, still within the limit.
    let odd = StaleTemporaryItems.renameTemporaryName(index: 0, original: "a." + String(repeating: "x", count: 400))
    #expect(odd.utf8.count <= Int(NAME_MAX))
}

@Test func oldFormatAndUnsafeRenameNamesRestoreToRecoveredNames() {
    let id = UUID().uuidString
    #expect(StaleTemporaryItems.parseRenameLeftover(".lightbox-rename-\(id)-4") == .init(index: 4, original: nil))
    #expect(StaleTemporaryItems.restoredName(forTemporaryName: ".lightbox-rename-\(id)-4") == "Recovered 4")
    #expect(StaleTemporaryItems.restoredName(forTemporaryName: ".lightbox-rename-\(id)-4-..") == "Recovered 4")
    #expect(StaleTemporaryItems.restoredName(forTemporaryName: ".lightbox-rename-\(id)-4-.lightbox-transfer-x") == "Recovered 4")
    #expect(StaleTemporaryItems.parseRenameLeftover(".lightbox-rename-x-0") == nil)
    #expect(StaleTemporaryItems.restoredName(forTemporaryName: ".lightbox-rename-x-0") == "Recovered 0")
}

@Test func restoreBringsLeftoversBackWithoutReplacingAnything() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    let plain = StaleTemporaryItems.renameTemporaryName(index: 0, original: "IMG_1.jpg")
    let clash = StaleTemporaryItems.renameTemporaryName(index: 1, original: "IMG_2.jpg")
    let old = ".lightbox-rename-\(UUID().uuidString)-2"
    try Data([1]).write(to: folder.appendingPathComponent(plain))
    try Data([2]).write(to: folder.appendingPathComponent(clash))
    try Data([3]).write(to: folder.appendingPathComponent(old))
    try Data([9]).write(to: folder.appendingPathComponent("IMG_2.jpg"))

    let restored = StaleTemporaryItems.restore([plain, clash, old].map { folder.appendingPathComponent($0) })
    #expect(restored.map(\.lastPathComponent) == ["IMG_1.jpg", "IMG_2 2.jpg", "Recovered 2"])
    #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_1.jpg")) == Data([1]))
    #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_2.jpg")) == Data([9]))
    #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_2 2.jpg")) == Data([2]))
    #expect(try Data(contentsOf: folder.appendingPathComponent("Recovered 2")) == Data([3]))
    #expect(try fm.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".lightbox-") })
}

@Test func renamedOriginalsAreAnnouncedOncePerRun() {
    let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/\(StaleTemporaryItems.renameTemporaryName(index: 0, original: "x.jpg"))")
    #expect(StaleTemporaryItems.unannounced([url]) == [url])
    #expect(StaleTemporaryItems.unannounced([url]).isEmpty)
}

// The folder read reports temporary names even though hidden items are not listed.
@Test func folderSnapshotReportsTemporaryNamesWithoutListingThem() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let name = ".lightbox-transfer-\(UUID().uuidString)"
    try Data([1]).write(to: folder.appendingPathComponent(name))
    try Data([1]).write(to: folder.appendingPathComponent(".hidden"))
    let snapshot = LocalImageSource.loadFolderSnapshot(in: folder, sourceID: "t", rootURL: folder)
    #expect(snapshot.temporaryNames == [name])
    #expect(snapshot.entryCount == 0)
}
