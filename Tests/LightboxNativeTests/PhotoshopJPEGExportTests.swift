import Foundation
import ImageIO
import JavaScriptCore
import Testing
@testable import LightboxNative

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JPEGExport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Stands in for Photoshop: writes the destination, records the call.
private final class FakePhotoshop: @unchecked Sendable {
    var calls: [(source: String, destination: String)] = []
    var answer: (URL) -> String? = { _ in nil }

    var runner: PhotoshopJPEGExport.Runner {
        { [self] source, destination, _ in
            calls.append((source.lastPathComponent, destination.path))
            if let problem = answer(source) { return problem }
            FileManager.default.createFile(atPath: destination.path, contents: Data([0xFF]))
            return nil
        }
    }
}

// JPEGs go to a "JPEG" folder beside each image, as name.jpg, never over a file.
@Test func jpegExportWritesBesideEachImageWithoutReplacing() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = folder.appendingPathComponent("DSCF1.JPG"), b = folder.appendingPathComponent("IMG_2.RAF")
    for url in [a, b] { FileManager.default.createFile(atPath: url.path, contents: Data([0])) }
    let jpegFolder = folder.appendingPathComponent("JPEG")
    try FileManager.default.createDirectory(at: jpegFolder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: jpegFolder.appendingPathComponent("DSCF1.jpg").path, contents: Data([1]))

    let photoshop = FakePhotoshop()
    let request = FileTransferRequest(sourceURLs: [a, b], destinationFolderURL: jpegFolder,
                                      operation: .exportJPEG, jpegExport: JPEGExportOptions())
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in }, shouldCancel: { false }, permission: { nil }, runner: photoshop.runner)

    #expect(result.failures.isEmpty && !result.wasCancelled)
    #expect(result.successes.map(\.destinationURL.lastPathComponent) == ["DSCF1 2.jpg", "IMG_2.jpg"])
    #expect(try Data(contentsOf: jpegFolder.appendingPathComponent("DSCF1.jpg")) == Data([1]))
}

// Exported into the images' own folder, a JPEG never lands on its source.
@Test func jpegExportIntoTheSourceFolderKeepsTheSource() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("DSCF1.JPG")
    FileManager.default.createFile(atPath: source.path, contents: Data([0]))
    var options = JPEGExportOptions()
    options.folderPath = folder.path
    let request = FileTransferRequest(sourceURLs: [source], destinationFolderURL: folder,
                                      operation: .exportJPEG, jpegExport: options)
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in }, shouldCancel: { false }, permission: { nil }, runner: FakePhotoshop().runner)
    #expect(result.successes.first?.destinationURL.lastPathComponent == "DSCF1 2.jpg")
    #expect(try Data(contentsOf: source) == Data([0]))
}

// Without permission to control Photoshop, the rest is not tried.
@Test func jpegExportStopsWhenPhotoshopIsNotPermitted() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = (1...3).map { folder.appendingPathComponent("\($0).jpg") }
    for url in sources { FileManager.default.createFile(atPath: url.path, contents: Data([0])) }
    let photoshop = FakePhotoshop()
    photoshop.answer = { _ in "execution error: Not authorized to send Apple events to Adobe Photoshop. (-1743)" }
    let request = FileTransferRequest(sourceURLs: sources, destinationFolderURL: folder, operation: .exportJPEG)
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in }, shouldCancel: { false }, permission: { nil }, runner: photoshop.runner)
    #expect(photoshop.calls.count == 1)
    #expect(result.failures.count == 3 && result.successes.isEmpty)
}

// Refused before the first file, nothing is tried.
@Test func jpegExportRefusedUpFrontTriesNothing() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = (1...2).map { folder.appendingPathComponent("\($0).jpg") }
    let photoshop = FakePhotoshop()
    let request = FileTransferRequest(sourceURLs: sources, destinationFolderURL: folder, operation: .exportJPEG)
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in }, shouldCancel: { false },
                                             permission: { "Not permitted to control Photoshop (-1743)" },
                                             runner: photoshop.runner)
    #expect(photoshop.calls.isEmpty)
    #expect(result.failures.count == 2)
    #expect(result.failures.allSatisfy { $0.message.contains(PhotoshopJPEGExport.notPermittedMessage) })
}

// One failure does not stop the others.
@Test func jpegExportReportsEachFailure() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
    for url in sources { FileManager.default.createFile(atPath: url.path, contents: Data([0])) }
    let photoshop = FakePhotoshop()
    photoshop.answer = { $0.lastPathComponent == "b.jpg" ? "Error 8800: General Photoshop error" : nil }
    let request = FileTransferRequest(sourceURLs: sources, destinationFolderURL: folder, operation: .exportJPEG)
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in }, shouldCancel: { false }, permission: { nil }, runner: photoshop.runner)
    #expect(result.successes.count == 2)
    #expect(result.failures.map(\.sourceURL.lastPathComponent) == ["b.jpg"])
}

@Test func jpegExportArgumentsClampQualityAndCarryTheOptions() {
    var options = JPEGExportOptions()
    options.quality = 20
    options.convertsToSRGB = false
    options.longEdge = 2048
    let arguments = PhotoshopJPEGExport.arguments(source: URL(fileURLWithPath: "/a/b.jpg"),
                                                  destination: URL(fileURLWithPath: "/a/JPEG/b.jpg"), options: options)
    #expect(arguments == ["/a/b.jpg", "/a/JPEG/b.jpg", "12", "0", "2048"])
}

@Test(arguments: ["collision", "failure", "missing", "cancel"])
func jpegExportPublishesOnlyCompletedFiles(scenario: String) throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("photo.raw")
    let output = folder.appendingPathComponent("JPEG")
    let cancelled = folder.appendingPathComponent("cancelled")
    let request = FileTransferRequest(sourceURLs: [source], destinationFolderURL: output, operation: .exportJPEG)
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in },
        shouldCancel: { FileManager.default.fileExists(atPath: cancelled.path) }, permission: { nil },
        runner: { _, destination, _ in
            do {
                if scenario == "missing" { return nil }
                try Data([7]).write(to: destination)
                if scenario == "failure" { return "save failed" }
                if scenario == "cancel" { try Data().write(to: cancelled) }
                if scenario == "collision" {
                    // 模擬 Photoshop 運行期間，另一個程式建立了同名檔。
                    try Data([9]).write(to: output.appendingPathComponent("photo.jpg"))
                }
                return nil
            } catch { return error.localizedDescription }
        })
    let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
    if scenario == "collision" {
        #expect(result.successes.map(\.destinationURL.lastPathComponent) == ["photo 2.jpg"])
        #expect(result.failures.isEmpty)
        #expect(try Data(contentsOf: output.appendingPathComponent("photo.jpg")) == Data([9]))
        #expect(try Data(contentsOf: output.appendingPathComponent("photo 2.jpg")) == Data([7]))
        #expect(names == ["photo 2.jpg", "photo.jpg"])
    } else {
        #expect(result.successes.isEmpty)
        #expect(names.isEmpty)
        #expect(result.wasCancelled == (scenario == "cancel"))
        #expect(result.failures.count == (scenario == "cancel" ? 0 : 1))
    }
}

// 執行實際轉存腳本，以文件模型驗證所有清理路徑不會碰到使用者已開啟的文件。
@Test(arguments: ["existing", "new", "duplicateFailure", "saveFailure"])
func jpegExportScriptProtectsOpenDocuments(scenario: String) throws {
    let context = try #require(JSContext())
    context.setObject(scenario, forKeyedSubscript: "scenario" as NSString)
    context.evaluateScript("""
    var DialogModes = { NO: 0 }, Units = { PIXELS: 1 };
    var DocumentMode = { RGB: 1, GRAYSCALE: 2, CMYK: 3 }, ChangeMode = { RGB: 1 };
    var BitsPerChannelType = { EIGHT: 8 }, Intent = { RELATIVECOLORIMETRIC: 1 };
    var FormatOptions = { STANDARDBASELINE: 1 }, MatteType = { NONE: 0 };
    var Extension = { LOWERCASE: 1 }, SaveOptions = { DONOTSAVECHANGES: 1 };
    function File(path) { this.path = path; }
    function JPEGSaveOptions() {}
    function MockDocument(id) {
        this.id = id; this.closed = false; this.changed = false; this.saved = false;
        this.mode = DocumentMode.RGB; this.bitsPerChannel = 8;
        this.width = this.height = { as: function() { return 100; } };
    }
    MockDocument.prototype.duplicate = function() {
        if (scenario == "duplicateFailure") { throw new Error("duplicate failed"); }
        duplicate = new MockDocument(3);
        app.documents.push(duplicate); app.activeDocument = duplicate;
        return duplicate;
    };
    MockDocument.prototype.flatten = function() { this.changed = true; };
    MockDocument.prototype.convertProfile = function() { this.changed = true; };
    MockDocument.prototype.saveAs = function() {
        if (scenario == "saveFailure") { throw new Error("save failed"); }
        this.saved = true;
    };
    MockDocument.prototype.close = function() { this.closed = true; };
    var previous = new MockDocument(1), original = new MockDocument(2), duplicate = null;
    var app = {
        displayDialogs: 7, preferences: { rulerUnits: 9 },
        documents: scenario == "new" ? [previous] : [previous, original],
        activeDocument: previous,
        open: function() {
            if (scenario == "new") { this.documents.push(original); }
            this.activeDocument = original;
            return original;
        }
    };
    var arguments = ["source.raw", "output.jpg", "10", "1", "0"];
    """)
    #expect(context.exception == nil)
    let result = context.evaluateScript(PhotoshopJPEGExport.script)?.toString()
    #expect(context.exception == nil)
    #expect(context.evaluateScript("app.activeDocument === previous && !previous.closed && !previous.changed")?.toBool() == true)
    #expect(context.evaluateScript("app.displayDialogs === 7 && app.preferences.rulerUnits === 9")?.toBool() == true)
    if scenario == "new" {
        #expect(result == "ok")
        #expect(context.evaluateScript("original.saved && original.closed && duplicate === null")?.toBool() == true)
    } else {
        #expect(context.evaluateScript("!original.changed && !original.saved && !original.closed")?.toBool() == true)
        if scenario == "duplicateFailure" {
            #expect(result?.contains("duplicate failed") == true)
            #expect(context.evaluateScript("duplicate === null")?.toBool() == true)
        } else {
            #expect(context.evaluateScript("duplicate.changed && duplicate.closed")?.toBool() == true)
            #expect(result == (scenario == "saveFailure" ? "Error: save failed" : "ok"))
        }
    }
}

@Test func jpegExportOptionsAreRemembered() throws {
    let defaults = try #require(UserDefaults(suiteName: "JPEGExport-\(UUID())"))
    #expect(JPEGExportOptions.load(defaults: defaults) == JPEGExportOptions())
    var options = JPEGExportOptions()
    options.quality = 8
    options.longEdge = 3000
    options.folderPath = "/tmp/out"
    options.save(defaults: defaults)
    #expect(JPEGExportOptions.load(defaults: defaults) == options)
}

/// Mean brightness, 0…1, of an image file.
private func meanBrightness(_ url: URL) throws -> Double {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let side = 64
    var pixels = [UInt8](repeating: 0, count: side * side)
    let context = try #require(CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) / 255
}

// Real Photoshop, on request only (LIGHTBOX_PHOTOSHOP_TEST=<a JPEG with
// Camera Raw settings that brighten it>): the export carries the edit.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTBOX_PHOTOSHOP_TEST"] != nil))
func jpegExportThroughPhotoshopAppliesCameraRawSettings() throws {
    let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIGHTBOX_PHOTOSHOP_TEST"]))
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent(original.lastPathComponent)
    try FileManager.default.copyItem(at: original, to: source)
    var options = JPEGExportOptions()
    options.longEdge = 1200
    let request = FileTransferRequest(sourceURLs: [source], destinationFolderURL: folder, operation: .exportJPEG, jpegExport: options)
    let result = PhotoshopJPEGExport.perform(request, progress: { _ in }, shouldCancel: { false })
    #expect(result.failures.isEmpty, "\(result.failures.map(\.message))")
    let output = try #require(result.successes.first?.destinationURL)
    #expect(output.path == folder.appendingPathComponent("JPEG/\(source.deletingPathExtension().lastPathComponent).jpg").path)
    let size = try #require(CGImageSourceCreateWithURL(output as CFURL, nil)
        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
    #expect(max(size[kCGImagePropertyPixelWidth] as? Int ?? 0, size[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 1200)
    #expect(try meanBrightness(output) > meanBrightness(source) + 0.02)
}
