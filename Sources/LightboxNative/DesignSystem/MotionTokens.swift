import SwiftUI

enum MotionTokens {
    // Durations used for task scheduling. These must stay in sync with the
    // spatial springs below so state-machine timing matches the visuals.
    // Scaled down with the faster previewGeometry spring (response 0.30): the
    // overlay tear-down (previewGeometryDuration) lands right as the image
    // settles, the source card is revealed a touch before that, and the full-res
    // upgrade still fires comfortably *after* the zoom settles so its decode
    // never hitches mid-scale.
    static let previewGeometryDurationSeconds = 0.38
    static let previewGeometryDuration: Duration = .milliseconds(380)
    static let previewSourceRevealDelay: Duration = .milliseconds(330)
    static let previewHighResolutionDelay: Duration = .milliseconds(480)

    // Core UI springs. Use APIs available on macOS 13 so the compatibility app
    // can share the same motion language without macOS 14-only symbols.
    static let quick = Animation.spring(response: 0.20, dampingFraction: 1.0)
    static let standard = Animation.spring(response: 0.28, dampingFraction: 1.0)
    // Longer, ease-out-leaning spring so resizing thumbnails decelerate into
    // their final size instead of tracking the slider near-linearly.
    static let thumbnailScale = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let preview = Animation.easeInOut(duration: 0.24)

    // Asymmetric hover: snap in, ease out. The faster in / slower out pairing
    // is what reads as "expensive" on macOS hover micro-interactions.
    static let hoverIn = Animation.spring(response: 0.18, dampingFraction: 0.92)
    static let hoverOut = Animation.easeOut(duration: 0.28)
    static func hover(_ isOn: Bool) -> Animation { isOn ? hoverIn : hoverOut }

    // Press: quick down, tiny rubber overshoot on release.
    static let pressIn = Animation.easeOut(duration: 0.12)
    static let pressRelease = Animation.spring(response: 0.30, dampingFraction: 0.62)
    static func press(_ isPressed: Bool) -> Animation { isPressed ? pressIn : pressRelease }

    // Sidebar disclosure (expand/collapse). A gentle ease-in-out bezier matching
    // the native NSOutlineView feel: children slide up and fade back into the
    // parent row instead of snapping out. Bezier (not spring) so the height
    // decelerates into place with no bounce — the rows below glide up to fill.
    static let sidebarDisclosure = Animation.timingCurve(0.33, 0.0, 0.2, 1.0, duration: 0.34)

    // Spatial open/close: interruptible springs. Unlike a timing curve, a spring
    // retargets from the current position and velocity, so a close that
    // interrupts an open reverses smoothly instead of snapping/restarting.
    // dampingFraction 1.0 = critically damped: the image scales up and back with
    // no overshoot/rebound at either end (per request), while still retargeting.
    // response 0.30 = a touch snappier than before, still smooth and bounce-free.
    static let previewGeometry = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let previewChrome = Animation.spring(response: 0.40, dampingFraction: 1.0)

    static func ifAllowed(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        // Reduced motion still gets a designed, gentle cross-fade rather than a
        // near-instant snap, so transitions read as intentional.
        reduceMotion ? .easeOut(duration: 0.12) : animation
    }
}

extension AnyTransition {
    static var lightboxBlurReplace: AnyTransition {
        .opacity
    }
}

extension View {
    @ViewBuilder
    func lightboxSymbolReplaceTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            contentTransition(.opacity)
        }
    }

    @ViewBuilder
    func lightboxNumericTextTransition(value: Double) -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText(value: value))
        } else {
            contentTransition(.opacity)
        }
    }
}
