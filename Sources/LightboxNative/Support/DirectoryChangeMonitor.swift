import Foundation
import CoreServices
import Darwin
import OSLog

final class DirectoryChangeMonitor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "DirectoryMonitor")
    private let url: URL
    private let recursive: Bool
    private let openDirectory: @Sendable (URL) -> Int32
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Lightbox.DirectoryChangeMonitor", qos: .utility)
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, recursive: Bool = false, openDirectory: @escaping @Sendable (URL) -> Int32 = { open($0.path, O_EVTONLY) }) {
        self.url = url
        self.recursive = recursive
        self.openDirectory = openDirectory
    }

    deinit {
        stop()
    }

    func start(
        onInvalidated: @escaping @MainActor @Sendable () -> Void = {},
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        let generation = stopCurrent()
        let invalidate: @Sendable (Bool) -> Void = { [weak self] refresh in
            Task { @MainActor in
                guard let self, self.isCurrent(generation) else { return }
                self.stop()
                onInvalidated()
                if refresh { onChange() }
            }
        }
        if recursive {
            startRecursive(generation: generation, invalidate: invalidate, onChange: onChange)
            return
        }

        let url = url
        let openDirectory = openDirectory
        let queue = queue
        let startedAt = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard self?.isCurrent(generation) == true else { return }
            // Opening a disconnected network directory can block in the kernel.
            // Do not retain the monitor or hold its lock during that operation.
            let descriptor = openDirectory(url)
            guard descriptor >= 0 else {
                Self.logger.error("monitor start failed path=\(url.path, privacy: .public) errno=\(errno)")
                invalidate(false)
                return
            }
            guard let self else { close(descriptor); return }
            let notify: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    guard self?.isCurrent(generation) == true else { return }
                    onChange()
                }
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events: DispatchSource.FileSystemEvent = self.lock.withLock {
                    guard self.generation == generation else { return [] }
                    return self.source?.data ?? []
                }
                guard !events.isEmpty else { return }
                Self.logger.info("monitor event path=\(url.path, privacy: .public)")
                if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                    invalidate(true)
                } else {
                    notify()
                }
            }
            source.setCancelHandler { close(descriptor) }
            let accepted = self.lock.withLock {
                guard self.generation == generation else { return false }
                self.source = source
                return true
            }
            source.resume()
            guard accepted else { source.cancel(); return }
            Self.logger.info("monitor started path=\(url.path, privacy: .public)")
            // Reconcile directory entries changed before attachment, without
            // turning every successful monitor start into an unsolicited reload.
            var info = stat()
            if fstat(descriptor, &info) == 0 {
                let modifiedAt = TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                if modifiedAt >= startedAt { notify() }
            }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { self.generation == generation }
    }

    private final class CallbackBox: @unchecked Sendable {
        let action: @MainActor @Sendable () -> Void
        let invalidated: @MainActor @Sendable () -> Void
        init(_ action: @escaping @MainActor @Sendable () -> Void,
             invalidated: @escaping @MainActor @Sendable () -> Void) {
            self.action = action
            self.invalidated = invalidated
        }
    }

    private func startRecursive(generation: UInt64, invalidate: @escaping @Sendable (Bool) -> Void,
                                onChange: @escaping @MainActor @Sendable () -> Void) {
        let box = CallbackBox({ [weak self] in
            guard self?.isCurrent(generation) == true else { return }
            onChange()
        }, invalidated: { invalidate(true) })
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
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let rootChanged = (0..<count).contains {
                flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
            }
            let action = rootChanged ? box.invalidated : box.action
            Task { @MainActor in action() }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            invalidate(false)
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            invalidate(false)
            return
        }
        self.stream = stream
    }

    func stop() {
        _ = stopCurrent()
    }

    private func stopCurrent() -> UInt64 {
        let (generation, source) = lock.withLock {
            self.generation &+= 1
            let previous = self.source
            self.source = nil
            return (self.generation, previous)
        }
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
        return generation
    }
}
