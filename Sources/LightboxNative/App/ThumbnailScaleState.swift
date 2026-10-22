import Combine
import CoreGraphics

/// The gallery's thumbnail size and whether the size slider is being dragged.
///
/// The slider changes the width many times per second, but only the gallery
/// and the slider depend on it. Keeping it outside `AppState` means a drag
/// re-renders those two views instead of the sidebar, header and window
/// chrome too. `AppState.thumbnailWidth` and `AppState.isScalingThumbnails`
/// forward here and keep the tab-state bookkeeping.
@MainActor
final class ThumbnailScaleState: ObservableObject {
    @Published var width: CGFloat = 206
    @Published var isScaling = false
    /// The width the gallery's columns share, as it last laid out (not
    /// published: nothing redraws for it). Column steps work from it.
    var galleryAvailableWidth: CGFloat = 0
    /// The image at the top before a column step, kept there after it (a
    /// step re-flows the masonry, which would otherwise show other images).
    @Published var columnStepAnchor: ColumnStepAnchor?
}

struct ColumnStepAnchor: Equatable {
    var assetID: LightboxAsset.ID
    /// New for every step, so the same image can be kept twice in a row.
    var generation: Int
}
