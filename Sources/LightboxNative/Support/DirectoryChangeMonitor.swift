import Foundation
import Darwin
import OSLog

final class DirectoryChangeMonitor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "DirectoryMonitor")
    private let url: URL
    private let queue = DispatchQueue(label: "Lightbox.DirectoryChangeMonitor", qos: .utility)
    private var source: DispatchSourceFileSystemObject?

    init(url: URL) {
        self.url = url
    }

    deinit {
        stop()
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()

        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.logger.error("monitor start failed path=\(self.url.path, privacy: .public) errno=\(errno)")
            return
        }

        let eventMask: DispatchSource.FileSystemEvent = [
            .write,
            .delete,
            .rename,
            .revoke
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: queue
        )

        source.setEventHandler {
            let event = source.data
            Self.logger.info("monitor event path=\(self.url.path, privacy: .public) raw=\(event.rawValue)")
            Task { @MainActor in
                onChange()
            }
        }

        source.setCancelHandler {
            close(descriptor)
        }

        self.source = source
        source.resume()
        Self.logger.info("monitor started path=\(self.url.path, privacy: .public)")
    }

    func stop() {
        if source != nil {
            Self.logger.info("monitor stopped path=\(self.url.path, privacy: .public)")
        }
        source?.cancel()
        source = nil
    }
}
