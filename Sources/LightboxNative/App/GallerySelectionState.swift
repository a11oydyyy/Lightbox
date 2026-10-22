import Combine

/// Which images and folder are selected in the gallery.
///
/// Selection changes on every click and Command-click, but only the gallery,
/// the header's selection bar and the menu commands show it. Keeping it
/// outside `AppState` means a click re-renders those instead of the sidebar
/// and window chrome too. `AppState` forwards its selection properties here
/// and still publishes when a selection starts, ends or becomes a
/// multi-selection, the only changes the rest of the window depends on.
@MainActor
final class GallerySelectionState: ObservableObject {
    @Published var assetIDs: Set<LightboxAsset.ID> = []
    @Published var assetID: LightboxAsset.ID?
    @Published var folderID: LibraryFolderEntry.ID?
}

/// The gallery's keyboard focus ring and the request to scroll it into view.
/// Arrow keys change it on every press and only the gallery draws it.
@MainActor
final class GalleryKeyboardFocusState: ObservableObject {
    @Published var assetID: LightboxAsset.ID?
    @Published var scrollGeneration = 0
}
