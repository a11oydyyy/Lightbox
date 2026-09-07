import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = LightboxUpdateController.shared
    private var updateState: UpdateState { updater.updateState }

    var body: some View {
        Form {
            Section(appState.localized(.appearance)) {
                Picker(appState.localized(.colorMode), selection: $appState.colorMode) {
                    Text(appState.localized(.system)).tag(LightboxColorMode.system)
                    Text(appState.localized(.light)).tag(LightboxColorMode.light)
                    Text(appState.localized(.dark)).tag(LightboxColorMode.dark)
                }
                .pickerStyle(.segmented)


            }

            Section(appState.localized(.language)) {
                Picker(appState.localized(.language), selection: $appState.appLanguage) {
                    Text(appState.localized(.system)).tag(LightboxLanguage.system)
                    Text(appState.localized(.english)).tag(LightboxLanguage.english)
                    Text(appState.localized(.simplifiedChinese)).tag(LightboxLanguage.simplifiedChinese)
                    Text(appState.localized(.traditionalChinese)).tag(LightboxLanguage.traditionalChinese)
                    Text(appState.localized(.japanese)).tag(LightboxLanguage.japanese)
                }
                .pickerStyle(.menu)
            }

            Section(appState.localized(.sidebar)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(appState.localized(.sidebarWidth))
                        Spacer()
                        Text("\(Int(appState.sidebarWidth.rounded()))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { appState.sidebarWidth },
                            set: { appState.sidebarWidth = $0 }
                        ),
                        in: LightboxSettingsStore.sidebarWidthRange
                    )
                }

                Toggle(appState.localized(.showFolderCards), isOn: $appState.showFolderCards)
                Toggle(appState.localized(.showHiddenFiles), isOn: $appState.showsHiddenItems)

                SidebarLocationToggle(
                    title: appState.localized(.showApplications),
                    locationID: .applications
                )
                SidebarLocationToggle(
                    title: appState.localized(.showDesktop),
                    locationID: .desktop
                )
                SidebarLocationToggle(
                    title: appState.localized(.showDocuments),
                    locationID: .documents
                )
                SidebarLocationToggle(
                    title: appState.localized(.showDownloads),
                    locationID: .downloads
                )
                SidebarLocationToggle(
                    title: appState.localized(.showMovies),
                    locationID: .movies
                )
                SidebarLocationToggle(
                    title: appState.localized(.showMusic),
                    locationID: .music
                )
                SidebarLocationToggle(
                    title: appState.localized(.showPictures),
                    locationID: .pictures
                )
                SidebarLocationToggle(
                    title: appState.localized(.showICloudDrive),
                    locationID: .iCloudDrive
                )
                SidebarLocationToggle(
                    title: appState.localized(.showVolumes),
                    locationID: .volumes
                )
            }

            Section(appState.localized(.about)) {
                HStack(spacing: 14) {
                    SettingsAppIconView()
                        .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lightbox")
                            .font(.system(size: 18, weight: .semibold))

                        Text(appState.localized(.appDescription))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)

                SettingsInfoRow(title: appState.localized(.version), value: appVersion)
                HStack {
                    Text(appState.localized(.github))
                    Spacer()
                    Link("a11oydyyy/Lightbox", destination: LightboxUpdateChecker.repositoryURL)
                }
                HStack {
                    Link(appState.localized(.releaseNotes), destination: LightboxUpdateChecker.releasesURL)
                    Spacer()
                    Link(appState.localized(.reportIssue), destination: LightboxUpdateChecker.issuesURL)
                }
            }

            Section(appState.localized(.updates)) {
                Toggle(appState.localized(.automaticallyCheckUpdates), isOn: $updater.automaticallyChecksForUpdates)
                    .onChange(of: updater.automaticallyChecksForUpdates) { enabled in
                        if enabled { Task { await updater.checkAutomatically(appState: appState) } }
                    }
                Text(appState.localized(.automaticUpdateHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let date = updater.lastChecked {
                    HStack {
                        Text(appState.localized(.lastUpdateCheck))
                        Spacer()
                        Text(date, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsInfoRow(title: appState.localized(.updates), value: updateStatusText)

                Button {
                    Task {
                        await updater.checkForUpdates(appState: appState)
                    }
                } label: {
                    HStack(spacing: 7) {
                        if updateState.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(appState.localized(.checkForUpdates))
                    }
                }
                .disabled(updateState.isBusy)
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(width: 480, height: 660)
        .environment(\.lightboxGlassOpacity, appState.glassOpacity)
        .preferredColorScheme(appState.preferredColorScheme)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        default:
            return "Development"
        }
    }

    private var updateStatusText: String {
        switch updateState {
        case .idle:
            return appState.localized(.githubReleases)
        case .checking:
            return appState.localized(.checkingForUpdates)
        case .downloading:
            return appState.localized(.downloadingUpdate)
        case .installing:
            return appState.localized(.installingUpdate)
        case let .available(version):
            return String(format: appState.localized(.updateAvailableStatus), version)
        case let .upToDate(version):
            return String(format: appState.localized(.alreadyUpToDateStatus), version)
        case .failed:
            return appState.localized(.updateCheckFailed)
        }
    }

}

private struct SidebarLocationToggle: View {
    @EnvironmentObject private var appState: AppState
    var title: String
    var locationID: SidebarLocationID

    private var isVisible: Binding<Bool> {
        Binding(
            get: {
                appState.sidebarVisibleLocationIDs.contains(locationID)
            },
            set: { isOn in
                if isOn {
                    appState.sidebarVisibleLocationIDs.insert(locationID)
                } else {
                    appState.sidebarVisibleLocationIDs.remove(locationID)
                }
            }
        )
    }

    var body: some View {
        // Finder "show these items in the sidebar" style: a checkbox, then a
        // monochrome (label-colored, i.e. black in light mode) symbol, then the
        // name — matching the spacing of Finder's sidebar editor.
        Toggle(isOn: isVisible) {
            HStack(spacing: 6) {
                Image(systemName: locationID.systemImage)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .font(.system(size: 14))
                    .frame(width: 18, alignment: .center)

                Text(title)
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct SettingsInfoRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsAppIconView: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
    }
}
