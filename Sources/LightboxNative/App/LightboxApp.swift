import AppKit
import SwiftUI

@main
struct LightboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(appState)
                .environment(\.lightboxGlassOpacity, appState.glassOpacity)
                .preferredColorScheme(appState.preferredColorScheme)
                .frame(minWidth: 980, minHeight: 680)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            LightboxCommands(appState: appState)
            SidebarCommands()
            TextEditingCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environment(\.lightboxGlassOpacity, appState.glassOpacity)
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
