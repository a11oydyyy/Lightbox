import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LightboxNative

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraRaw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func sidecar(hasSettings: Bool) -> String {
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
     crs:Version="17.0" crs:HasSettings="\(hasSettings ? "True" : "False")" crs:Exposure2012="+0.35"/>
    </rdf:RDF></x:xmpmeta>
    """
}

/// A 2×2 JPEG, optionally carrying `crs:HasSettings="True"` in its XMP.
private func writeJPEG(to url: URL, hasSettings: Bool) throws {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let metadata = CGImageMetadataCreateMutable()
    if hasSettings {
        #expect(CGImageMetadataRegisterNamespaceForPrefix(metadata, CameraRawSettings.namespace as CFString, "crs" as CFString, nil))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "crs:HasSettings" as CFString, "True" as CFString))
    }
    CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func cameraRawSidecarMarksRawFiles() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("IMG_0001.CR3")
    let untouched = folder.appendingPathComponent("IMG_0002.NEF")
    let longName = folder.appendingPathComponent("IMG_0003.ARW")
    for url in [raw, untouched, longName] { try Data([0]).write(to: url) }
    try sidecar(hasSettings: true).write(to: folder.appendingPathComponent("IMG_0001.xmp"), atomically: true, encoding: .utf8)
    try sidecar(hasSettings: true).write(to: folder.appendingPathComponent("IMG_0003.ARW.xmp"), atomically: true, encoding: .utf8)

    #expect(CameraRawSettings.hasSettings(for: raw))
    #expect(!CameraRawSettings.hasSettings(for: untouched))
    #expect(CameraRawSettings.hasSettings(for: longName))
}

@Test func cameraRawSidecarChangesAreNoticed() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("DSC_1.NEF")
    try Data([0]).write(to: raw)
    let xmp = folder.appendingPathComponent("DSC_1.xmp")

    // Bridge writes a sidecar for a rating alone; that is not an edit.
    try sidecar(hasSettings: false).write(to: xmp, atomically: true, encoding: .utf8)
    #expect(!CameraRawSettings.hasSettings(for: raw))
    try sidecar(hasSettings: true).write(to: xmp, atomically: true, encoding: .utf8)
    #expect(CameraRawSettings.hasSettings(for: raw))
    try FileManager.default.removeItem(at: xmp)
    #expect(!CameraRawSettings.hasSettings(for: raw))
}

@Test func cameraRawSettingsEmbeddedInJPEG() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let edited = folder.appendingPathComponent("edited.jpg")
    let plain = folder.appendingPathComponent("plain.jpg")
    try writeJPEG(to: edited, hasSettings: true)
    try writeJPEG(to: plain, hasSettings: false)
    // A sidecar beside a JPEG belongs to a RAW of the same name, not to it.
    try sidecar(hasSettings: true).write(to: folder.appendingPathComponent("plain.xmp"), atomically: true, encoding: .utf8)

    #expect(CameraRawSettings.hasSettings(for: edited))
    #expect(!CameraRawSettings.hasSettings(for: plain))
    #expect(PreviewMetadata.read(url: edited).hasCameraRawSettings)
}

@Test func cameraRawSettingsElementForm() {
    #expect(CameraRawSettings.xmpHasSettings("<crs:HasSettings>True</crs:HasSettings>"))
    #expect(!CameraRawSettings.xmpHasSettings("<crs:HasSettings>False</crs:HasSettings>"))
    #expect(!CameraRawSettings.xmpHasSettings("xmp:Rating=\"3\""))
}

@MainActor
@Test func metadataLoaderReportsCameraRawSettings() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("A.dng")
    try writeJPEG(to: raw, hasSettings: false)
    try sidecar(hasSettings: true).write(to: folder.appendingPathComponent("A.xmp"), atomically: true, encoding: .utf8)
    let index = folder.appendingPathComponent("index.sqlite")
    let loader = AssetMetadataLoader(indexDatabaseURL: index, dimensionProbe: { _ in CGSize(width: 2, height: 2) })
    var received: [AssetMetadataUpdate] = []
    var finished = false
    loader.onBatch = { updates, _, _ in received += updates }
    loader.onFinish = { _, _ in finished = true }
    loader.start(.init(
        targets: [AssetMetadataTarget(id: "file:\(raw.path)", url: raw, shouldLoadDimensions: false, shouldLoadTags: false,
                                     shouldCheckCameraRaw: true)],
        sourceID: "test", folderURL: folder, refreshID: 1, startDelayMilliseconds: 0
    ))
    #expect(await waitWhile { !finished })
    #expect(received.first?.hasCameraRawSettings == true)
}

// Every image is checked, beyond the tag limit external volumes use.
@Test func metadataTargetsCheckEveryImageForCameraRaw() {
    let assets = (0..<30).map { index in
        LightboxAsset(originalName: "\(index).jpg", width: 10, height: 10, tags: [],
                      sourceURL: URL(fileURLWithPath: "/tmp/\(index).jpg"), addedAt: .distantPast,
                      palette: MockPalette.imported[0], metadataLoaded: true)
    }
    let targets = AssetMetadataLoader.targets(for: assets, metadataLimit: 30, tagLimit: 12, loadsFinderTags: true)
    #expect(targets.count == 30)
    #expect(targets.allSatisfy { $0.shouldCheckCameraRaw })
    #expect(targets.filter { $0.shouldLoadTags }.count == 12)
}

@Test func cameraRawSidecarNamesFromTheListingSkipLookups() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("IMG_7.NEF")
    try Data([0]).write(to: raw)
    try sidecar(hasSettings: true).write(to: folder.appendingPathComponent("IMG_7.XMP"), atomically: true, encoding: .utf8)
    // The listing's names are lowercased; an upper-case sidecar still counts.
    #expect(CameraRawSettings.hasSettings(for: raw, sidecarNames: ["img_7.xmp"]))
    #expect(!CameraRawSettings.hasSettings(for: raw, sidecarNames: []))
}
