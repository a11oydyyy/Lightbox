import AppKit

enum ImageClipboardWriter {
    static func copyImage(at url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var objects: [NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url) {
            objects.insert(image, at: 0)
        }

        pasteboard.writeObjects(objects)
    }

    static func copyImages(at urls: [URL]) {
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else { return }

        if existingURLs.count == 1,
           let url = existingURLs.first {
            copyImage(at: url)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(existingURLs.map { $0 as NSURL })
    }
}
