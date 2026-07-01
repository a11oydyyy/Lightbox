import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.configureIfNeeded(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configureIfNeeded(from: nsView)
    }

    @MainActor
    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var pendingConfigure = false

        func configureIfNeeded(from view: NSView) {
            guard let window = view.window else {
                scheduleConfigure(from: view)
                return
            }

            guard configuredWindow !== window else { return }
            configuredWindow = window
            Self.configure(window: window)
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

        private static func configure(window: NSWindow) {
            window.title = "Lightbox"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unifiedCompact
            window.minSize = NSSize(width: 980, height: 680)
            window.backgroundColor = .clear
            installTitlebarInteractionZone(in: window)
        }

        private static func installTitlebarInteractionZone(in window: NSWindow) {
            guard let titlebarView = window.standardWindowButton(.closeButton)?.superview,
                  titlebarView.subviews.contains(where: { $0 is TitlebarInteractionView }) == false
            else {
                return
            }

            let interactionView = TitlebarInteractionView()
            interactionView.translatesAutoresizingMaskIntoConstraints = false
            titlebarView.addSubview(interactionView)

            NSLayoutConstraint.activate([
                interactionView.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor, constant: 220),
                interactionView.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
                interactionView.topAnchor.constraint(equalTo: titlebarView.topAnchor),
                interactionView.bottomAnchor.constraint(equalTo: titlebarView.bottomAnchor)
            ])
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
