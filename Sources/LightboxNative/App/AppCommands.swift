import SwiftUI

struct LightboxCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject private var updater = LightboxUpdateController.shared

    private var updateMenuTitle: String {
        if case let .available(version) = updater.updateState {
            return "\(appState.localized(.installUpdate))… (\(version))"
        }
        return appState.localized(.checkForUpdates)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updateMenuTitle) {
                Task { await updater.checkForUpdates(appState: appState) }
            }
            .disabled(updater.updateState.isBusy)
        }

        CommandGroup(replacing: .newItem) {
            Button {
                appState.newTab()
            } label: {
                Label(appState.localized(.newTab), systemImage: "plus.rectangle.on.rectangle")
            }
            .keyboardShortcut("t", modifiers: [.command])
        }

        CommandGroup(after: .newItem) {
            Button {
                appState.goBack()
            } label: {
                Label(appState.localized(.goBack), systemImage: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!appState.canGoBack)

            Button {
                appState.goForward()
            } label: {
                Label(appState.localized(.goForward), systemImage: "chevron.right")
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!appState.canGoForward)

            Button {
                appState.openParentFolder()
            } label: {
                Label(appState.localized(.goToParentFolder), systemImage: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!appState.canOpenParentFolder)

            Divider()

            Button {
                appState.focusGoToFolder()
            } label: {
                Label(appState.localized(.goToFolder), systemImage: "folder")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button {
                appState.showsHiddenItems.toggle()
            } label: {
                Label(
                    appState.localized(.showHiddenFiles),
                    systemImage: appState.showsHiddenItems ? "checkmark" : "eye.slash"
                )
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button {
                appState.focusSearch()
            } label: {
                Label(appState.localized(.search), systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(appState.isShowingStartPage)

            Button {
                appState.refreshLibrary()
            } label: {
                Label(appState.localized(.refreshLibrary), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(appState.isShowingStartPage)

            Button {
                appState.sidebarCollapsed.toggle()
            } label: {
                Label(appState.localized(.sidebar), systemImage: "sidebar.left")
            }
            .keyboardShortcut("b", modifiers: [.command])
        }

        CommandMenu(appState.localized(.tabs)) {
            Button {
                appState.closeActiveTab()
            } label: {
                Label(appState.localized(.closeTab), systemImage: "xmark")
            }
            .keyboardShortcut("w", modifiers: [.command])

            Divider()

            Button {
                appState.selectPreviousTab()
            } label: {
                Label(appState.localized(.previousTab), systemImage: "chevron.left.2")
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(appState.tabs.count < 2)

            Button {
                appState.selectNextTab()
            } label: {
                Label(appState.localized(.nextTab), systemImage: "chevron.right.2")
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(appState.tabs.count < 2)

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button {
                    appState.selectTab(atShortcutIndex: index)
                } label: {
                    let tabIndex = index == 9 ? appState.tabs.count - 1 : index - 1
                    Text(appState.tabs.indices.contains(tabIndex) ? appState.tabTitle(appState.tabs[tabIndex]) : "–")
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: [.command])
                .disabled(index == 9 ? appState.tabs.isEmpty : appState.tabs.count < index)
            }
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
            .keyboardShortcut(.delete, modifiers: [.command])
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
