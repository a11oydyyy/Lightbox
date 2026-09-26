import SwiftUI

struct TabContextMenu: View {
    @EnvironmentObject private var appState: AppState
    var tab: LightboxTab

    var body: some View {
        Button(appState.localized(.duplicateTab)) {
            appState.duplicateTab(tab.id)
        }
        Button(appState.localized(tab.isPinned ? .unpinTab : .pinTab)) {
            appState.toggleTabPinned(tab.id)
        }

        if !tab.isStartPage {
            Divider()
            Button(appState.localized(.showInFinder)) {
                appState.revealTabInFinder(tab.id)
            }
            Button(appState.localized(.copyPath)) {
                appState.copyTabPathToClipboard(tab.id)
            }
        }

        Divider()
        Button(appState.localized(.closeTab)) {
            appState.closeTab(tab.id)
        }
        Button(appState.localized(.closeOtherTabs)) {
            appState.closeOtherTabs(keeping: tab.id)
        }
        .disabled(!appState.canCloseOtherTabs(keeping: tab.id))
        Button(appState.localized(.closeFollowingTabs)) {
            appState.closeTabsAfter(tab.id)
        }
        .disabled(!appState.canCloseTabsAfter(tab.id))
    }
}
