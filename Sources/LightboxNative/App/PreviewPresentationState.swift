import Combine
import CoreGraphics
import Foundation

/// What the open preview shows: the image, where it opened from, and the
/// gallery card it hides while it is open.
///
/// Stepping with the arrow keys changes these on every press, but only the
/// preview and the gallery depend on them; the sidebar, header and window
/// chrome only care whether a preview is open. `AppState` forwards its
/// preview properties here and still publishes when a preview appears or
/// goes away.
@MainActor
final class PreviewPresentationState: ObservableObject {
    @Published var assetID: LightboxAsset.ID?
    @Published var sourceHiddenAssetID: LightboxAsset.ID?
    @Published var sourceFrame: CGRect?
    @Published var sessionID = UUID()
    @Published var stepDirection: PreviewDirection?
}
