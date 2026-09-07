import Foundation
import CoreServices
import Darwin
import OSLog

final class DirectoryChangeMonitor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "DirectoryMonitor")
    private let url: URL
    private let recursive: Bool
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Lightbox.DirectoryChangeMonitor", qos: .utility)
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, recursive: Bool = false) {
        self.url = url
        self.recursive = recursive
    }

    deinit {
        stop()
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        if recursive {
            startRecursive(onChange: onChange)
            return
        }

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

    private final class CallbackBox: @unchecked Sendable {
        let action: @MainActor @Sendable () -> Void
        init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
    }

    private func startRecursive(onChange: @escaping @MainActor @Sendable () -> Void) {
        let box = CallbackBox(onChange)
        defer { withExtendedLifetime(box) {} }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<CallbackBox>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let changedPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            let needsRefresh = (0..<count).contains { index in
                let flag = flags[index]
                let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
                if flag & rescanFlags != 0 { return true }
                let directoryChanges = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                    return flag & directoryChanges != 0
                }
                return LocalImageSource.isSupportedImageURL(URL(fileURLWithPath: changedPaths[index]))
            }
            guard needsRefresh else { return }
            let action = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().action
            Task { @MainActor in action() }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if source != nil {
            Self.logger.info("monitor stopped path=\(self.url.path, privacy: .public)")
        }
        source?.cancel()
        source = nil
    }
}
