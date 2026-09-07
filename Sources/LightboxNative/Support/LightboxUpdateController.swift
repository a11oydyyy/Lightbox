import AppKit
import SwiftUI

/// One update operation for settings, application menus, and background checks.
@MainActor
final class LightboxUpdateController: ObservableObject {
    static let shared = LightboxUpdateController()
    static let automaticKey = "Lightbox.automaticallyChecksForUpdates"
    static let lastAttemptKey = "Lightbox.lastAutomaticUpdateAttempt"
    static let availableVersionKey = "Lightbox.availableUpdateVersion"
    static let lastCheckedKey = "Lightbox.lastUpdateCheck"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let fetchRelease: @Sendable () async throws -> LightboxUpdateChecker.CheckResult
    private var operationInProgress = false
    @Published private(set) var updateState = UpdateState.idle
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { defaults.set(automaticallyChecksForUpdates, forKey: Self.automaticKey) }
    }

    init(
        defaults: UserDefaults = .standard,
        fetchRelease: @escaping @Sendable () async throws -> LightboxUpdateChecker.CheckResult = {
            try await LightboxUpdateChecker.checkLatestRelease()
        }
    ) {
        self.defaults = defaults
        self.fetchRelease = fetchRelease
        automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        if let version = defaults.string(forKey: Self.availableVersionKey),
           LightboxUpdateChecker.isVersion(version, newerThan: LightboxUpdateChecker.currentAppVersion) {
            updateState = .available(version)
        }
    }

    static func shouldCheckAutomatically(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        let interval = now.timeIntervalSince(lastAttempt)
        return interval >= checkInterval || interval < 0
    }

    func checkAutomatically(appState: AppState) async {
        guard !operationInProgress, !updateState.isBusy,
              Self.shouldCheckAutomatically(
                enabled: automaticallyChecksForUpdates,
                lastAttempt: defaults.object(forKey: Self.lastAttemptKey) as? Date,
                now: Date()
              ) else { return }
        defaults.set(Date(), forKey: Self.lastAttemptKey)
        await checkForUpdates(appState: appState, automatic: true)
    }

    func checkForUpdates(appState: AppState, automatic: Bool = false) async {
        guard !operationInProgress, !updateState.isBusy else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        updateState = .checking

        do {
            let result = try await fetchRelease()
            if automatic && !automaticallyChecksForUpdates { updateState = .idle; return }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
            switch result {
            case let .updateAvailable(version, _, assetURL, digest):
                defaults.set(version, forKey: Self.availableVersionKey)
                updateState = .available(version)
                guard !automatic, confirmUpdateInstall(version: version, appState: appState) else { return }
                await installUpdate(
                    appState: appState,
                    from: assetURL,
                    expectedDigest: digest,
                    expectedVersion: version
                )
            case let .upToDate(version, _):
                defaults.removeObject(forKey: Self.availableVersionKey)
                updateState = .upToDate(version)
                guard !automatic else { return }
                showInfoAlert(
                    appState: appState,
                    title: appState.localized(.alreadyUpToDate),
                    message: String(format: appState.localized(.alreadyUpToDateMessage), version)
                )
            }
        } catch {
            updateState = .failed
            guard !automatic else { return }
            showInfoAlert(
                appState: appState,
                title: appState.localized(.updateCheckFailed),
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func installUpdate(
        appState: AppState,
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
                appState: appState,
                title: appState.localized(.updateCheckFailed),
                message: error.localizedDescription
            )
        }
    }

    private func confirmUpdateInstall(version: String, appState: AppState) -> Bool {
        let alert = NSAlert()
        alert.messageText = appState.localized(.updateAvailable)
        alert.informativeText = String(format: appState.localized(.updateAvailableMessage), version)
        alert.addButton(withTitle: appState.localized(.installUpdate))
        alert.addButton(withTitle: appState.localized(.close))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showInfoAlert(appState: AppState, title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: appState.localized(.close))
        alert.runModal()
    }
}

enum UpdateState: Equatable {
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
