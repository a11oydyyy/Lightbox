import AppKit
import CoreServices
import Darwin
import Foundation
import OSLog

private let exportLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Export")

/// How `PhotoshopJPEGExport` saves, as Bridge's Image Processor asks.
struct JPEGExportOptions: Codable, Equatable, Sendable {
    /// Photoshop's JPEG quality, 0…12.
    var quality = 10
    var convertsToSRGB = true
    /// Shrinks images whose long edge is longer; nil keeps the full size.
    var longEdge: Int? = nil
    /// Where the JPEGs go: a folder of this name beside each source, or one
    /// chosen folder for all.
    var subfolderName = "JPEG"
    var folderPath: String? = nil

    func destinationFolder(for source: URL) -> URL {
        if let folderPath { return URL(fileURLWithPath: folderPath, isDirectory: true) }
        return source.deletingLastPathComponent().appendingPathComponent(subfolderName, isDirectory: true)
    }
}

/// Bridge's Image Processor, run through Photoshop. Camera Raw's settings
/// are only ever rendered by Adobe: a JPEG or RAW with saved settings opens
/// through Camera Raw with them applied, as when Image Processor opens it.
/// Each file is then flattened, made 8-bit, optionally converted to sRGB
/// and shrunk, saved as a JPEG beside nothing it would overwrite, and closed.
/// The sources are never changed.
enum PhotoshopJPEGExport {
    static let bundleIdentifier = "com.adobe.Photoshop"

    /// The installed Photoshop, if any; looked up once a launch, as menus
    /// ask on every update.
    static let applicationURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)

    /// Photoshop's answer for one file: nil when saved, else why not.
    typealias Runner = @Sendable (_ source: URL, _ destination: URL, _ options: JPEGExportOptions) -> String?

    /// What Apple Events report when the person has not let Lightbox control
    /// Photoshop (System Settings › Privacy & Security › Automation).
    static let notPermittedMessage = "-1743"

    static func perform(
        _ request: FileTransferRequest,
        progress: @escaping @Sendable (FileTransferProgressUpdate) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        permission: () -> String? = askPermission,
        runner: Runner = runInPhotoshop
    ) -> FileTransferResult {
        let options = request.jpegExport ?? JPEGExportOptions()
        let sources = request.sourceURLs.map(\.standardizedFileURL)
        var successes: [FileTransferSuccess] = []
        var failures: [FileTransferFailure] = []
        var wasCancelled = false

        if let refusal = permission() {
            exportLogger.error("export refused: \(refusal, privacy: .public)")
            return FileTransferResult(requestID: request.id, operation: .exportJPEG, successes: [],
                                      failures: sources.map { FileTransferFailure(sourceURL: $0, message: refusal) },
                                      wasCancelled: false)
        }

        for (index, source) in sources.enumerated() {
            if shouldCancel() {
                wasCancelled = true
                break
            }
            progress(FileTransferProgressUpdate(completedCount: index, totalCount: sources.count,
                                                currentName: source.lastPathComponent))
            do {
                let folder = options.destinationFolder(for: source)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Photoshop 只寫入本次專用的暫存目錄，完成後才發布到最終檔名。
                let staging = folder.appendingPathComponent(".lightbox-export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: staging) }
                let rendered = staging.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".jpg")
                if let message = runner(source, rendered, options) {
                    exportLogger.error("export failed \(source.lastPathComponent, privacy: .public): \(message, privacy: .public)")
                    failures.append(FileTransferFailure(sourceURL: source, message: message))
                    // Without permission no other file can go either.
                    if message.contains(notPermittedMessage) {
                        failures += sources[(index + 1)...].map { FileTransferFailure(sourceURL: $0, message: message) }
                        break
                    }
                } else {
                    let destination = try commitExport(at: rendered, for: source, in: folder, shouldCancel: shouldCancel)
                    successes.append(FileTransferSuccess(sourceURL: source, destinationURL: destination))
                }
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                failures.append(FileTransferFailure(sourceURL: source, message: error.localizedDescription))
            }
        }
        progress(FileTransferProgressUpdate(completedCount: successes.count + failures.count, totalCount: sources.count,
                                            currentName: ""))
        return FileTransferResult(requestID: request.id, operation: .exportJPEG, successes: successes,
                                  failures: failures, wasCancelled: wasCancelled)
    }

    /// `name.jpg` in `folder`, or `name 2.jpg` and so on when taken: an
    /// export never replaces a file, and never lands on its own JPEG source.
    static func availableDestination(for source: URL, in folder: URL) throws -> URL {
        let name = source.deletingPathExtension().lastPathComponent + ".jpg"
        return try FileTransferService.availableDestinationURL(
            for: folder.appendingPathComponent(name), in: folder, operation: .exportJPEG
        )
    }

    private static func commitExport(at rendered: URL, for source: URL, in folder: URL,
                                     shouldCancel: @Sendable () -> Bool) throws -> URL {
        while true {
            guard !shouldCancel() else { throw CancellationError() }
            let destination = try availableDestination(for: source, in: folder)
            let result = rendered.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else {
                        errno = EINVAL
                        return Int32(-1)
                    }
                    return renamex_np(from, to, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return destination }
            let error = errno
            // 名稱檢查後仍可能被其他程式佔用；重新取名，絕不退回覆蓋寫入。
            if error == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
    }

    // MARK: Photoshop

    /// Asks, before the first file, to control Photoshop, and waits for the
    /// answer: otherwise macOS refuses the first file while its prompt shows.
    /// Photoshop has to be running to be asked about, so it is opened first
    /// (it would be by the first file anyway). Nil when allowed or when the
    /// answer is unclear (each file then tries); the refusal otherwise.
    static func askPermission() -> String? {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
           let applicationURL {
            let launched = DispatchSemaphore(value: 0)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in
                launched.signal()
            }
            _ = launched.wait(timeout: .now() + 120)
        }
        var target = AEAddressDesc()
        let identifier = Array(bundleIdentifier.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), identifier, identifier.count, &target) == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
        return status == OSStatus(errAEEventNotPermitted) ? "Not permitted to control Photoshop (\(notPermittedMessage))" : nil
    }

    /// Runs `script` in Photoshop through `osascript`, off the main thread;
    /// the arguments travel as a list, so paths need no quoting.
    @Sendable static func runInPhotoshop(_ source: URL, _ destination: URL, _ options: JPEGExportOptions) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript, script] + arguments(source: source, destination: destination, options: options)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        if process.terminationStatus != 0 { return problem.isEmpty ? "osascript \(process.terminationStatus)" : problem }
        return answer == "ok" ? nil : (answer.isEmpty ? "Photoshop gave no answer" : answer)
    }

    static func arguments(source: URL, destination: URL, options: JPEGExportOptions) -> [String] {
        [source.path, destination.path, String(min(12, max(0, options.quality))),
         options.convertsToSRGB ? "1" : "0", String(options.longEdge ?? 0)]
    }

    /// Opens Photoshop if needed, and waits up to ten minutes for a file:
    /// the first one includes Photoshop starting.
    static let appleScript = """
    on run argv
        with timeout of 600 seconds
            tell application id "\(bundleIdentifier)"
                return do javascript (item 1 of argv) with arguments (items 2 thru -1 of argv)
            end tell
        end timeout
    end run
    """

    /// One file, in Photoshop's ExtendScript: arguments are source, destination,
    /// quality, sRGB ("1"/"0") and long edge (0 = keep). Answers "ok" or why not,
    /// and leaves Photoshop's dialog and unit settings as they were.
    static let script = """
    (function (args) {
        var dialogs = app.displayDialogs;
        var units = app.preferences.rulerUnits;
        var previous = app.documents.length ? app.activeDocument : null;
        var existing = [];
        for (var i = 0; i < app.documents.length; i++) { existing.push(app.documents[i].id); }
        var doc = null;
        try {
            app.displayDialogs = DialogModes.NO;
            app.preferences.rulerUnits = Units.PIXELS;
            var opened = app.open(new File(args[0]));
            var wasOpen = false;
            for (var i = 0; i < existing.length; i++) {
                if (opened.id == existing[i]) { wasOpen = true; break; }
            }
            doc = wasOpen ? opened.duplicate() : opened;
            doc.flatten();
            if (doc.mode != DocumentMode.RGB && doc.mode != DocumentMode.GRAYSCALE && doc.mode != DocumentMode.CMYK) {
                doc.changeMode(ChangeMode.RGB);
            }
            if (doc.bitsPerChannel != BitsPerChannelType.EIGHT) { doc.bitsPerChannel = BitsPerChannelType.EIGHT; }
            if (args[3] == "1") {
                doc.convertProfile("sRGB IEC61966-2.1", Intent.RELATIVECOLORIMETRIC, true, false);
            }
            var edge = Number(args[4]);
            var w = doc.width.as("px"), h = doc.height.as("px");
            if (edge > 0 && Math.max(w, h) > edge) {
                var scale = edge / Math.max(w, h);
                doc.resizeImage(UnitValue(Math.round(w * scale), "px"), UnitValue(Math.round(h * scale), "px"),
                                doc.resolution, ResampleMethod.BICUBICSHARPER);
            }
            var save = new JPEGSaveOptions();
            save.quality = Number(args[2]);
            save.embedColorProfile = true;
            save.formatOptions = FormatOptions.STANDARDBASELINE;
            save.matte = MatteType.NONE;
            doc.saveAs(new File(args[1]), save, true, Extension.LOWERCASE);
            return "ok";
        } catch (e) {
            return "" + e;
        } finally {
            if (doc) { try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (ignored) {} }
            if (previous) { try { app.activeDocument = previous; } catch (ignored) {} }
            app.displayDialogs = dialogs;
            app.preferences.rulerUnits = units;
        }
    })(arguments);
    """
}
