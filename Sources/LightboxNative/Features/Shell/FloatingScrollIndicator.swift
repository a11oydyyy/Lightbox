import AppKit
import SwiftUI

/// Uses AppKit's overlay scroller for native fade timing, dragging and accessibility.
struct GalleryScrollBarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> GalleryScrollBarConfigurationView {
        GalleryScrollBarConfigurationView()
    }

    func updateNSView(_ nsView: GalleryScrollBarConfigurationView, context: Context) {
        nsView.configureScrollView()
    }
}

final class GalleryScrollBarConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureScrollView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureScrollView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configureScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        // The gallery extends behind the 52pt header; keep the entire thumb below it.
        scrollView.scrollerInsets = NSEdgeInsets(top: 58, left: 0, bottom: 6, right: 0)
    }
}
