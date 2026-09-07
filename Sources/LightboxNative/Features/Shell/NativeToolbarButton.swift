import AppKit
import SwiftUI

/// An AppKit button hosted inside the native toolbar, with a real mouse target.
struct NativeToolbarButton: NSViewRepresentable {
    var symbol: String
    var title: String
    var isEnabled = true
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func performAction() { action() }
    }
}
