import Foundation
import ImageIO
import Testing
@testable import LightboxNative

private func writeJPEG(_ url: URL, width: Int, height: Int) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    let image = try #require(context.makeImage())
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func asset(_ url: URL, loaded: Bool = false) -> LightboxAsset {
    LightboxAsset(originalName: url.lastPathComponent, width: 1, height: 1, tags: [], sourceURL: url,
                  addedAt: .distantPast, palette: MockPalette.imported[0], metadataLoaded: loaded)
}

@Test func metadataTargetsSkipKnownDimensionsAndRespectLimits() {
    let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/meta/\($0).jpg") }
    let snapshot = urls.enumerated().map { asset($1, loaded: $0 == 1) }
    let targets = AssetMetadataLoader.targets(for: snapshot, metadataLimit: 3, tagLimit: 4, loadsFinderTags: true)
    // Dimensions for the first three that lack them; tags for the first four;
    // every image for Camera Raw settings.
    #expect(targets.map(\.url.lastPathComponent) == ["0.jpg", "1.jpg", "2.jpg", "3.jpg", "4.jpg"])
    #expect(targets.map(\.shouldLoadDimensions) == [true, false, true, false, false])
    #expect(targets.map(\.shouldLoadTags) == [true, true, true, true, false])
    #expect(targets.allSatisfy { $0.shouldCheckCameraRaw })
    let none = AssetMetadataLoader.targets(for: snapshot, metadataLimit: 0, tagLimit: 0, loadsFinderTags: true)
    #expect(none.allSatisfy { !$0.shouldLoadDimensions && !$0.shouldLoadTags && $0.shouldCheckCameraRaw })
}

@Test @MainActor func metadataLoaderReadsSavesAndReportsInBatches() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxMetadataLoader-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = try (0..<40).map { index -> URL in
        let url = folder.appendingPathComponent(String(format: "%02d.jpg", index))
        try writeJPEG(url, width: 30, height: 20)
        return url
    }
    let database = folder.appendingPathComponent("index.sqlite")
    // As in a refresh: the folder snapshot is indexed first, metadata fills it in.
    let source = LibrarySource(id: "meta", name: "Meta", rootURL: folder, kind: .external)
    LightboxIndexStore(databaseURL: database).replaceVisibleSnapshot(
        source: source, folderURL: folder, folders: [], assets: urls.map { asset($0) })
    let loader = AssetMetadataLoader(indexDatabaseURL: database)
    var progress: [Int] = []
    var updated = 0
    var finished = false
    loader.onBatch = { updates, processed, _ in
        progress.append(processed)
        updated += updates.count
    }
    loader.onFinish = { _, _ in finished = true }
    let targets = AssetMetadataLoader.targets(for: urls.map { asset($0) }, metadataLimit: 40, tagLimit: 0, loadsFinderTags: false)
    loader.start(.init(targets: targets, sourceID: "meta", folderURL: folder, refreshID: 1, startDelayMilliseconds: 0))
    await waitWhile { !finished }
    #expect(finished)
    #expect(progress == [32, 40])
    #expect(updated == 40)
    #expect(!loader.isRunning)
    let saved = LightboxIndexStore(databaseURL: database).cachedDimensions(sourceID: "meta", parentPath: folder.path)
    #expect(saved.count == 40 && saved.values.allSatisfy { $0.width == 30 && $0.height == 20 })

    // Cancelling stops the reports; nothing finishes.
    var lateReports = 0
    finished = false
    loader.onBatch = { _, _, _ in lateReports += 1 }
    loader.start(.init(targets: targets, sourceID: "meta", folderURL: folder, refreshID: 2, startDelayMilliseconds: 50))
    loader.cancel()
    try await Task.sleep(for: .milliseconds(300))
    #expect(lateReports == 0 && !finished)
}

@Test func storedImageDimensionsRoundTripAndStayInsideTheFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxStoredDimensions-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LightboxIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
    let signature = FileContentSignature(modificationTime: 100, fileSize: 3)
    func entry(_ path: String, _ width: CGFloat) -> StoredImageDimensions {
        StoredImageDimensions(path: path, signature: signature, width: width, height: 20)
    }
    store.storeImageDimensions([entry("/shoot/a.jpg", 30), entry("/shoot/day 2/b.jpg", 40), entry("/shoot2/c.jpg", 50)])
    // A later read of the same file replaces the old size.
    store.storeImageDimensions([entry("/shoot/a.jpg", 35)])
    #expect(Set(store.storedImageDimensions(under: "/shoot").keys) == ["/shoot/a.jpg", "/shoot/day 2/b.jpg"])
    #expect(store.storedImageDimensions(under: "/shoot/")["/shoot/a.jpg"]?.width == 35)
    let byPath = store.storedImageDimensions(paths: ["/shoot2/c.jpg", "/missing.jpg"])
    #expect(byPath.count == 1 && byPath["/shoot2/c.jpg"] == entry("/shoot2/c.jpg", 50))
}

@Test @MainActor func metadataLoaderReusesStoredSizesUntilTheFileChanges() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxStoredReuse-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("photo.jpg")
    try writeJPEG(url, width: 30, height: 20)
    let database = folder.appendingPathComponent("index.sqlite")
    final class Probes: @unchecked Sendable { var count = 0 }
    let probes = Probes()
    let loader = AssetMetadataLoader(indexDatabaseURL: database) { url in
        probes.count += 1
        return ImageProbe.dimensions(for: url)
    }
    func listed() throws -> LightboxAsset {
        let signature = try #require(FileContentSignature(url: url))
        return LightboxAsset(originalName: "photo.jpg", width: 1, height: 1, tags: [], sourceURL: url,
            addedAt: .distantPast, contentModifiedAt: Date(timeIntervalSince1970: signature.modificationTime),
            fileSize: signature.fileSize, palette: MockPalette.imported[0], metadataLoaded: false)
    }
    func load() async throws -> CGSize? {
        var size: CGSize?
        var finished = false
        loader.onBatch = { updates, _, _ in
            if let update = updates.first, let width = update.width, let height = update.height {
                size = CGSize(width: width, height: height)
            }
        }
        loader.onFinish = { _, _ in finished = true }
        let targets = AssetMetadataLoader.targets(for: [try listed()], metadataLimit: 1, tagLimit: 0, loadsFinderTags: false)
        loader.start(.init(targets: targets, sourceID: "s", folderURL: folder, refreshID: 1, startDelayMilliseconds: 0))
        await waitWhile { !finished }
        return size
    }
    #expect(try await load() == CGSize(width: 30, height: 20))
    #expect(probes.count == 1)
    // Unchanged: the stored size, no decode.
    #expect(try await load() == CGSize(width: 30, height: 20))
    #expect(probes.count == 1)
    // Rewritten: decoded again.
    try writeJPEG(url, width: 64, height: 48)
    #expect(try await load() == CGSize(width: 64, height: 48))
    #expect(probes.count == 2)
}

@Test func recursiveResultsTakeStoredSizesOnlyForTheSameFileVersion() {
    let url = URL(fileURLWithPath: "/shoot/a.jpg")
    let listed = LightboxAsset(originalName: "a.jpg", width: 1, height: 1, tags: [], sourceURL: url,
        addedAt: .distantPast, contentModifiedAt: Date(timeIntervalSince1970: 100), fileSize: 3,
        palette: MockPalette.imported[0], metadataLoaded: false)
    let stored = ["/shoot/a.jpg": StoredImageDimensions(path: "/shoot/a.jpg",
        signature: FileContentSignature(modificationTime: 100.0000002, fileSize: 3), width: 30, height: 20)]
    let merged = SearchMetadataSnapshot.mergingStored(stored, into: [listed])[0]
    #expect(merged.metadataLoaded && merged.width == 30 && merged.height == 20)
    var edited = listed
    edited.fileSize = 4
    #expect(SearchMetadataSnapshot.mergingStored(stored, into: [edited]) == [edited])
}
