import AppKit
import QuartzCore

/// Native text and accessibility, with counter motion composited by Core Animation.
@MainActor
final class NativeProgressLabel: NSTextField {
    private struct Token { var text: String; var isNumber: Bool }
    private struct Run {
        var token: Token
        var container: CALayer
        var current: CATextLayer
        var departing: CATextLayer?
    }
    private static let numbers = try! NSRegularExpression(pattern: "[0-9][0-9,]*")
    private var runs: [Run] = []
    private var pendingText: String?
    private var updateTask: Task<Void, Never>?
    private var measuredSize = NSSize.zero
    private(set) var displayedText = ""
    var presentationSizeChanged: (() -> Void)?

    override var font: NSFont? {
        didSet { if font != oldValue { render(animated: false) } }
    }
    override var textColor: NSColor? {
        didSet { if textColor != oldValue { render(animated: false) } }
    }
    override var intrinsicContentSize: NSSize { measuredSize }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        wantsLayer = true
        layer?.isGeometryFlipped = true
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {}
    override func layout() { super.layout(); layoutRuns() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render(animated: false)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render(animated: false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPendingUpdates() }
        else { render(animated: false) }
    }

    func setText(_ text: String, animated: Bool) {
        guard stringValue != text else { return }
        // Accessibility always exposes the latest full value; visual updates coalesce.
        stringValue = text
        toolTip = text
        let samePhase = Self.caption(in: displayedText) == Self.caption(in: text)
        guard animated, samePhase, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancelPendingUpdates()
            return
        }
        pendingText = text
        if updateTask == nil { advance() }
    }
    func cancelPendingUpdates() {
        updateTask?.cancel()
        updateTask = nil
        pendingText = nil
        display(stringValue, animated: false)
        removeDepartingLayers()
        for run in runs { run.current.removeAllAnimations() }
    }
    private func advance() {
        guard let text = pendingText else { return }
        pendingText = nil
        display(text, animated: true)
        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.removeDepartingLayers()
            self.updateTask = nil
            self.advance()
        }
    }
    private func display(_ text: String, animated: Bool) {
        guard displayedText != text else { return }
        displayedText = text
        render(animated: animated)
    }
    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 14, weight: .semibold),
         .foregroundColor: textColor ?? NSColor.labelColor]
    }
    private func textLayer(_ text: String) -> CATextLayer {
        let result = CATextLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var attributes = textAttributes
            attributes[.foregroundColor] = (textColor ?? .labelColor).usingColorSpace(.deviceRGB)
            result.string = NSAttributedString(string: text, attributes: attributes)
        }
        result.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return result
    }
    private func render(animated: Bool) {
        guard let layer else { return }
        let oldTokens = runs.map(\.token)
        let nextTokens = Self.tokens(in: displayedText)
        let nextSize = (displayedText as NSString).size(withAttributes: textAttributes)
        let changedSize = measuredSize != nextSize
        measuredSize = nextSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers = nil
        runs = nextTokens.enumerated().map { index, token in
            let container = CALayer()
            container.masksToBounds = token.isNumber
            let current = textLayer(token.text)
            container.addSublayer(current)
            var departing: CATextLayer?
            if animated, token.isNumber, index < oldTokens.count,
               oldTokens[index].isNumber, oldTokens[index].text != token.text,
               (oldTokens[index].text as NSString).size(withAttributes: textAttributes).width
                <= (token.text as NSString).size(withAttributes: textAttributes).width {
                let old = textLayer(oldTokens[index].text)
                old.opacity = 0
                container.addSublayer(old)
                departing = old
            }
            layer.addSublayer(container)
            return Run(token: token, container: container, current: current, departing: departing)
        }
        layoutRuns()
        if animated {
            for run in runs {
                guard let departing = run.departing else { continue }
                animate(run.current, key: "position.y", from: run.current.position.y + bounds.height * 0.45, to: run.current.position.y)
                animate(run.current, key: "opacity", from: 0, to: 1)
                animate(departing, key: "position.y", from: departing.position.y, to: departing.position.y - bounds.height * 0.45)
                animate(departing, key: "opacity", from: 1, to: 0)
            }
        }
        CATransaction.commit()
        if changedSize { invalidateIntrinsicContentSize(); presentationSizeChanged?() }
    }
    private func layoutRuns() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var prefix = ""
        var x: CGFloat = 0
        for run in runs {
            prefix += run.token.text
            let end = (prefix as NSString).size(withAttributes: textAttributes).width
            run.container.frame = CGRect(x: x, y: 0, width: max(0, end - x), height: bounds.height)
            let size = (run.token.text as NSString).size(withAttributes: textAttributes)
            run.current.frame = CGRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            if let departing = run.departing, let text = departing.string as? NSAttributedString {
                let oldSize = text.size()
                departing.frame = CGRect(x: 0, y: (bounds.height - oldSize.height) / 2, width: oldSize.width, height: oldSize.height)
            }
            x = end
        }
        CATransaction.commit()
    }
    private func animate(_ layer: CALayer, key: String, from: CGFloat, to: CGFloat) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 0.22
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)
        layer.add(animation, forKey: key)
    }
    private func removeDepartingLayers() {
        for index in runs.indices {
            runs[index].departing?.removeFromSuperlayer()
            runs[index].departing = nil
        }
    }
    private static func tokens(in text: String) -> [Token] {
        let string = text as NSString
        var result: [Token] = []
        var start = 0
        for match in numbers.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            if match.range.location > start {
                result.append(Token(text: string.substring(with: NSRange(location: start, length: match.range.location - start)), isNumber: false))
            }
            result.append(Token(text: string.substring(with: match.range), isNumber: true))
            start = NSMaxRange(match.range)
        }
        if start < string.length { result.append(Token(text: string.substring(from: start), isNumber: false)) }
        return result
    }
    private static func caption(in text: String) -> String {
        text.replacingOccurrences(of: "[0-9][0-9,]*", with: "#", options: .regularExpression)
    }
}
