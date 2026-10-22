import Foundation
import SQLite3
import Testing
@testable import LightboxNative

// A snapshot that fails partway rolls back as a whole: the previous snapshot
// stays, and the caller learns the write did not happen.
@Test(arguments: ["insert", "delete"])
func failedSnapshotWriteKeepsThePreviousSnapshot(failingStep: String) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightboxIndexFailure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("index.sqlite")
    let source = LibrarySource.favorites(rootURL: root)
    func asset(_ name: String) throws -> LightboxAsset {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return LightboxAsset(originalName: name, width: 300, height: 200, tags: [], sourceURL: url,
                             addedAt: .now, palette: MockPalette.imported[0], metadataLoaded: true)
    }
    func cachedNames(_ store: LightboxIndexStore) -> [String] {
        (store.cachedVisibleSnapshot(source: source, folderURL: root)?.assets.map(\.originalName) ?? []).sorted()
    }

    let store = LightboxIndexStore(databaseURL: databaseURL)
    #expect(store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [],
                                         assets: [try asset("a.jpg"), try asset("b.jpg")]))
    #expect(cachedNames(store) == ["a.jpg", "b.jpg"])

    // Make SQLite refuse one step of the next replacement.
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let trigger = failingStep == "insert"
        ? "CREATE TRIGGER refuse BEFORE INSERT ON items WHEN NEW.path LIKE '%broken%' BEGIN SELECT RAISE(ABORT, 'refused'); END;"
        : "CREATE TRIGGER refuse BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT, 'refused'); END;"
    #expect(sqlite3_exec(database, trigger, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let replaced = store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [],
                                                assets: [try asset("c.jpg"), try asset("broken.jpg")])
    #expect(!replaced)
    #expect(cachedNames(store) == ["a.jpg", "b.jpg"])

    // The store is still usable once the fault is gone.
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, "DROP TRIGGER refuse;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    #expect(store.replaceVisibleSnapshot(source: source, folderURL: root, folders: [],
                                         assets: [try asset("c.jpg")]))
    #expect(cachedNames(store) == ["c.jpg"])
}
