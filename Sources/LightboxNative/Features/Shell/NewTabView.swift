import AppKit
import SwiftUI

struct NewTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var unavailablePath: String?

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
                        HStack(spacing: 12) {
                            Button { appState.addExternalSource() } label: {
                                Label(appState.localized(.startOpenFolder), systemImage: "folder.badge.plus")
                                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LightboxColorTokens.accent)
                            .keyboardShortcut("o", modifiers: .command)
                            Text("⌘O")
                                .font(.system(size: 12))
                                .foregroundStyle(LightboxColorTokens.mutedText)
                                .accessibilityHidden(true)
                        }
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
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                unavailablePath = url.path
                return
            }
            appState.openSidebarFolder(url)
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
