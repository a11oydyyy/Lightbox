import AppKit

@main
struct ImageAnalysisPluginApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ImageAnalysisPluginDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ImageAnalysisPluginDelegate: NSObject, NSApplicationDelegate {
    private let panel: ImageAnalysisWindow
    private var selectedURLs: [URL] = []
    private var hasLaunched = false

    override init() {
        let arguments = CommandLine.arguments
        let support: URL
        if let index = arguments.firstIndex(of: "--host-support-directory"), arguments.indices.contains(index + 1) {
            support = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lightbox", isDirectory: true)
        }
        panel = ImageAnalysisWindow(indexURL: support.appendingPathComponent("ImageAnalysis/results.json"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出图片分析", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        hasLaunched = true
        panel.open(urls: selectedURLs)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        selectedURLs = urls.filter(\.isFileURL)
        if hasLaunched { panel.open(urls: selectedURLs) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
