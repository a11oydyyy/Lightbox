import Foundation
import ImageIO
import Testing
@testable import LightboxNative

@Test func previewMetadataParsesCaptureAndPreservesCameraTime() {
    let details = PreviewMetadata.parse([
        kCGImagePropertyTIFFDictionary as String: ["Make": "RICOH", "Model": "RICOH GR IIIx", "Software": "Camera firmware"],
        kCGImagePropertyExifDictionary as String: [
            "FNumber": 2.8, "ExposureTime": 0.002, "ISOSpeedRatings": [200],
            "FocalLength": 26.1, "FocalLenIn35mmFilm": 40,
            "ExposureBiasValue": -1.0, "DateTimeOriginal": "2026:09:06 12:30:00", "OffsetTimeOriginal": "+08:00"
        ]
    ])
    #expect(details.capture.first(where: { $0.label == "Camera" })?.value == "RICOH GR IIIx")
    #expect(details.capture.first(where: { $0.label == "Shutter" })?.value == "1/500 s")
    #expect(details.capture.first(where: { $0.label == "Captured" })?.value == "2026:09:06 12:30:00 +08:00")
    #expect(details.exposureSummary.contains("ISO 200"))
}

@Test func previewMetadataOmitsMissingAndInvalidFields() {
    let details = PreviewMetadata.parse([
        kCGImagePropertyExifDictionary as String: ["FNumber": 0, "ExposureTime": -1, "ISOSpeedRatings": [0], "FocalLength": Double.nan],
        kCGImagePropertyTIFFDictionary as String: ["Model": "  "]
    ])
    #expect(details.capture.isEmpty)
    #expect(details.exposureSummary.isEmpty)
    #expect(PreviewMetadata.shutter(.infinity) == nil)
    #expect(PreviewMetadata.shutter(2) == "2 s")
}

@Test func previewMetadataReadsPNGWithoutExif() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aO1sAAAAASUVORK5CYII="))
    try data.write(to: url)
    let details = PreviewMetadata.read(url: url)
    #expect(details.imagePropertiesAvailable)
    #expect(details.capture.isEmpty)
    #expect(details.file.contains { $0.label == "Path" && $0.value == url.path })
    #expect(details.file.contains { $0.label == "File size" })
    #expect(details.image.contains { $0.label == "Format" })
}

@Test func previewMetadataHandlesUnavailableSource() {
    let details = PreviewMetadata.read(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg"))
    #expect(!details.imagePropertiesAvailable)
    #expect(details.capture.isEmpty)
    #expect(details.file.count == 1)
}

@Test func previewMetadataUsesShortBrandAndModel() {
    #expect(PreviewMetadata.shortCameraName(make: "RICOH IMAGING COMPANY, LTD.", model: "RICOH GR IIIx") == "RICOH GR IIIx")
    #expect(PreviewMetadata.shortCameraName(make: "FUJIFILM", model: "X-T5") == "FUJIFILM X-T5")
    #expect(PreviewMetadata.shortCameraName(make: "NIKON CORPORATION", model: "NIKON Z 6_2") == "Nikon Z 6_2")
    #expect(PreviewMetadata.shortCameraName(make: nil, model: nil) == nil)
}
