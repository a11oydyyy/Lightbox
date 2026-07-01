import SwiftUI

struct FloatingScrollIndicator: View {
    var viewportHeight: CGFloat
    var contentHeight: CGFloat
    var fraction: CGFloat
    var isVisible: Bool

    private var thumbHeight: CGFloat {
        let ratio = viewportHeight / max(viewportHeight, contentHeight)
        return max(54, viewportHeight * ratio)
    }

    private var travel: CGFloat {
        max(0, viewportHeight - thumbHeight - 28)
    }

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.24))
            .overlay {
                Capsule().stroke(.white.opacity(0.22), lineWidth: 0.8)
            }
            .frame(width: 7, height: thumbHeight)
            .offset(y: 14 + travel * min(1, max(0, fraction)))
            .frame(width: 18, height: viewportHeight, alignment: .top)
            .lightboxGlass(Capsule())
            .opacity(isVisible ? 1 : 0)
            .animation(MotionTokens.quick, value: isVisible)
            .allowsHitTesting(false)
    }
}
