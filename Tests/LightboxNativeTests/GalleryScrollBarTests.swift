import AppKit
import Testing
@testable import LightboxNative

@Test @MainActor func galleryScrollbarPreservesHeaderClearanceAfterLayoutReset() {
    let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    let document = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 1200))
    scrollView.documentView = document
    let configurator = GalleryScrollBarConfigurationView()
    document.addSubview(configurator)

    // SwiftUI resets the native indicator insets after attaching its content.
    scrollView.scrollerInsets = NSEdgeInsetsZero
    #expect(scrollView.scrollerInsets.top == 58)
    #expect(scrollView.scrollerInsets.bottom == 6)

    configurator.removeFromSuperview()
    scrollView.scrollerInsets = NSEdgeInsetsZero
    #expect(scrollView.scrollerInsets.top == 0)

    let nextScrollView = NSScrollView()
    let nextDocument = NSView()
    nextScrollView.documentView = nextDocument
    nextDocument.addSubview(configurator)
    nextScrollView.scrollerInsets = NSEdgeInsetsZero
    #expect(nextScrollView.scrollerInsets.top == 58)
}
