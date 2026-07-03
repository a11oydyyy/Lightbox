import SwiftUI

struct Hover3DModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isReduced = false
    var isEnabled = true
    @State private var isHovering = false
    @State private var hoverUnitPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var contentSize: CGSize = .zero

    @ViewBuilder
    func body(content: Content) -> some View {
        hoverBody(content: content)
    }

    private func hoverBody(content: Content) -> some View {
        let active = isEnabled && isHovering && !reduceMotion
        let tracksPointer = active && !isReduced
        let highlightPoint = tracksPointer ? hoverUnitPoint : CGPoint(x: 0.5, y: 0.26)
        let xTilt = tracksPointer ? (0.5 - hoverUnitPoint.y) * 5.5 : 0
        let yTilt = tracksPointer ? (hoverUnitPoint.x - 0.5) * 5.5 : 0

        return content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            contentSize = proxy.size
                        }
                        .onChange(of: proxy.size) { size in
                            contentSize = size
                        }
                }
            }
            .overlay {
                if active {
                    // Fill a rounded rect (not a bare gradient) so the highlight
                    // is clipped to the card's corners.
                    RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(tracksPointer ? 0.28 : 0.18),
                                    .white.opacity(tracksPointer ? 0.08 : 0.05),
                                    .clear
                                ],
                                center: UnitPoint(x: highlightPoint.x, y: highlightPoint.y),
                                startRadius: 2,
                                endRadius: max(contentSize.width, contentSize.height) * 0.72
                            )
                        )
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
                        .strokeBorder(.white.opacity(0.20), lineWidth: 0.7)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .rotation3DEffect(.degrees(xTilt), axis: (x: 1, y: 0, z: 0), perspective: 0.58)
            .rotation3DEffect(.degrees(yTilt), axis: (x: 0, y: 1, z: 0), perspective: 0.58)
            .scaleEffect(active ? (tracksPointer ? 1.012 : 1.005) : 1)
            // Shadow is keyed only to the boolean hover state, not live pointer
            // position, to avoid re-rasterizing the shadow on every mouse move.
            .shadow(
                color: .black.opacity(active ? (tracksPointer ? 0.16 : 0.10) : 0),
                radius: active ? (tracksPointer ? 9 : 5) : 0,
                x: 0,
                y: active ? (tracksPointer ? 5 : 3) : 0
            )
            .animation(MotionTokens.ifAllowed(MotionTokens.hover(active), reduceMotion: reduceMotion), value: active)
            .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: isReduced)
            .onChange(of: isEnabled) { enabled in
                if !enabled {
                    endHover()
                }
            }
            .onContinuousHover { phase in
                guard isEnabled else {
                    endHover()
                    return
                }
                switch phase {
                case .active(let location):
                    updateHover(location: location)
                case .ended:
                    endHover()
                }
            }
    }

    private func updateHover(location: CGPoint) {
        guard isEnabled else {
            endHover()
            return
        }

        if isReduced {
            isHovering = true
            hoverUnitPoint = CGPoint(x: 0.5, y: 0.5)
            return
        }

        guard !reduceMotion, contentSize.width > 0, contentSize.height > 0 else {
            return
        }

        let next = CGPoint(
            x: min(1, max(0, location.x / contentSize.width)),
            y: min(1, max(0, location.y / contentSize.height))
        )
        let movedEnough = abs(next.x - hoverUnitPoint.x) > 0.01 || abs(next.y - hoverUnitPoint.y) > 0.01

        if !isHovering {
            isHovering = true
            hoverUnitPoint = next
        } else if movedEnough {
            hoverUnitPoint = next
        }
    }

    private func endHover() {
        isHovering = false
        hoverUnitPoint = CGPoint(x: 0.5, y: 0.5)
    }
}

extension View {
    func hover3D(isReduced: Bool = false, isEnabled: Bool = true) -> some View {
        modifier(Hover3DModifier(isReduced: isReduced, isEnabled: isEnabled))
    }
}
