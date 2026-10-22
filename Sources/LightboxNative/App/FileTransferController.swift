import Foundation

/// Runs copy and move requests one at a time and reports their progress.
///
/// Owns the queue, the running task, the failure count across a batch and the
/// short delay before a finished batch's status goes away. It knows nothing
/// about tabs or the library: `AppState` decides where files go and applies
/// each finished request's results.
@MainActor
final class FileTransferController {
    typealias Executor = @Sendable (
        FileTransferRequest,
        @escaping @Sendable (FileTransferProgressUpdate) -> Void
    ) -> FileTransferResult

    /// The batch's progress, or nil when nothing is shown.
    private(set) var progress: FileTransferProgress? {
        didSet { if progress != oldValue { onProgressChange(progress) } }
    }
    /// Called whenever `progress` changes.
    var onProgressChange: (FileTransferProgress?) -> Void = { _ in }
    /// Called with each request's result, before progress moves on.
    var onResult: (FileTransferResult) -> Void = { _ in }

    private let executor: Executor
    private var queue: [FileTransferRequest] = []
    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var failureCount = 0
    private var firstFailureName: String?

    init(executor: @escaping Executor) {
        self.executor = executor
    }

    deinit {
        task?.cancel()
        dismissTask?.cancel()
    }

    func enqueue(_ request: FileTransferRequest) {
        // A new batch starts counting failures afresh, unless the last one
        // failed and its status is still showing.
        if task == nil, queue.isEmpty, progress?.phase != .failed {
            failureCount = 0
            firstFailureName = nil
        }
        dismissTask?.cancel()
        dismissTask = nil
        queue.append(request)
        startNextIfNeeded()
    }

    func cancel() {
        queue = []
        task?.cancel()
    }

    /// Hides a finished batch's status. An active transfer keeps showing.
    func dismissStatus() {
        guard progress?.phase != .active else { return }
        dismissTask?.cancel()
        dismissTask = nil
        progress = nil
        failureCount = 0
        firstFailureName = nil
    }

    private func startNextIfNeeded() {
        guard task == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        progress = FileTransferProgress(
            requestID: request.id,
            operation: request.operation,
            phase: .active,
            completedCount: 0,
            totalCount: request.sourceURLs.count,
            failedCount: failureCount,
            currentName: request.sourceURLs.first?.lastPathComponent ?? ""
        )

        let executor = executor
        let progressHandler: @Sendable (FileTransferProgressUpdate) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.apply(update, requestID: request.id)
            }
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = executor(request, progressHandler)
            await self?.finish(result)
        }
    }

    private func apply(_ update: FileTransferProgressUpdate, requestID: UUID) {
        guard var progress, progress.requestID == requestID, progress.phase == .active else { return }
        // One assignment, so each update publishes once.
        progress.completedCount = update.completedCount
        progress.totalCount = update.totalCount
        progress.currentName = update.currentName
        self.progress = progress
    }

    private func finish(_ result: FileTransferResult) {
        guard var progress, progress.requestID == result.requestID else {
            task = nil
            startNextIfNeeded()
            return
        }

        onResult(result)
        failureCount += result.failures.count
        if firstFailureName == nil, let firstFailure = result.failures.first {
            firstFailureName = firstFailure.sourceURL.lastPathComponent
        }
        progress.completedCount = result.successes.count + result.failures.count
        progress.failedCount = failureCount
        if result.wasCancelled {
            markFinished(&progress, cancelled: true)
        }
        task = nil

        if !queue.isEmpty {
            self.progress = progress
            startNextIfNeeded()
            return
        }

        if !result.wasCancelled {
            markFinished(&progress, cancelled: false)
        }
        self.progress = progress

        if failureCount == 0, !result.wasCancelled {
            let requestID = result.requestID
            dismissTask?.cancel()
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled, let self, self.progress?.requestID == requestID else { return }
                self.progress = nil
            }
        }
    }

    /// Failed (naming the first failure) when anything in the batch failed;
    /// otherwise cancelled or completed.
    private func markFinished(_ progress: inout FileTransferProgress, cancelled: Bool) {
        if failureCount > 0 {
            progress.phase = .failed
            progress.currentName = firstFailureName ?? ""
        } else {
            progress.phase = cancelled ? .cancelled : .completed
        }
    }
}
