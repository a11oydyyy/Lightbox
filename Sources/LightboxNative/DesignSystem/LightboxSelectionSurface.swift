import SwiftUI

enum LightboxSelectionTokens {
    static let controlFillOpacity: Double = 0.08
    static let hoverFillOpacity = LightboxControlMetrics.hoverOpacity
    static let dropFillOpacity: Double = 0.14
    static let emphasisStrokeOpacity: Double = 0.62
    static let emphasisLineWidth: CGFloat = 1
}

/// Shared selected-state treatment for compact navigation and mode controls.
/// Persistent selection is a quiet tint without an outline. Focus, drop targets,
/// and content-object selection may opt into a stroke for semantic emphasis.
struct LightboxSelectionSurface<S: Shape>: View {
    var shape: S
    var fillOpacity: Double = LightboxSelectionTokens.controlFillOpacity
    var strokeOpacity: Double = 0
    var lineWidth: CGFloat = 0


    private var accent: Color {
        LightboxColorTokens.accent
    }

    var body: some View {
        shape
            .fill(accent.opacity(fillOpacity))
            .overlay {
                if strokeOpacity > 0, lineWidth > 0 {
                    shape.stroke(accent.opacity(strokeOpacity), lineWidth: lineWidth)
                }
            }
    }
}
