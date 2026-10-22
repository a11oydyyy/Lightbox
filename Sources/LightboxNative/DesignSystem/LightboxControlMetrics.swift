import Foundation

/// Shared by SwiftUI controls and the native titlebar.
enum LightboxControlMetrics {
    static let iconButtonSize: CGFloat = 32
    /// The sidebar toggle in the native toolbar, inside the sidebar's top band.
    static let toolbarButtonSize: CGFloat = 28
    static let iconSize: CGFloat = 14
    static let cornerRadius: CGFloat = 8
    static let focusLineWidth: CGFloat = 1.5
    /// Matches the gallery folder tiles' hover, so every hover reads the same.
    static let hoverOpacity = 0.08
    static let pressedOpacity = 0.12
}
