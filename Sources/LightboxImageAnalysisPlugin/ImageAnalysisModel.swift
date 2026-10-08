import AppKit
import Darwin
import SwiftUI

struct ImageAnalysisRecord: Codable, Identifiable, Equatable, Sendable {
    var path: String
    var modifiedAt: Date?
    var fileSize: Int?
    var result: ImageAnalysisResult
    var analyzedAt: Date
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    func matches(_ query: String) -> Bool {
        query.isEmpty || ([name, result.summary, result.text] + result.tags)
            .contains { $0.localizedStandardContains(query) }
    }
}

actor ImageAnalysisIndex {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox")
            .appendingPathComponent("ImageAnalysis/results.json")
    }

    func load() throws -> [ImageAnalysisRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ImageAnalysisRecord].self, from: Data(contentsOf: url))
    }

    func save(_ record: ImageAnalysisRecord) throws -> [ImageAnalysisRecord] {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Plugin windows run in separate processes; serialize the read/merge/write
        // so two windows cannot discard each other's completed results.
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        var records = try load()
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        return records
    }
}

@MainActor
final class ImageAnalysisModel: ObservableObject {
    @Published private(set) var targets: [URL] = []
    @Published private(set) var records: [ImageAnalysisRecord] = []
    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    @Published var error: String?
    @Published var query = ""
    private let index: ImageAnalysisIndex
    private let analyze: @Sendable (URL, ImageAnalysisMode) async throws -> ImageAnalysisResult
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(index: ImageAnalysisIndex = ImageAnalysisIndex(),
         analyze: @escaping @Sendable (URL, ImageAnalysisMode) async throws -> ImageAnalysisResult = {
             try await ImageAnalysisService.analyze(url: $0, mode: $1)
         }) {
        self.index = index
        self.analyze = analyze
    }

    var visibleRecords: [ImageAnalysisRecord] {
        records.filter { $0.matches(query) }.sorted { $0.analyzedAt > $1.analyzedAt }
    }

    func select(_ urls: [URL]) {
        cancel()
        var seen = Set<URL>()
        targets = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        query = ""
        error = nil
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await index.load()
                guard generation == token, !Task.isCancelled else { return }
                records = loaded
            } catch { if generation == token { self.error = "读取分析记录失败：\(error.localizedDescription)" } }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = UUID()
        isRunning = false
        progress = ""
    }

    func run(_ mode: ImageAnalysisMode) {
        guard !isRunning, !targets.isEmpty else { return }
        task?.cancel()
        let token = UUID()
        generation = token
        let selected = targets
        isRunning = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token { isRunning = false; progress = ""; task = nil }
            }
            do {
                let loaded = try await index.load()
                guard generation == token, !Task.isCancelled else { return }
                records = loaded
                for (offset, url) in selected.enumerated() {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    progress = "\(offset + 1)/\(selected.count) · \(url.lastPathComponent)"
                    do {
                        let values = try await Task.detached {
                            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                            return (modifiedAt: values.contentModificationDate, fileSize: values.fileSize)
                        }.value
                        let result = try await analyze(url, mode)
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        let after = try await Task.detached {
                            let fresh = URL(fileURLWithPath: url.path)
                            let value = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                            return (modifiedAt: value.contentModificationDate, fileSize: value.fileSize)
                        }.value
                        try Task.checkCancellation()
                        guard values == after else {
                            self.error = "\(url.lastPathComponent)：分析时文件发生变化，请重新分析。"
                            continue
                        }
                        var merged = records.first { $0.path == url.path && $0.modifiedAt == values.modifiedAt && $0.fileSize == values.fileSize }?.result ?? ImageAnalysisResult()
                        if mode == .text { merged.text = result.text }
                        else { merged.summary = result.summary; merged.tags = result.tags }
                        let updated = try await index.save(ImageAnalysisRecord(path: url.path, modifiedAt: values.modifiedAt,
                            fileSize: values.fileSize, result: merged, analyzedAt: .now))
                        guard generation == token, !Task.isCancelled else { return }
                        records = updated
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard generation == token, !Task.isCancelled else { return }
                        self.error = "\(url.lastPathComponent)：\(error.localizedDescription)"
                    }
                }
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
final class ImageAnalysisWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: ImageAnalysisModel

    init(indexURL: URL) { model = ImageAnalysisModel(index: ImageAnalysisIndex(url: indexURL)) }

    func open(urls: [URL]) {
        model.select(urls)
        if let window { window.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "图片分析"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 400)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ImageAnalysisPanel(model: model))
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model.cancel(); window = nil }
}
