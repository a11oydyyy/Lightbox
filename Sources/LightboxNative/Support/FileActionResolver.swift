import Foundation

enum FileActionResolver {
    static func existingURLs(_ urls: [URL],
                             exists: @escaping @Sendable (URL) -> Bool = {
                                 FileManager.default.fileExists(atPath: $0.path)
                             }) async throws -> [URL] {
        let worker = Task.detached(priority: .userInitiated) {
            var result: [URL] = []
            for url in urls {
                try Task.checkCancellation()
                if exists(url) { result.append(url) }
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
}
