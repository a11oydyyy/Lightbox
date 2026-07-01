import AppKit
import Foundation

enum LightboxClickTrigger: String {
    case mouseDown = "mouse-down"
    case mouseUp = "mouse-up"
}

struct LightboxClickContext {
    var trigger: LightboxClickTrigger
    var modifierFlags: NSEvent.ModifierFlags
    var windowLocation: CGPoint
    var windowSize: CGSize
    var localLocation: CGPoint
    var bounds: CGRect

    @MainActor
    init(event: NSEvent, in view: NSView, trigger: LightboxClickTrigger) {
        self.trigger = trigger
        modifierFlags = event.modifierFlags
        windowLocation = event.locationInWindow
        windowSize = view.window?.contentView?.bounds.size ?? view.bounds.size
        localLocation = view.convert(event.locationInWindow, from: nil)
        bounds = view.bounds
    }

    var localTopLeftLocation: CGPoint {
        CGPoint(x: localLocation.x, y: bounds.height - localLocation.y)
    }

    var windowTopLeftLocation: CGPoint {
        CGPoint(x: windowLocation.x, y: windowSize.height - windowLocation.y)
    }

    func mappedTopLeftPoint(in frame: CGRect?) -> CGPoint? {
        guard let frame,
              bounds.width > 0,
              bounds.height > 0
        else {
            return nil
        }

        let topLeft = localTopLeftLocation
        return CGPoint(
            x: frame.minX + (topLeft.x / bounds.width) * frame.width,
            y: frame.minY + (topLeft.y / bounds.height) * frame.height
        )
    }
}

enum LightboxClickFormatter {
    static func describe(_ click: LightboxClickContext?, previewSpacePoint: CGPoint? = nil) -> String {
        guard let click else { return "click=nil" }
        return [
            "trigger=\(click.trigger.rawValue)",
            "mods=\(modifierDescription(click.modifierFlags))",
            "window=\(pointDescription(click.windowLocation))",
            "windowTopLeft=\(pointDescription(click.windowTopLeftLocation))",
            "local=\(pointDescription(click.localLocation))",
            "localTopLeft=\(pointDescription(click.localTopLeftLocation))",
            "bounds=\(frameDescription(click.bounds))",
            "previewPoint=\(pointDescription(previewSpacePoint))"
        ].joined(separator: " ")
    }

    static func pointDescription(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "x=%.1f,y=%.1f", point.x, point.y)
    }

    static func frameDescription(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return String(format: "x=%.1f,y=%.1f,w=%.1f,h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
    }

    private static func modifierDescription(_ modifiers: NSEvent.ModifierFlags) -> String {
        var labels: [String] = []
        if modifiers.contains(.command) { labels.append("cmd") }
        if modifiers.contains(.shift) { labels.append("shift") }
        if modifiers.contains(.option) { labels.append("opt") }
        if modifiers.contains(.control) { labels.append("ctrl") }
        return labels.isEmpty ? "none" : labels.joined(separator: "+")
    }
}
