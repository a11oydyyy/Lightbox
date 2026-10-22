import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    @ObservedObject var appState: AppState
    /// Scan and transfer progress publish here, not on `appState`; observing
    /// it keeps the header current without re-rendering the window.
    @ObservedObject private var activity: BackgroundActivityState

    init(appState: AppState) {
        self.appState = appState
        activity = appState.activity
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.configureIfNeeded(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configureIfNeeded(from: nsView)
        context.coordinator.updateSidebarButton()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let appState: AppState
        private var headerAccessory: NSTitlebarAccessoryViewController?
        private var headerHost: NativeNavigationBar?
        private var sidebarChromeVisible: Bool?
        private var sidebarButton: NSButton?

        init(appState: AppState) {
            self.appState = appState
            super.init()
        }

        /// The sidebar toggle sits beside the window controls, outside the
        /// toolbar: macOS 26+ puts a glass platter behind every toolbar item,
        /// which doubled up with this button's own hover fill. Same control as
        /// the header's back/forward buttons, at the standard 28pt toolbar size
        /// so its fill clears the edges of the sidebar's 40pt top band.
        private func installSidebarButton(in window: NSWindow) {
            guard sidebarButton == nil, let zoom = window.standardWindowButton(.zoomButton),
                  let titlebar = zoom.superview else { return }
            let button = HeaderIconButton()
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: LightboxControlMetrics.iconSize, weight: .regular))
            button.target = self
            button.action = #selector(toggleSidebar)
            button.focusRingType = .none
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(button)
            let size = LightboxControlMetrics.toolbarButtonSize
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: size),
                button.heightAnchor.constraint(equalToConstant: size),
                // Where the toolbar item used to sit.
                button.centerXAnchor.constraint(equalTo: zoom.centerXAnchor, constant: 42),
                button.centerYAnchor.constraint(equalTo: zoom.centerYAnchor)
            ])
            sidebarButton = button
            updateSidebarButton()
        }

        func updateSidebarButton() {
            let title = appState.localized(appState.sidebarCollapsed ? .openSidebar : .closeSidebar)
            sidebarButton?.toolTip = title
            sidebarButton?.setAccessibilityLabel(title)
            let visible = appState.isOverlayChromeVisible
            // Restore appearance with the titlebar; toggleSidebar still guards the overlay.
            sidebarButton?.isEnabled = visible
            if let sidebarButton {
                NativeChromeTransition.apply(to: sidebarButton, visible: visible, wasVisible: sidebarChromeVisible)
                sidebarChromeVisible = visible
            }
            headerHost?.refresh()
        }

        @objc private func toggleSidebar() {
            guard appState.previewAssetID == nil && !appState.isComparing else { return }
            appState.sidebarCollapsed.toggle()
            updateSidebarButton()
        }

        private weak var configuredWindow: NSWindow?
        private var pendingConfigure = false

        func configureIfNeeded(from view: NSView) {
            guard let window = view.window else {
                scheduleConfigure(from: view)
                return
            }

            guard configuredWindow !== window else { return }
            configuredWindow = window
            configure(window: window)
        }

        private func scheduleConfigure(from view: NSView) {
            guard !pendingConfigure else { return }
            pendingConfigure = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                pendingConfigure = false
                guard let view else { return }
                configureIfNeeded(from: view)
            }
        }

        private func configure(window: NSWindow) {
            window.title = "Lightbox"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            // An empty toolbar: it gives the titlebar its unified height and
            // places the window controls; the header is a titlebar accessory.
            let toolbar = NSToolbar(identifier: "Lightbox.WindowHeader")
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            // Display-mode customization is independent of item customization.
            // Text modes change native toolbar geometry around our fixed-height accessory.
            if #available(macOS 15.0, *) {
                toolbar.allowsDisplayModeCustomization = false
            }
            window.toolbar = toolbar
            let host = NativeNavigationBar(appState: appState)
            let width = max(300, window.frame.width - 152)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 52)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            accessory.view = host
            window.addTitlebarAccessoryViewController(accessory)
            installSidebarButton(in: window)
            appState.quickLook.attach(to: window)
            headerAccessory = accessory
            headerHost = host
            window.minSize = NSSize(width: 980, height: 680)
            window.backgroundColor = .clear
            NotificationCenter.default.addObserver(self, selector: #selector(resizeHeader), name: NSWindow.didResizeNotification, object: window)
            DispatchQueue.main.async { [weak self] in self?.resizeHeader() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func resizeHeader() {
            guard let window = configuredWindow, let host = headerHost else { return }
            let width = max(300, window.frame.width - 152)
            host.setFrameSize(NSSize(width: width, height: 52))
            host.needsLayout = true
        }
    }
}

final class TitlebarInteractionView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let window {
            window.performDrag(with: event)
        } else {
            // Let AppKit complete its titlebar double-click gesture on mouse-up.
            // An extra performZoom here can immediately undo that native zoom.
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Keep the native gesture as the only double-click zoom handler.
        guard event.clickCount < 2 else { return }
        super.mouseUp(with: event)
    }
}

/// Native toolbar geometry supplies the window controls and their standard behavior.
struct WindowHeaderDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitlebarInteractionView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
