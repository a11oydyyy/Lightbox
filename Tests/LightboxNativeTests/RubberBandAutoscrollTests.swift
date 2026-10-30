import CoreGraphics
import Testing
@testable import LightboxNative

// A drag selection scrolls only near the top or bottom edge, faster the deeper in.
@Test func rubberBandAutoscrollsNearTheEdgesOnly() {
    let step = { (y: CGFloat) in RubberBandSelectionView.autoscrollStep(at: y, height: 800, edge: 64) }
    #expect(step(400) == 0)
    #expect(step(64) == 0)
    #expect(step(736) == 0)
    #expect(step(40) < 0)
    #expect(step(760) > 0)
    #expect(step(10) < step(40))
    #expect(step(790) > step(760))
    // Past the edge, capped.
    #expect(step(-500) == -36)
    #expect(step(2000) == 36)
}
