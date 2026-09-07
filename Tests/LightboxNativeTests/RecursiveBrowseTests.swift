import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import Testing
@testable import LightboxNative

@Test func recursiveBrowseMigratesLegacyGridAndPersistsNewScope() throws {
    #expect(try JSONDecoder().decode(GalleryLayoutMode.self, from: Data("\"grid\"".utf8)) == .masonry)
    let data = try JSONEncoder().encode(GalleryLayoutMode.recursive)
    #expect(try JSONDecoder().decode(GalleryLayoutMode.self, from: data) == .recursive)
}

@Test func recursiveBrowseIncludesDeepImagesWithoutSearchCapOrDuplicates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child/deep")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("cover.jpg"))
    for index in 0..<2_005 { try Data().write(to: child.appendingPathComponent("photo-\(index).jpg")) }
    try Data().write(to: child.appendingPathComponent("notes.txt"))
    try Data().write(to: child.appendingPathComponent(".hidden.jpg"))
    try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: root)
    try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("alias.jpg"), withDestinationURL: root.appendingPathComponent("cover.jpg"))
    let result = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
        query: .parse(""), recursive: true, collectsFolders: false, skipsPackages: true,
        maxResults: .max, maxFolderResults: .max, maxVisited: .max)
    #expect(result.assets.count == 2_006)
    #expect(Set(result.assets.map(\.id)).count == 2_006)
    #expect(!result.limitReached)
    #expect(result.folders.isEmpty)
    let direct = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root, query: .parse(""), recursive: false)
    #expect(direct.assets.map(\.originalName) == ["cover.jpg"])
}

@MainActor
@Test func recursiveBrowseMonitorObservesNestedImageCreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var changed = false
    let monitor = DirectoryChangeMonitor(url: root, recursive: true)
    monitor.start { changed = true }
    defer { monitor.stop() }
    try Data().write(to: child.appendingPathComponent("new.jpg"))
    for _ in 0..<60 {
        if changed { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(changed)
}

@Test func recursiveBrowsePublishesRealDimensionsBeforeLayout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("portrait.png")
    let context = try #require(CGContext(data: nil, width: 40, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let result = LocalImageSource.searchAssets(in: root, sourceID: "test", rootURL: root,
        query: .parse(""), recursive: true, collectsFolders: false, probeDimensions: true)
    let asset = try #require(result.assets.first)
    #expect(asset.width == 40)
    #expect(asset.height == 60)
    #expect(asset.metadataLoaded)
}

@MainActor
@Test func recursiveBrowseClickFlushesLatestPendingCardFrame() async throws {
    let coordinator = GalleryFrameUpdateCoordinator()
    let latest = CGRect(x: 240, y: 380, width: 160, height: 240)
    var deliveries = 0
    var delivered: CGRect?
    let apply: @MainActor (GalleryAssetFrameSnapshot, Set<String>) -> Void = { snapshot, _ in
        deliveries += 1
        delivered = snapshot.previewFrames["photo"]
    }
    coordinator.submit(.init(previewFrames: ["photo": CGRect(x: 0, y: 0, width: 160, height: 240)]), activeAssetIDs: ["photo"], apply: apply)
    coordinator.submit(.init(previewFrames: ["photo": latest]), activeAssetIDs: ["photo"], apply: apply)
    coordinator.flush(apply: apply)
    #expect(delivered == latest)
    try await Task.sleep(for: .milliseconds(30))
    #expect(deliveries == 1)
}

@Test func previewImageClipKeepsReturningCardBelowHeader() {
    let path = PreviewImageViewportClip().path(in: CGRect(x: 0, y: 0, width: 1200, height: 800))
    #expect(!path.contains(CGPoint(x: 600, y: 30)))
    #expect(path.contains(CGPoint(x: 600, y: 53)))
    #expect(path.boundingRect == CGRect(x: 0, y: 52, width: 1200, height: 748))
}
