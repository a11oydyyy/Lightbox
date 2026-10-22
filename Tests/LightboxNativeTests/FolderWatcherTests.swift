import Foundation
import Testing
@testable import LightboxNative

private final class MonitorCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [(URL, Bool)] = []
    func record(_ url: URL, _ recursive: Bool) { lock.withLock { value.append((url, recursive)) } }
    var made: [(URL, Bool)] { lock.withLock { value } }
}

@Test @MainActor func folderWatcherRestartsOnlyWhenTheFolderOrDepthChanges() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxWatcher-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let count = MonitorCount()
    let watcher = FolderWatcher { url, recursive in
        count.record(url, recursive)
        return DirectoryChangeMonitor(url: url, recursive: recursive)
    }
    var changes = 0
    watcher.onChange = { changes += 1 }

    #expect(watcher.watch(folder, includingSubfolders: false))
    #expect(!watcher.watch(folder, includingSubfolders: false))
    #expect(count.made.count == 1)
    #expect(watcher.watch(folder, includingSubfolders: true))
    #expect(count.made.count == 2 && count.made[1].1)

    try Data([1]).write(to: folder.appendingPathComponent("new.jpg"))
    await waitWhile { changes == 0 }
    #expect(changes > 0)

    watcher.stop()
    #expect(!watcher.isWatching)
    #expect(watcher.watch(folder, includingSubfolders: true))
    #expect(count.made.count == 3)
    watcher.stop()
}
