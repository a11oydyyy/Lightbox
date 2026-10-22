import AppKit
import QuartzCore
import SwiftUI

/// A borderless titlebar button with the shared hover and press fill. Keyboard
/// navigation gets a quiet marker; mouse clicks keep the borderless style.
final class HeaderIconButton: NSButton {
    private var showsKeyboardFocus = false
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = LightboxControlMetrics.cornerRadius
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateFeedback() {
        guard let layer else { return }
        let opacity = !isEnabled || window?.isKeyWindow != true ? 0
            : isHighlighted ? LightboxControlMetrics.pressedOpacity
            : isHovered ? LightboxControlMetrics.hoverOpacity : 0
        let target = NSColor(LightboxColorTokens.primaryText).withAlphaComponent(opacity).cgColor
        guard layer.backgroundColor != target else { return }
        let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "feedback")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = previous ?? NSColor.clear.cgColor
        fade.toValue = target
        fade.duration = MotionTokens.feedbackDurationSeconds
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "feedback")
    }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        showsKeyboardFocus = false
        needsDisplay = true
        return super.resignFirstResponder()
    }
    override func draw(_ dirtyRect: NSRect) {
        updateFeedback()
        super.draw(dirtyRect)
        guard showsKeyboardFocus, window?.firstResponder === self else { return }
        NSColor(LightboxColorTokens.secondaryText).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 5, y: 2))
        line.line(to: NSPoint(x: bounds.width - 5, y: 2))
        line.lineWidth = LightboxControlMetrics.focusLineWidth
        line.stroke()
    }
}
