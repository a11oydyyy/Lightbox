import Foundation
import SQLite3
import Testing
@testable import LightboxNative

private final class SQLiteWriteHold: @unchecked Sendable {
    private let database: OpaquePointer
    init(url: URL) throws {
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        database = try #require(connection)
        #expect(sqlite3_exec(database, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
    }
    func release() { _ = sqlite3_exec(database, "COMMIT;", nil, nil, nil) }
    deinit { sqlite3_close(database) }
}

@Test @MainActor func sourcePinRespondsBeforeBackgroundIndexWriteLockIsReleased() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxIndexResponse-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "LightboxIndexResponse-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: work) }
    let source = LibrarySource(id: "index-response", name: "Source", rootURL: work, kind: .external)
    let pinned = LibrarySource(id: "pinned-under-lock", name: "Pinned", rootURL: work.appendingPathComponent("pinned"), kind: .external)
    try FileManager.default.createDirectory(at: pinned.rootURL, withIntermediateDirectories: true)
    let tab = LightboxTab(source: source, folderURL: work)
    LightboxTabStore.save(tabs: [tab], activeTabID: tab.id, defaults: defaults)
    let databaseURL = work.appendingPathComponent("index.sqlite")
    let state = AppState(indexDatabaseURL: databaseURL, libraryDefaults: defaults)
    for _ in 0..<100 where state.libraryLoadingStatus != nil { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(100))
    let hold = try SQLiteWriteHold(url: databaseURL)
    let release = Task.detached {
        try? await Task.sleep(for: .milliseconds(300))
        hold.release()
    }
    let clock = ContinuousClock()
    let start = clock.now
    state.pinSource(pinned, selectPinnedFolder: false)
    let elapsed = start.duration(to: clock.now)
    #expect(state.sources.contains { $0.id == pinned.id })
    #expect(elapsed < .milliseconds(100), "Pin blocked on index lock: \(elapsed)")
    await release.value
    func indexedName() -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sources WHERE id='pinned-under-lock';", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
    let deadline = clock.now.advanced(by: .seconds(2))
    while indexedName() == nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(indexedName() == pinned.name)
}
