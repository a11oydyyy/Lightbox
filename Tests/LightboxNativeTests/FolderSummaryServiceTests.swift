import Foundation
import Testing
@testable import LightboxNative

@Test func folderImageSummaryCountsDirectImagesAndPicksFinderFirstCover() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxFolderSummary-\(UUID())")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["IMG_10.jpg", "IMG_2.JPG", "notes.txt", ".hidden.jpg", "Nested/inner.jpg"] {
        try Data().write(to: folder.appendingPathComponent(name))
    }

    let summary = try #require(LocalImageSource.folderImageSummary(in: folder))
    #expect(summary.imageCount == 2)
    #expect(summary.coverURL?.lastPathComponent == "IMG_2.JPG")
    #expect(LocalImageSource.folderImageSummary(in: folder.appendingPathComponent("Missing")) == nil)
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
@Test func folderSummaryServiceReusesStoredSummaryUntilTheFolderChanges() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxFolderSummaryCache-\(UUID())")
    let folder = work.appendingPathComponent("Trip")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    try Data().write(to: folder.appendingPathComponent("a.jpg"))
    let database = work.appendingPathComponent("index.sqlite")
    let reads = ReadCounter()
    let read: @Sendable (URL) -> FolderImageSummary? = { url in
        reads.increment()
        return LocalImageSource.folderImageSummary(in: url)
    }

    func load(_ service: FolderSummaryService) async throws -> FolderImageSummary {
        var result: FolderImageSummary?
        service.request([folder]) { _, summary in result = summary }
        await waitWhile { result == nil }
        return try #require(result)
    }

    let first = FolderSummaryService(indexDatabaseURL: database, read: read)
    #expect(try await load(first).imageCount == 1)
    #expect(reads.value == 1)

    // A new session finds the stored summary; the unchanged folder is not read again.
    let second = FolderSummaryService(indexDatabaseURL: database, read: read)
    #expect(try await load(second).imageCount == 1)
    #expect(reads.value == 1)

    // Adding an image changes the folder's modification time, so it is re-read.
    try Data().write(to: folder.appendingPathComponent("b.jpg"))
    second.reset(keeping: [folder])
    #expect(try await load(second).imageCount == 2)
    #expect(reads.value == 2)
}
