import Combine

/// Progress of long-running background work: library scans and file
/// transfers.
///
/// Progress ticks many times per operation but only the header shows it, so
/// it lives outside `AppState`: a tick re-renders the header alone instead of
/// every view that observes the app state. `AppState.libraryLoadingStatus`
/// and `AppState.fileTransferProgress` forward here and still publish when an
/// operation starts or finishes, the only edges other views depend on.
@MainActor
final class BackgroundActivityState: ObservableObject {
    @Published var loadingStatus: LibraryLoadingStatus?
    @Published var fileTransferProgress: FileTransferProgress?
}
