import SwiftUI

struct LightboxCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button {
                appState.refreshLibrary()
            } label: {
                Label(appState.localized(.refreshLibrary), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button {
                appState.sidebarCollapsed.toggle()
            } label: {
                Label(appState.localized(.sidebar), systemImage: "sidebar.left")
            }
            .keyboardShortcut("b", modifiers: [.command])
        }

        CommandMenu(appState.localized(.assetMenu)) {
            Button {
                appState.showComparisonFromSelection()
            } label: {
                Label(appState.localized(.compareSelection), systemImage: "rectangle.split.2x1")
            }
            .disabled(appState.selectedAssetCount < 2)

            Button {
                appState.closeActiveOverlay()
            } label: {
                Label(appState.localized(.close), systemImage: "xmark")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!appState.hasActiveOverlay)

            Divider()

            Button {
                appState.deleteSelectedAssets()
            } label: {
                Label(appState.localized(.moveToTrash), systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!appState.canMoveSelectionToTrash)

            Button {
                if let asset = appState.explicitlySelectedAsset {
                    appState.revealInFinder(asset)
                }
            } label: {
                Label(appState.localized(.showInFinder), systemImage: "finder")
            }
            .disabled(appState.explicitlySelectedAsset?.sourceURL == nil)
        }
    }
}
