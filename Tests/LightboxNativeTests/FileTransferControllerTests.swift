import Foundation
import Testing
@testable import LightboxNative

@MainActor
private func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func request(_ names: [String]) -> FileTransferRequest {
    FileTransferRequest(sourceURLs: names.map { URL(fileURLWithPath: "/tmp/\($0)") },
                        destinationFolderURL: URL(fileURLWithPath: "/tmp/destination"), operation: .copy)
}

// A cancelled batch with nothing failed says so, rather than complete or failed.
@Test @MainActor func cancelledTransferWithoutFailuresReportsCancelled() async {
    let controller = FileTransferController { request, _ in
        FileTransferResult(requestID: request.id, operation: request.operation,
                           successes: [], failures: [], wasCancelled: true)
    }
    var results = 0
    controller.onResult = { _ in results += 1 }
    controller.enqueue(request(["a.jpg", "b.jpg"]))
    #expect(await waitFor { controller.progress?.phase == .cancelled })
    #expect(results == 1)
    #expect(controller.progress?.failedCount == 0)
}

// A successful batch reports completion, then its status goes away on its own;
// every change reaches the progress callback.
@Test @MainActor func completedTransferStatusDismissesItself() async {
    let controller = FileTransferController { request, progress in
        progress(FileTransferProgressUpdate(completedCount: 1, totalCount: 2, currentName: "b.jpg"))
        return FileTransferResult(requestID: request.id, operation: request.operation,
            successes: request.sourceURLs.map { FileTransferSuccess(sourceURL: $0, destinationURL: $0) },
            failures: [], wasCancelled: false)
    }
    var reported: [FileTransferProgress?] = []
    controller.onProgressChange = { reported.append($0) }
    controller.enqueue(request(["a.jpg", "b.jpg"]))
    #expect(await waitFor { controller.progress?.phase == .completed })
    #expect(controller.progress?.completedCount == 2)
    #expect(await waitFor { controller.progress == nil })
    #expect(reported.first??.phase == .active)
    #expect(reported.last! == nil)
}
