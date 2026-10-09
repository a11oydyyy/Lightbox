import AppKit
import SwiftUI

struct NewTabView: View {
    @EnvironmentObject private var appState: AppState
    @LightboxViewState private var unavailablePath: String?
    @LightboxViewState private var folderRequestID: UUID?

    private var pinned: [LibrarySource] {
        Array(appState.pinnedSidebarSources.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }.prefix(6))
    }
    private var recent: [URL] {
        Array(appState.recentFolderURLs.filter { url in
            !appState.pinnedSidebarSources.contains { $0.rootURL.standardizedFileURL == url.standardizedFileURL }
        }.prefix(6))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(appState.localized(.startBrowsing))
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(LightboxColorTokens.primaryText)
                        Text(appState.localized(.startBrowsingHint))
                            .font(.system(size: 14))
                            .foregroundStyle(LightboxColorTokens.secondaryText)
                        openFolderButton
                            .padding(.top, 8)
                    }

                    if geometry.size.width >= 700 {
                        HStack(alignment: .top, spacing: 40) {
                            pinnedSection.frame(maxWidth: .infinity, alignment: .topLeading)
                            recentSection.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 30) {
                            pinnedSection
                            recentSection
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, max(92, geometry.size.height * 0.17))
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .alert(appState.localized(.folderUnavailable), isPresented: Binding(
            get: { unavailablePath != nil }, set: { if !$0 { unavailablePath = nil } }
        )) {
            Button(appState.localized(.startOpenFolder)) { unavailablePath = nil; appState.addExternalSource() }
            Button(appState.localized(.cancel), role: .cancel) { unavailablePath = nil }
        } message: {
            Text(unavailablePath ?? "")
        }
        .onDisappear {
            folderRequestID = nil
            appState.cancelPendingFolderPath()
        }
    }

    @ViewBuilder
    private var openFolderButton: some View {
        let button = Button { appState.addExternalSource() } label: {
            Label(appState.localized(.startOpenFolder), systemImage: "folder.badge.plus")
                .foregroundStyle(LightboxColorTokens.accentForeground)
                .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .keyboardShortcut("o", modifiers: .command)
        .help("\(appState.localized(.startOpenFolder)) (⌘O)")
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(appState.localized(.sidebarPinned))
            if pinned.isEmpty {
                emptyText(appState.localized(.noPinnedFolders))
            } else {
                ForEach(pinned) { source in
                    folderRow(source.rootURL, title: source.displayName)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(appState.localized(.recentFolders))
            if recent.isEmpty {
                emptyText(appState.localized(.noRecentFolders))
            } else {
                ForEach(recent, id: \.self) { url in folderRow(url, title: url.lastPathComponent) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LightboxColorTokens.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).font(.system(size: 12))
            .foregroundStyle(LightboxColorTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func folderRow(_ url: URL, title: String) -> some View {
        Button {
            let tabID = appState.activeTabID
            let requestID = UUID()
            folderRequestID = requestID
            Task { @MainActor in
                guard folderRequestID == requestID, !Task.isCancelled else { return }
                let opened = await appState.openFolderPath(url.path)
                guard folderRequestID == requestID, !Task.isCancelled,
                      appState.activeTabID == tabID, appState.isShowingStartPage else { return }
                if opened == .unavailable { unavailablePath = url.path }
            }
        } label: {
            HStack(spacing: 12) {
                SidebarSymbolIcon(symbol: "folder", url: url)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LightboxColorTokens.primaryText)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(LightboxColorTokens.secondaryText)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius)))
        .help(url.path)
    }
}
