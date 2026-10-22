import SwiftUI

struct LightboxCommands: Commands {
    @ObservedObject var appState: AppState
    /// Selection publishes here rather than on `appState`; the Compare, Move to
    /// Trash and Show in Finder items depend on it.
    @ObservedObject private var selection: GallerySelectionState
    @ObservedObject private var updater = LightboxUpdateController.shared

    init(appState: AppState) {
        self.appState = appState
        selection = appState.selection
    }

    private var updateMenuTitle: String {
        if case let .available(version) = updater.updateState {
            return "\(appState.localized(.installUpdate))… (\(version))"
        }
        return appState.localized(.checkForUpdates)
    }

    private var goMenuTitle: String {
        switch appState.appLanguage.resolved {
        case .english: "Go"
        case .simplifiedChinese, .traditionalChinese: "前往"
        case .japanese: "移動"
        }
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

            Button {
                appState.beginNewFolder()
            } label: {
                Label(appState.renameText.newFolderMenuItem, systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!appState.canCreateFolder)
        }

        // File: what makes something new, and finding.
        CommandGroup(after: .newItem) {
            Button {
                appState.focusSearch()
            } label: {
                Label(appState.localized(.search), systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(appState.isShowingStartPage)
        }

        // View: how the folder is shown, as Finder's View menu.
        CommandGroup(before: .toolbar) {
            Button {
                appState.galleryViewMode = .grid
            } label: {
                Label(FileListText(appState.appLanguage).asGrid,
                      systemImage: appState.galleryViewMode == .grid ? "checkmark" : "square.grid.2x2")
            }
            .keyboardShortcut("1", modifiers: [.command, .control])

            Button {
                appState.galleryViewMode = .list
            } label: {
                Label(FileListText(appState.appLanguage).asList,
                      systemImage: appState.galleryViewMode == .list ? "checkmark" : "rectangle.grid.1x2")
            }
            .keyboardShortcut("2", modifiers: [.command, .control])

            Divider()

            // Whole columns, as the size slider's end dots.
            Button(FilterText(appState.appLanguage).fewerColumns) {
                withAnimation(MotionTokens.thumbnailScale) { _ = appState.stepThumbnailColumns(by: -1) }
            }
            .keyboardShortcut("=", modifiers: [.command])
            .disabled(appState.galleryViewMode == .list || appState.isShowingStartPage || appState.hasActiveOverlay)

            Button(FilterText(appState.appLanguage).moreColumns) {
                withAnimation(MotionTokens.thumbnailScale) { _ = appState.stepThumbnailColumns(by: 1) }
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(appState.galleryViewMode == .list || appState.isShowingStartPage || appState.hasActiveOverlay)

            Divider()

            // The grid's scope; the list shows one folder.
            Button {
                appState.galleryLayoutMode = appState.galleryLayoutMode.next
            } label: {
                Label(appState.localized(.includeSubfolders),
                      systemImage: appState.galleryLayoutMode == .recursive ? "checkmark" : "square.stack.3d.up")
            }
            .disabled(appState.galleryViewMode == .list || appState.isViewingTrash || appState.isShowingStartPage)

            Button {
                appState.showsHiddenItems.toggle()
            } label: {
                Label(
                    appState.localized(.showHiddenFiles),
                    systemImage: appState.showsHiddenItems ? "checkmark" : "eye.slash"
                )
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button {
                appState.showsOtherFiles.toggle()
            } label: {
                Label(
                    appState.localized(.showOtherFiles),
                    systemImage: appState.showsOtherFiles ? "checkmark" : "doc"
                )
            }

            Divider()

            Button {
                appState.showsAttributeFilterPanel.toggle()
            } label: {
                Label(FilterText(appState.appLanguage).menuTitle, systemImage: "line.3.horizontal.decrease")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(appState.isShowingStartPage)

            Button {
                appState.attributeFilter = GalleryAttributeFilter()
            } label: {
                Label(FilterText(appState.appLanguage).clear, systemImage: "xmark.circle")
            }
            .disabled(!appState.attributeFilter.isActive)

            Divider()

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
                Label(appState.localized(appState.sidebarCollapsed ? .openSidebar : .closeSidebar), systemImage: "sidebar.left")
            }
            .keyboardShortcut("b", modifiers: [.command])

            Divider()
        }

        // Go: moving between folders, as Finder's Go menu.
        CommandMenu(goMenuTitle) {
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
            .disabled(!appState.canCompareSelection)

            Button {
                appState.toggleQuickLook()
            } label: {
                Label(appState.localized(.quickLook), systemImage: "eye")
            }
            .keyboardShortcut("y", modifiers: [.command])
            .disabled(!appState.canQuickLook && !appState.quickLook.isVisible)

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
                appState.beginRename()
            } label: {
                Label(appState.renameText.menuItem, systemImage: "pencil")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!appState.canRename)

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
