import Foundation

enum FileTransferOperation: String, Equatable, Sendable {
    case copy
    case move
}

struct FileTransferRequest: Identifiable, Equatable, Sendable {
    var id = UUID()
    var sourceURLs: [URL]
    var destinationFolderURL: URL
    var operation: FileTransferOperation
}

struct FileTransferProgressUpdate: Equatable, Sendable {
    var completedCount: Int
    var totalCount: Int
    var currentName: String
}

struct FileTransferSuccess: Equatable, Sendable {
    var sourceURL: URL
    var destinationURL: URL
}

struct FileTransferFailure: Equatable, Sendable {
    var sourceURL: URL
    var message: String
    var committedDestinationURL: URL?

    init(sourceURL: URL, message: String, committedDestinationURL: URL? = nil) {
        self.sourceURL = sourceURL
        self.message = message
        self.committedDestinationURL = committedDestinationURL
    }
}

struct FileTransferResult: Equatable, Sendable {
    var requestID: UUID
    var operation: FileTransferOperation
    var successes: [FileTransferSuccess]
    var failures: [FileTransferFailure]
    var wasCancelled: Bool
}

struct FileTransferProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case active
        case completed
        case failed
        case cancelled
    }

    var requestID: UUID
    var operation: FileTransferOperation
    var phase: Phase
    var completedCount: Int
    var totalCount: Int
    var failedCount: Int
    var currentName: String

    var fractionCompleted: Double {
        guard totalCount > 0 else { return phase == .active ? 0 : 1 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }
}
