import Foundation

/// Watches the folder on screen for changes and reports them.
///
/// Keeps one directory monitor for the current folder (and its subfolders
/// when they are included) and restarts it only when the folder or depth
/// changes. A monitor the system invalidates (the folder went away) is
/// dropped, so the next `watch` starts a fresh one. `AppState` decides what
/// to watch and what a change means.
@MainActor
final class FolderWatcher {
    typealias MonitorFactory = @Sendable (URL, Bool) -> DirectoryChangeMonitor

    /// Called on the main actor when the watched folder changes.
    var onChange: () -> Void = {}
    private let makeMonitor: MonitorFactory
    private var monitor: DirectoryChangeMonitor?
    private var watched: LibraryMonitorContext?

    init(makeMonitor: @escaping MonitorFactory) {
        self.makeMonitor = makeMonitor
    }

    deinit {
        monitor?.stop()
    }

    var isWatching: Bool { monitor != nil }

    /// Watches `folderURL`. Returns false when it was already being watched
    /// the same way. `includingOtherFiles` makes changes to non-image files
    /// count too (they are listed only when the gallery shows other files).
    @discardableResult
    func watch(_ folderURL: URL, includingSubfolders recursive: Bool, includingOtherFiles: Bool = false) -> Bool {
        let context = LibraryMonitorContext(
            folderURL: folderURL, recursive: recursive, includesOtherFiles: includingOtherFiles
        )
        guard watched != context || monitor == nil else { return false }
        monitor?.stop()
        watched = context
        let next = makeMonitor(folderURL, recursive)
        next.includesOtherFiles = includingOtherFiles
        monitor = next
        next.start(onInvalidated: { [weak self, weak next] in
            guard let self, let next, self.monitor === next else { return }
            self.monitor = nil
            self.watched = nil
        }) { [weak self] in
            self?.onChange()
        }
        return true
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        watched = nil
    }
}
