import AppKit
import Quartz

/// The system Quick Look panel, behind a protocol so tests can stand in.
@MainActor
protocol QuickLookPanelDriving: AnyObject {
    var isVisible: Bool { get }
    func open()
    func close()
    func reload()
}

@MainActor
final class SystemQuickLookPanel: QuickLookPanelDriving {
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    func open() { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
    func close() { if isVisible { QLPreviewPanel.shared().orderOut(nil) } }
    func reload() { QLPreviewPanel.shared().reloadData() }
}

/// Shows files in Quick Look. It sits in the window's responder chain, after
/// the window, so the panel finds it as its controller whatever has focus.
/// The panel calls its data source and delegate on the main thread.
@MainActor
final class QuickLookController: NSResponder, @preconcurrency QLPreviewPanelDataSource,
                                 @preconcurrency QLPreviewPanelDelegate {
    private(set) var urls: [URL] = []
    /// Arrow keys pressed in the panel while it shows one file: the gallery
    /// moves its focus and shows the next file, as Finder does.
    var onArrow: (UInt16) -> Void = { _ in }
    private let panel: QuickLookPanelDriving

    init(panel: QuickLookPanelDriving = SystemQuickLookPanel()) {
        self.panel = panel
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isVisible: Bool { panel.isVisible }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        if panel.isVisible { panel.reload() } else { panel.open() }
    }

    func close() {
        panel.close()
    }

    /// Joins `window`'s responder chain once.
    func attach(to window: NSWindow) {
        guard window.nextResponder !== self else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    // MARK: Panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49:
            close()
            return true
        case 123, 124, 125, 126:
            guard urls.count == 1 else { return false }
            onArrow(event.keyCode)
            return true
        default:
            return false
        }
    }
}
