import AppKit
import SwiftUI

struct GalleryRefreshControl: NSViewRepresentable {
    var isRefreshing: Bool
    var isEnabled: Bool
    var refresh: () -> Void

    func makeNSView(context: Context) -> GalleryRefreshView { GalleryRefreshView() }
    func updateNSView(_ view: GalleryRefreshView, context: Context) {
        let stateChanged = view.isRefreshing != isRefreshing || view.isEnabled != isEnabled
        view.isRefreshing = isRefreshing
        view.isEnabled = isEnabled
        view.refresh = refresh
        guard stateChanged || view.needsAttachment else { return }
        view.attach()
        if view.needsAttachment {
            DispatchQueue.main.async { [weak view] in view?.attach() }
        }
    }
    static func dismantleNSView(_ view: GalleryRefreshView, coordinator: ()) { view.detach() }
}

final class GalleryRefreshView: NSView {
    var isRefreshing = false
    var isEnabled = true
    var refresh: (() -> Void)?
    private weak var scrollView: NSScrollView?
    // Stored as NSObject to preserve deployment on systems without this class.
    private var controller: NSObject?
    private var isConfiguring = false

    var needsAttachment: Bool {
        guard #available(macOS 27, *) else { return false }
        return scrollView == nil || controller == nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }

    func attach() {
        guard !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        guard #available(macOS 27, *) else { return }
        guard let parent = enclosingScrollView else { removeController(); return }
        if scrollView !== parent || controller == nil {
            removeController()
            // macOS 27 may retain an ended controller in a mounted scroll view.
            // Reuse it when SwiftUI recreates the background host in that view.
            let next = parent.refreshController ?? NSRefreshController()
            controller = next
            scrollView = parent
            parent.refreshController = next
        }
        guard let controller = controller as? NSRefreshController else { return }
        guard isEnabled else {
            if controller.target === self { controller.target = nil }
            if controller.isRefreshing { controller.endRefreshing() }
            return
        }
        if controller.target !== self { controller.target = self }
        if controller.action != #selector(trigger) { controller.action = #selector(trigger) }
        if isRefreshing && !controller.isRefreshing { controller.beginRefreshing() }
        if !isRefreshing && controller.isRefreshing { controller.endRefreshing() }
    }

    func detach() {
        guard !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        removeController()
    }

    private func removeController() {
        // AppKit changes the document hierarchy while ending refresh. Snapshot the
        // owner first and ignore reentrant attachment callbacks during that change.
        let parent = scrollView
        let previous = controller
        controller = nil
        scrollView = nil
        if #available(macOS 27, *), let owned = previous as? NSRefreshController,
           owned.target === self || owned.target == nil {
            // macOS 27 can retain an ended controller while the scroll view is
            // mounted in a window, even after setting refreshController to nil.
            // Always remove the action target so that retained controls are inert.
            owned.target = nil
            owned.endRefreshing()
            if parent?.refreshController === owned { parent?.refreshController = nil }
        }
    }

    @objc private func trigger() {
        guard isEnabled, !isRefreshing else { return }
        refresh?()
    }
}
