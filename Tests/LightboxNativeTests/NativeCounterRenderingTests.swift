import AppKit
import QuartzCore
import Testing
@testable import LightboxNative

@Test @MainActor func nativeCounterDrawsFullTextAndCancelsActiveAnimationWithoutPendingValue() throws {
    let label = NativeProgressLabel()
    label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    label.textColor = .labelColor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 23),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = label
    defer { window.close() }
    let text = "正在扫描子文件夹… 已找到 4,003 张 · 已扫描 6,006 项"
    label.setText(text, animated: false)
    window.contentView?.layoutSubtreeIfNeeded()
    let size = (text as NSString).size(withAttributes: [.font: try #require(label.font)])
    #expect(abs(label.intrinsicContentSize.width - size.width) < 0.01)
    #expect(label.stringValue == text && label.toolTip == text)
    let root = try #require(label.layer)
    func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
    let textLayers = layers(root).compactMap { $0 as? CATextLayer }
    #expect(textLayers.count == 5)
    #expect(textLayers.allSatisfy {
        ($0.string as? NSAttributedString)?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == label.font
    })
    // Both appearances must resolve dynamic label color and produce actual glyph pixels.
    var luminances: [Double] = []
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        label.appearance = NSAppearance(named: appearance)
        label.viewDidChangeEffectiveAppearance()
        let width = Int(ceil(size.width * 2)) + 4
        let height = 46
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 2, y: -2)
        root.render(in: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let visible = (0..<(width * height)).filter { bytes[$0 * 4 + 3] > 32 }
        #expect(visible.count > 100)
        #expect(visible.contains { $0 % width > width - 70 })
        luminances.append(visible.reduce(0.0) { sum, pixel in
            let offset = pixel * 4
            let rgb = Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])
            return sum + rgb / (3 * Double(bytes[offset + 3]))
        } / Double(max(1, visible.count)))
        if let output = ProcessInfo.processInfo.environment["LIGHTBOX_TEST_ARTIFACTS"] {
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("counter-\(appearance.rawValue).png"))
        }
    }
    #expect(luminances[1] > luminances[0] + 0.5)
    label.setText("Scanning 1", animated: false)
    label.setText("Scanning 111", animated: true)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        #expect(layers(root).contains { !($0.animationKeys() ?? []).isEmpty })
    }
    label.cancelPendingUpdates()
    #expect(label.displayedText == "Scanning 111")
    #expect(layers(root).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    label.setText("Scanning 1", animated: true)
    label.cancelPendingUpdates()
    #expect(label.displayedText == "Scanning 1")
}
