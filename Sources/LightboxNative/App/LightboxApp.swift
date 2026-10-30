import AppKit
import SwiftUI

@main
struct LightboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Lightbox", id: "main") {
            RootShellView()
                .environmentObject(appState)
                .tint(LightboxColorTokens.accent)
                .accentColor(LightboxColorTokens.accent)
                .environment(\.lightboxGlassOpacity, appState.glassOpacity)
                .preferredColorScheme(appState.preferredColorScheme)
                .environment(\.locale, appState.appLanguage.locale)
                .frame(minWidth: 980, minHeight: 680)
                .background(WindowConfigurator(appState: appState))
                .onAppear { appDelegate.appState = appState }
                .task { await LightboxUpdateController.shared.checkAutomatically(appState: appState) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await LightboxUpdateController.shared.checkAutomatically(appState: appState) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            LightboxCommands(appState: appState)
            TextEditingCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .tint(LightboxColorTokens.accent)
                .accentColor(LightboxColorTokens.accent)
                .environment(\.lightboxGlassOpacity, appState.glassOpacity)
                .preferredColorScheme(appState.preferredColorScheme)
                .environment(\.locale, appState.appLanguage.locale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    weak var appState: AppState?

    /// The end of the responder chain: a focused card or text field handles
    /// Select All itself, so this only runs when nothing else would.
    @MainActor @objc func selectAll(_ sender: Any?) {
        appState?.selectAllInGallery()
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectAll(_:)) else { return true }
        return appState?.canSelectAllInGallery == true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LightboxUpdateHealth.isRequested(), !LightboxUpdateHealth.recordLaunch() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
