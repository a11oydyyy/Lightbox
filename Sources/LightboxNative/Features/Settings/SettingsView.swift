import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(LightboxGlowColor.modeKey) private var glowModeRaw = LightboxGlowColor.systemMode
    @AppStorage(LightboxGlowColor.hexKey) private var glowHex = ""
    @State private var customGlowColor = Color.accentColor
    @State private var updateState = UpdateState.idle

    private var opacityPercent: Int {
        Int((appState.glassOpacity * 100).rounded())
    }

    var body: some View {
        Form {
            Section(appState.localized(.appearance)) {
                Picker(appState.localized(.colorMode), selection: $appState.colorMode) {
                    Text(appState.localized(.system)).tag(LightboxColorMode.system)
                    Text(appState.localized(.light)).tag(LightboxColorMode.light)
                    Text(appState.localized(.dark)).tag(LightboxColorMode.dark)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(appState.localized(.liquidGlassOpacity))
                        Spacer()
                        Text("\(opacityPercent)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { appState.glassOpacity },
                            set: { appState.glassOpacity = $0 }
                        ),
                        in: LightboxSettingsStore.glassOpacityRange
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.localized(.hoverGlow))

                    Picker(appState.localized(.hoverGlow), selection: $glowModeRaw) {
                        Text(appState.localized(.system)).tag(LightboxGlowColor.systemMode)
                        Text(appState.localized(.custom)).tag(LightboxGlowColor.customMode)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if glowModeRaw == LightboxGlowColor.customMode {
                        HStack {
                            Text(appState.localized(.customColor))
                                .foregroundStyle(.secondary)
                            Spacer()
                            ColorPicker("", selection: $customGlowColor, supportsOpacity: false)
                                .labelsHidden()
                                .onAppear {
                                    syncCustomGlowColorFromStorage()
                                }
                                .onChange(of: customGlowColor) { color in
                                    glowHex = LightboxGlowColor.hex(from: color)
                                }
                                .onChange(of: glowModeRaw) { mode in
                                    if mode == LightboxGlowColor.customMode {
                                        syncCustomGlowColorFromStorage()
                                    }
                                }
                        }
                    }
                }
            }

            Section(appState.localized(.language)) {
                Picker(appState.localized(.language), selection: $appState.appLanguage) {
                    Text(appState.localized(.system)).tag(LightboxLanguage.system)
                    Text(appState.localized(.english)).tag(LightboxLanguage.english)
                    Text(appState.localized(.simplifiedChinese)).tag(LightboxLanguage.simplifiedChinese)
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
                SettingsInfoRow(title: appState.localized(.github), value: appState.localized(.githubReserved))
                SettingsInfoRow(title: appState.localized(.updates), value: updateStatusText)

                Button {
                    Task {
                        await checkForUpdates()
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
        .frame(width: 440)
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

    private func syncCustomGlowColorFromStorage() {
        customGlowColor = LightboxGlowColor.color(fromHex: glowHex) ?? .accentColor
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

    @MainActor
    private func checkForUpdates() async {
        updateState = .checking

        do {
            let result = try await LightboxUpdateChecker.checkLatestRelease()
            switch result {
            case let .updateAvailable(version, _, assetURL, digest):
                updateState = .available(version)
                guard confirmUpdateInstall(version: version) else { return }
                await installUpdate(
                    from: assetURL,
                    expectedDigest: digest,
                    expectedVersion: version
                )
            case let .upToDate(version, _):
                updateState = .upToDate(version)
                showInfoAlert(
                    title: appState.localized(.alreadyUpToDate),
                    message: String(format: appState.localized(.alreadyUpToDateMessage), version)
                )
            }
        } catch {
            updateState = .failed
            showInfoAlert(
                title: appState.localized(.updateCheckFailed),
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func installUpdate(
        from assetURL: URL,
        expectedDigest: String,
        expectedVersion: String
    ) async {
        do {
            updateState = .downloading
            let stagedAppURL = try await LightboxUpdateInstaller.prepareUpdate(
                from: assetURL,
                expectedDigest: expectedDigest
            )
            updateState = .installing
            try LightboxUpdateInstaller.installPreparedUpdate(
                stagedAppURL,
                expectedVersion: expectedVersion
            )
            NSApplication.shared.terminate(nil)
        } catch {
            updateState = .failed
            showInfoAlert(
                title: appState.localized(.updateCheckFailed),
                message: error.localizedDescription
            )
        }
    }

    private func confirmUpdateInstall(version: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = appState.localized(.updateAvailable)
        alert.informativeText = String(format: appState.localized(.updateAvailableMessage), version)
        alert.addButton(withTitle: appState.localized(.installUpdate))
        alert.addButton(withTitle: appState.localized(.close))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: appState.localized(.close))
        alert.runModal()
    }
}

private enum UpdateState: Equatable {
    case idle
    case checking
    case downloading
    case installing
    case available(String)
    case upToDate(String)
    case failed

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        case .idle, .available, .upToDate, .failed:
            return false
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
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.32), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
    }
}
