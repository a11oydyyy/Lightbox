import Foundation

// SQLite may wait for a concurrent snapshot writer. Source navigation/pinning
// must not inherit that wait on the main actor. This queue also preserves order.
final class SourceIndexWriter: @unchecked Sendable {
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "Lightbox.SourceIndex", qos: .utility)
    // Accessed only on queue, including lazy connection/schema creation.
    private var store: LightboxIndexStore?

    init(databaseURL: URL) { self.databaseURL = databaseURL }

    func upsertSource(_ source: LibrarySource) {
        queue.async { [self] in
            if store == nil { store = LightboxIndexStore(databaseURL: databaseURL) }
            store?.upsertSource(source)
        }
    }
}
