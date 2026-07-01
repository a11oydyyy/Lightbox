import SwiftUI

struct PreviewChromePresentationModifier: ViewModifier {
    var isVisible: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        // Animating `blur(radius:)` on these glass/material capsules was the cause
        // of the ~60ms frame peak when the chrome returns during a preview close:
        // a material layer can't cache a Gaussian blur, so every frame re-rasterized
        // the whole capsule — and it fired on top bar + bottom bar + in-preview
        // controls at once. Opacity + a slight scale reads just as cleanly and is
        // cheap. `compositingGroup` is dropped too (it only existed to bound the
        // blur, and it forced an offscreen buffer every frame of the fade).
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(
                x: isVisible || reduceMotion ? 1 : 1.02,
                y: isVisible || reduceMotion ? 1 : 1.008,
                anchor: .center
            )
            // Asymmetric: the *show* fades in over the full spring (chrome settling
            // back after a preview closes), but the *hide* uses a quick 0.07s fade.
            // `.animation(value:)` reads the new value, so the ternary picks the
            // animation by direction. A fast hide keeps a preview opening from
            // drawing the image over a lingering pill, without the abruptness of an
            // instant cut.
            .animation(
                isVisible
                    ? MotionTokens.ifAllowed(MotionTokens.previewChrome, reduceMotion: reduceMotion)
                    : MotionTokens.ifAllowed(.easeOut(duration: 0.07), reduceMotion: reduceMotion),
                value: isVisible
            )
    }
}

struct BottomPreviewChromePresentationModifier: ViewModifier {
    var isVisible: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        // Keep the native Slider out of scale/blur animations. Those are cheap for
        // static capsules, but they made SwiftUI's AppKit slider bridge emit
        // SystemSlider invalid-configuration state dumps during preview closes.
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 8)
            .animation(
                isVisible
                    ? MotionTokens.ifAllowed(MotionTokens.previewChrome, reduceMotion: reduceMotion)
                    : MotionTokens.ifAllowed(.easeOut(duration: 0.07), reduceMotion: reduceMotion),
                value: isVisible
            )
    }
}

extension View {
    func previewChromePresentation(isVisible: Bool, reduceMotion: Bool) -> some View {
        modifier(PreviewChromePresentationModifier(isVisible: isVisible, reduceMotion: reduceMotion))
    }

    func bottomPreviewChromePresentation(isVisible: Bool, reduceMotion: Bool) -> some View {
        modifier(BottomPreviewChromePresentationModifier(isVisible: isVisible, reduceMotion: reduceMotion))
    }
}
