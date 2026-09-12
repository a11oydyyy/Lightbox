import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    @ObservedObject var appState: AppState

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
    final class Coordinator: NSObject, NSToolbarDelegate {
        private let appState: AppState
        private var headerAccessory: NSTitlebarAccessoryViewController?
        private var headerHost: NativeNavigationBar?
        private var sidebarChromeVisible: Bool?
        private let sidebarItemID = NSToolbarItem.Identifier("Lightbox.ToggleSidebar")
        private var sidebarButton: NSButton?
        private var sidebarItem: NSToolbarItem?

        init(appState: AppState) {
            self.appState = appState
            super.init()
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [sidebarItemID]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [sidebarItemID]
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard itemIdentifier == sidebarItemID else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.isNavigational = true
            let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)!, target: self, action: #selector(toggleSidebar))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setFrameSize(NSSize(width: 36, height: 32))
            item.view = button
            item.label = appState.localized(.openSidebar)
            sidebarItem = item
            sidebarButton = button
            updateSidebarButton()
            return item
        }

        func updateSidebarButton() {
            let title = appState.localized(appState.sidebarCollapsed ? .openSidebar : .closeSidebar)
            sidebarItem?.label = title
            sidebarItem?.toolTip = title
            sidebarButton?.toolTip = title
            sidebarButton?.setAccessibilityLabel(title)
            let visible = appState.previewAssetID == nil && !appState.isComparing
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
            let toolbar = NSToolbar(identifier: "Lightbox.WindowHeader")
            toolbar.delegate = self
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

private final class TitlebarInteractionView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else if let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Native toolbar geometry supplies the window controls and their standard behavior.
struct WindowHeaderDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitlebarInteractionView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
