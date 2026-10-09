import AppKit
import SwiftUI

/// Keep the sidebar's layout and focus graph resident and independent of gallery
/// viewport updates. Its existing model subscriptions still handle navigation.
struct ResidentSidebarHost: NSViewRepresentable {
    var appState: AppState

    func makeNSView(context: Context) -> NSHostingView<SidebarHostedContent> {
        let host = NSHostingView(rootView: SidebarHostedContent(appState: appState))
        host.sizingOptions = []
        if #available(macOS 14, *) {
            host.clipsToBounds = false
            // The panel runs under the transparent titlebar so the window
            // controls sit inside it, as in Finder; it reserves that band itself.
            host.safeAreaRegions = []
        }
        return host
    }

    func updateNSView(_ host: NSHostingView<SidebarHostedContent>, context: Context) {
        // Do not replace the root on every gallery update: that would invalidate
        // the independent graph and its row focus state again.
        if host.rootView.appState !== appState {
            host.rootView = SidebarHostedContent(appState: appState)
        }
    }
}

struct SidebarHostedContent: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GlassSidebar(navigation: appState.sidebarNavigation)
            .environmentObject(appState)
            .environment(\.lightboxGlassOpacity, appState.glassOpacity)
            .environment(\.locale, appState.appLanguage.locale)
            .preferredColorScheme(appState.preferredColorScheme)
            // Reveal normal text through the veil, without a disabled-color jump.
            .disabled((appState.hasActiveOverlay && !appState.isPreviewClosing) || appState.sidebarCollapsed)
            .allowsHitTesting(!appState.hasActiveOverlay && !appState.sidebarCollapsed)
            .accessibilityHidden(appState.hasActiveOverlay || appState.sidebarCollapsed)
    }
}
