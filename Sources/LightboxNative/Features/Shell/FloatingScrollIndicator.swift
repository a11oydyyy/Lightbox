import AppKit
import SwiftUI

/// Uses AppKit's overlay scroller for native fade timing, dragging and accessibility.
struct GalleryScrollBarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> GalleryScrollBarConfigurationView {
        GalleryScrollBarConfigurationView()
    }

    func updateNSView(_ nsView: GalleryScrollBarConfigurationView, context: Context) {
        nsView.configureScrollView()
        // SwiftUI may attach the hosting hierarchy after this update.
        DispatchQueue.main.async { [weak nsView] in
            nsView?.configureScrollView()
        }
    }
}

final class GalleryScrollBarConfigurationView: NSView {
    private weak var configuredScrollView: NSScrollView?
    private var scrollerInsetsObservation: NSKeyValueObservation?

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
        guard let scrollView = enclosingScrollView else {
            scrollerInsetsObservation = nil
            configuredScrollView = nil
            return
        }
        if configuredScrollView !== scrollView {
            configuredScrollView = scrollView
            scrollerInsetsObservation = scrollView.observe(\.scrollerInsets, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    self?.applyScrollerInsets(to: scrollView)
                }
            }
        }
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        applyScrollerInsets(to: scrollView)
    }

    private func applyScrollerInsets(to scrollView: NSScrollView) {
        // The gallery extends behind the 52pt header; keep the entire thumb below it.
        // SwiftUI reapplies indicator insets during layout, so restore this inset
        // when it changes rather than only when the representable is updated.
        let insets = scrollView.scrollerInsets
        guard insets.top != 58 || insets.left != 0 || insets.bottom != 6 || insets.right != 0 else { return }
        scrollView.scrollerInsets = NSEdgeInsets(top: 58, left: 0, bottom: 6, right: 0)
    }
}
