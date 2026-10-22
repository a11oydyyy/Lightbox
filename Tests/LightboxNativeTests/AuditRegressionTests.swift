import AppKit
import Foundation
import Testing
import Quartz
@testable import LightboxNative

@MainActor
private final class AuditPanel: QuickLookPanelDriving {
    var isVisible = false
    func open() { isVisible = true }
    func close() { isVisible = false }
    func reload() {}
}

@MainActor
@Test func auditMultiQuickLookArrowsMustPassToSystem() throws {
    let controller = QuickLookController(panel: AuditPanel())
    controller.show([URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")])
    for key: UInt16 in [123, 124, 125, 126] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
        let handled = controller.previewPanel(nil, handle: event)
        #expect(handled == false, "Multi-item arrow \(key) must not be swallowed")
    }
}

private final class AuditTrash: @unchecked Sendable {
    let folder: URL
    let defaults: UserDefaults
    var delay: Double = 0
    init(_ folder: URL, _ defaults: UserDefaults) { self.folder = folder; self.defaults = defaults }
    func move(_ url: URL) -> URL? {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let target = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            LightboxLibraryStore.recordRestoreDestination(originalURL: url, trashURL: target, defaults: defaults)
            return target
        } catch { return nil }
    }
    func restore(_ url: URL) -> TrashRestoreResult {
        LightboxLibraryStore.restoreFromRecordedDestination(url, defaults: defaults).map(TrashRestoreResult.restored) ?? .failed
    }
}

@MainActor
@Test func auditTrashCollisionRedoMustNotDeleteReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditCollision-\(UUID())")
    let work = root.appendingPathComponent("work")
    let trashURL = root.appendingPathComponent("trash")
    for p in [work, trashURL] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "Audit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let trash = AuditTrash(trashURL, defaults)
    let undo = UndoManager(); undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         systemTrashMover: { trash.move($0) }, systemTrashRestorer: { trash.restore($0) },
                         renameUndoManager: { undo })
    let a = work.appendingPathComponent("a.jpg")
    try Data("original".utf8).write(to: a)
    let asset = LightboxAsset(originalName: "a.jpg", width: 1, height: 1, tags: [], sourceURL: a,
                             addedAt: .now, palette: MockPalette.imported[0])
    undo.beginUndoGrouping(); state.moveAssetsToSystemTrash([asset]); undo.endUndoGrouping()
    await waitWhile { state.trashMoveTask != nil }
    try Data("replacement".utf8).write(to: a)
    undo.undo()
    let restored = work.appendingPathComponent("a-2.jpg")
    await waitWhile { !FileManager.default.fileExists(atPath: restored.path) }
    #expect(try Data(contentsOf: restored) == Data("original".utf8))
    undo.redo()
    await waitWhile { state.trashMoveTask != nil }
    let replacementExists = FileManager.default.fileExists(atPath: a.path)
    let restoredExists = FileManager.default.fileExists(atPath: restored.path)
    #expect(replacementExists, "Redo must preserve the unrelated replacement")
    #expect(restoredExists == false, "Redo must trash the file actually restored")
}

@MainActor
@Test func auditImmediateTrashUndoMustWaitForPendingMove() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditPending-\(UUID())")
    let work = root.appendingPathComponent("work")
    let trashURL = root.appendingPathComponent("trash")
    for p in [work, trashURL] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "Audit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let trash = AuditTrash(trashURL, defaults); trash.delay = 0.2
    let undo = UndoManager(); undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         systemTrashMover: { trash.move($0) }, systemTrashRestorer: { trash.restore($0) },
                         renameUndoManager: { undo })
    let a = work.appendingPathComponent("a.jpg")
    try Data([1]).write(to: a)
    let asset = LightboxAsset(originalName: "a.jpg", width: 1, height: 1, tags: [], sourceURL: a,
                             addedAt: .now, palette: MockPalette.imported[0])
    undo.beginUndoGrouping(); state.moveAssetsToSystemTrash([asset]); undo.endUndoGrouping()
    undo.undo()
    await waitWhile { state.trashMoveTask != nil }
    #expect(FileManager.default.fileExists(atPath: a.path), "Undo while the I/O is pending must not be consumed")
}

@MainActor
@Test func auditRenameRawExtensionUndoMustRestoreSidecar() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditRename-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "Audit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let undo = UndoManager(); undo.groupsByEvent = false
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         renameUndoManager: { undo })
    let raw = root.appendingPathComponent("a.CR3")
    try Data([1]).write(to: raw)
    try Data([2]).write(to: root.appendingPathComponent("a.xmp"))
    undo.beginUndoGrouping(); state.rename([FileRenameItem(url: raw, newName: "b.jpg")]); undo.endUndoGrouping()
    await state.renameTask?.value
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.xmp").path))
    undo.undo(); await state.renameTask?.value
    #expect(FileManager.default.fileExists(atPath: raw.path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.xmp").path), "Undo must use all actual moves")
}


@MainActor
@Test func auditRecursiveWatchMustObserveRawSidecarEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditSidecarWatch-\(UUID())")
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let xmp = child.appendingPathComponent("a.xmp")
    try Data("before".utf8).write(to: xmp)
    try Data([1]).write(to: child.appendingPathComponent("a.CR3"))
    let monitor = DirectoryChangeMonitor(url: root, recursive: true)
    var changes = 0
    monitor.start { changes += 1 }
    defer { monitor.stop() }
    try Data([1]).write(to: child.appendingPathComponent("control.jpg"))
    await waitWhile { changes == 0 }
    try #require(changes > 0, "The live monitor must observe the image control")
    try await Task.sleep(for: .seconds(1))
    let baseline = changes
    try Data("<crs:HasSettings>True</crs:HasSettings>".utf8).write(to: xmp)
    try await Task.sleep(for: .seconds(2))
    let observedSidecar = changes > baseline
    try Data([2]).write(to: child.appendingPathComponent("control2.jpg"))
    await waitWhile { changes == baseline }
    #expect(changes > baseline, "The monitor must still be live after the sidecar edit")
    #expect(observedSidecar, "Sidecar changes affect Camera Raw badges and filters even with other files hidden")
}


@MainActor
private struct AuditFixture {
    let root: URL
    let work: URL
    let trash: AuditTrash
    let defaults: UserDefaults
    let suite: String
    let undo: UndoManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditHistory-\(UUID())")
        work = root.appendingPathComponent("work")
        let trashURL = root.appendingPathComponent("trash")
        for folder in [work, trashURL] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        suite = "Audit-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        trash = AuditTrash(trashURL, defaults)
        undo = UndoManager()
        undo.groupsByEvent = false
    }
    func state(restorer: (@Sendable (URL) async -> TrashRestoreResult)? = nil) -> AppState {
        AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                 systemTrashMover: { [trash] in trash.move($0) },
                 systemTrashRestorer: restorer ?? { [trash] in trash.restore($0) }, renameUndoManager: { undo })
    }
    func url(_ name: String) -> URL { work.appendingPathComponent(name) }
    func asset(_ name: String) -> LightboxAsset {
        LightboxAsset(originalName: name, width: 1, height: 1, tags: [], sourceURL: url(name),
                      addedAt: .now, palette: MockPalette.imported[0])
    }
    func record(_ operation: () -> Void) {
        undo.beginUndoGrouping(); operation(); undo.endUndoGrouping()
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Test func auditPartialRestoreRedoPreservesFailedItemsAndReplacements() async throws {
    let f = try AuditFixture()
    defer { f.cleanUp() }
    let state = f.state { [trash = f.trash] url in
        url.lastPathComponent.hasSuffix("-b.jpg") ? .failed : trash.restore(url)
    }
    for name in ["a.jpg", "b.jpg"] { try Data("original".utf8).write(to: f.url(name)) }
    f.record { state.moveAssetsToSystemTrash([f.asset("a.jpg"), f.asset("b.jpg")]) }
    await state.fileOperationTask?.value
    try Data("replacement".utf8).write(to: f.url("b.jpg"))
    f.undo.undo()
    await state.fileOperationTask?.value
    #expect(state.fileOperationAlert != nil)
    f.undo.redo()
    await state.fileOperationTask?.value
    #expect(try Data(contentsOf: f.url("b.jpg")) == Data("replacement".utf8))
    #expect(FileManager.default.fileExists(atPath: f.url("a.jpg").path) == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.folder.path).count == 2)
}

@MainActor
@Test func auditRapidUndoRedoSerializesRenameAndTrash() async throws {
    let f = try AuditFixture()
    defer { f.cleanUp() }
    f.trash.delay = 0.1
    let state = f.state()
    try Data("original".utf8).write(to: f.url("a.jpg"))
    f.record { state.rename([FileRenameItem(url: f.url("a.jpg"), newName: "b.jpg")]) }
    await state.fileOperationTask?.value
    f.record { state.moveAssetsToSystemTrash([f.asset("b.jpg")]) }
    f.undo.undo(); f.undo.undo()
    await state.fileOperationTask?.value
    #expect(try Data(contentsOf: f.url("a.jpg")) == Data("original".utf8))
    #expect(state.fileOperationAlert == nil)
    f.undo.redo(); f.undo.redo()
    await state.fileOperationTask?.value
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.work.path).isEmpty)
    #expect(state.fileOperationAlert == nil)
    #expect(state.pendingTrashOperations == 0 && state.trashMovingAssetIDs.isEmpty)
}

@MainActor
@Test func auditEarlierRenameFollowsTheActualCollisionRestore() async throws {
    let f = try AuditFixture()
    defer { f.cleanUp() }
    let state = f.state()
    try Data("original".utf8).write(to: f.url("a.jpg"))
    f.record { state.rename([FileRenameItem(url: f.url("a.jpg"), newName: "b.jpg")]) }
    await state.fileOperationTask?.value
    f.record { state.moveAssetsToSystemTrash([f.asset("b.jpg")]) }
    await state.fileOperationTask?.value
    try Data("replacement".utf8).write(to: f.url("b.jpg"))
    f.undo.undo(); f.undo.undo()
    await state.fileOperationTask?.value
    #expect(try Data(contentsOf: f.url("a.jpg")) == Data("original".utf8))
    #expect(try Data(contentsOf: f.url("b.jpg")) == Data("replacement".utf8))
    #expect(state.fileOperationAlert == nil)
    f.undo.redo(); f.undo.redo()
    await state.fileOperationTask?.value
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.work.path) == ["b.jpg"])
    #expect(try Data(contentsOf: f.url("b.jpg")) == Data("replacement".utf8))
}

@MainActor
@Test func auditRenameUndoDoesNotCollectANewSidecar() async throws {
    let f = try AuditFixture()
    defer { f.cleanUp() }
    let state = f.state()
    try Data([1]).write(to: f.url("a.CR3"))
    f.record { state.rename([FileRenameItem(url: f.url("a.CR3"), newName: "b.CR3")]) }
    await state.fileOperationTask?.value
    try Data("new sidecar".utf8).write(to: f.url("b.xmp"))
    f.undo.undo()
    await state.fileOperationTask?.value
    #expect(FileManager.default.fileExists(atPath: f.url("a.CR3").path))
    #expect(try Data(contentsOf: f.url("b.xmp")) == Data("new sidecar".utf8))
    #expect(FileManager.default.fileExists(atPath: f.url("a.xmp").path) == false)
}

@MainActor
@Test func auditSingleQuickLookStillFollowsAllGalleryArrows() throws {
    let controller = QuickLookController(panel: AuditPanel())
    controller.show([URL(fileURLWithPath: "/tmp/a.pdf")])
    var arrows: [UInt16] = []
    controller.onArrow = { arrows.append($0) }
    for key: UInt16 in [123, 124, 125, 126] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
        let handled = controller.previewPanel(nil, handle: event)
        #expect(handled)
    }
    #expect(arrows == [123, 124, 125, 126])
}
