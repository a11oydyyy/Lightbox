import AppKit

enum ImageClipboardWriter {
    static func copyImage(at url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    static func copyImages(at urls: [URL]) {
        // The menu action validates URLs off the main actor. Writing file
        // references must not repeat synchronous disk checks on the UI thread.
        guard !urls.isEmpty else { return }

        if urls.count == 1,
           let url = urls.first {
            copyImage(at: url)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
