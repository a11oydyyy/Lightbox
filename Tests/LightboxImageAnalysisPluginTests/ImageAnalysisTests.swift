import AppKit
import Testing
@testable import LightboxImageAnalysisPlugin

@Test func imageAnalysisIndexRoundTripsAndSearchesWithoutChangingImages() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxAnalysis-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("test.png")
    let bytes = Data([1, 2, 3])
    try bytes.write(to: source)
    let index = ImageAnalysisIndex(url: folder.appendingPathComponent("index.json"))
    var record = ImageAnalysisRecord(path: source.path, modifiedAt: nil, fileSize: 3,
        result: .init(summary: "蓝色天空", tags: ["风景"], text: "Lightbox 2026"), analyzedAt: .now)
    #expect(try await index.save(record).count == 1)
    #expect(record.matches("风景"))
    #expect(record.matches("lightbox"))
    #expect(!record.matches("unmatched"))
    record.result.text = "Updated"
    #expect(try await index.save(record).count == 1)
    #expect(try await index.load().first?.result.text == "Updated")
    #expect(try Data(contentsOf: source) == bytes)
    let corrupted = Data("broken JSON".utf8)
    try corrupted.write(to: folder.appendingPathComponent("index.json"))
    await #expect(throws: (any Error).self) { try await index.save(record) }
    #expect(try Data(contentsOf: folder.appendingPathComponent("index.json")) == corrupted)
}

@Test @MainActor func imageAnalysisCancellationDoesNotSaveLateResults() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxCancel-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("image.png")
    try Data([1]).write(to: image)
    let index = ImageAnalysisIndex(url: folder.appendingPathComponent("results.json"))
    let model = ImageAnalysisModel(index: index) { _, _ in
        // Deliberately ignore cancellation to simulate an uninterruptible decoder.
        try? await Task.sleep(for: .milliseconds(120))
        return ImageAnalysisResult(summary: "late")
    }
    model.select([image, image])
    #expect(model.targets.count == 1)
    model.run(.describe)
    try await Task.sleep(for: .milliseconds(30))
    model.cancel()
    model.select([])
    try await Task.sleep(for: .milliseconds(160))
    #expect(!model.isRunning)
    #expect(model.records.isEmpty)
    #expect(try await index.load().isEmpty)
    #expect(model.error == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_RUN_OCR_TEST"] == "1"))
@MainActor func imageAnalysisRecognizesRealTextImage() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxOCR-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = NSImage(size: NSSize(width: 1000, height: 400))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
    ("LIGHTBOX TEST 2026" as NSString).draw(at: NSPoint(x: 60, y: 160), withAttributes: [
        .font: NSFont.systemFont(ofSize: 66, weight: .bold), .foregroundColor: NSColor.black
    ])
    image.unlockFocus()
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = folder.appendingPathComponent("ocr.png")
    try png.write(to: url)
    if let output = ProcessInfo.processInfo.environment["LIGHTBOX_TEST_ARTIFACTS"] {
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("ocr.png"))
    }
    let result = try await ImageAnalysisService.analyze(url: url, mode: .text)
    #expect(result.text.contains("LIGHTBOX"))
    #expect(result.text.contains("2026"))
    #expect(try Data(contentsOf: url) == png)
    print("IMAGE_ANALYSIS_MODEL: \(ImageAnalysisService.modelUnavailableReason ?? "available")")
}

@Test @MainActor func imageAnalysisMergesModesAndInvalidatesChangedFiles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxAnalysisModes-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("image.png")
    try Data([1]).write(to: image)
    let index = ImageAnalysisIndex(url: folder.appendingPathComponent("results.json"))
    let model = ImageAnalysisModel(index: index) { _, mode in
        mode == .text ? ImageAnalysisResult(text: "Searchable OCR") : ImageAnalysisResult(summary: "Description", tags: ["Blue"])
    }
    func finish() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isRunning)
        #expect(model.error == nil)
    }
    model.select([image])
    model.run(.describe)
    try await finish()
    model.run(.text)
    try await finish()
    #expect(model.records.first?.result == ImageAnalysisResult(summary: "Description", tags: ["Blue"], text: "Searchable OCR"))
    model.query = "searchable"
    #expect(model.visibleRecords.count == 1)
    // Replacing the source must not leave the old description attached to new OCR.
    try Data([2, 3]).write(to: image)
    model.run(.text)
    try await finish()
    #expect(model.records.first?.result.summary.isEmpty == true)
    #expect(model.records.first?.fileSize == 2)
}

@Test func imageAnalysisSeparateWindowsPreserveConcurrentResults() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxConcurrentAnalysis-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("results.json")
    let first = ImageAnalysisIndex(url: url)
    let second = ImageAnalysisIndex(url: url)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for number in 0..<20 {
            group.addTask {
                let record = ImageAnalysisRecord(path: "/image-\(number).png", modifiedAt: nil, fileSize: 1,
                    result: .init(text: "\(number)"), analyzedAt: .now)
                _ = try await (number.isMultiple(of: 2) ? first : second).save(record)
            }
        }
        try await group.waitForAll()
    }
    #expect(try await first.load().count == 20)
}
