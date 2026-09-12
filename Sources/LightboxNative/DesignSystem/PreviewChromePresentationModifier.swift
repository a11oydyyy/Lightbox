import SwiftUI

struct PreviewChromePresentationModifier: ViewModifier {
    var isVisible: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(
                MotionTokens.ifAllowed(isVisible ? MotionTokens.chromeReveal : MotionTokens.chromeHide,
                                       reduceMotion: reduceMotion),
                value: isVisible
            )
    }
}

struct BottomPreviewChromePresentationModifier: ViewModifier {
    var isVisible: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content.previewChromePresentation(isVisible: isVisible, reduceMotion: reduceMotion)
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
