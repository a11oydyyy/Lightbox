import CryptoKit
import Foundation

enum LightboxUpdateChecker {
    static let repositoryURL = URL(string: "https://github.com/a11oydyyy/Lightbox")!
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/a11oydyyy/Lightbox/releases/latest")!

    struct Release: Decodable {
        var tagName: String
        var htmlURL: URL
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: URL
        var digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    enum CheckResult: Equatable {
        case updateAvailable(version: String, releaseURL: URL, assetURL: URL, digest: String)
        case upToDate(version: String, releaseURL: URL)
    }

    static func checkLatestRelease(
        currentVersion: String = currentAppVersion,
        compatibility: Bool = LightboxRuntime.isCompatibilityApp
    ) async throws -> CheckResult {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lightbox/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw UpdateError.unavailable
        }

        return try checkResult(from: data, currentVersion: currentVersion, compatibility: compatibility)
    }

    static func checkResult(from data: Data, currentVersion: String, compatibility: Bool) throws -> CheckResult {
        let release = try JSONDecoder().decode(Release.self, from: data)
        let latestVersion = normalizedVersion(release.tagName)

        guard isVersion(latestVersion, newerThan: currentVersion) else {
            return .upToDate(version: latestVersion, releaseURL: release.htmlURL)
        }
        guard let asset = preferredAsset(in: release, compatibility: compatibility) else {
            throw UpdateError.compatibleAssetMissing
        }
        guard let digest = asset.digest, !digest.isEmpty else {
            throw UpdateError.assetDigestMissing
        }

        return .updateAvailable(
            version: latestVersion,
            releaseURL: release.htmlURL,
            assetURL: asset.browserDownloadURL,
            digest: digest
        )
    }

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func preferredAsset(in release: Release, compatibility: Bool) -> Asset? {
        let version = normalizedVersion(release.tagName)
        let expectedName = compatibility
            ? "Lightbox-Intel-x86-v\(version).zip"
            : "Lightbox-v\(version).zip"
        return release.assets.first { asset in
            asset.name.caseInsensitiveCompare(expectedName) == .orderedSame
        }
    }

    static func isVersion(_ latestVersion: String, newerThan currentVersion: String) -> Bool {
        compareVersions(latestVersion, currentVersion) == .orderedDescending
    }

    static func normalizedVersion(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = versionParts(lhs)
        let rhsParts = versionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }

        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split { !$0.isNumber }
            .map { Int($0) ?? 0 }
    }
}

enum LightboxUpdateInstaller {
    static func prepareUpdate(from assetURL: URL, expectedDigest: String) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: assetURL)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw UpdateInstallError.downloadFailed
        }

        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("LightboxUpdate-\(UUID().uuidString)", isDirectory: true)
        let zipURL = rootURL.appendingPathComponent("update.zip")
        let unzipURL = rootURL.appendingPathComponent("unzipped", isDirectory: true)
        var prepared = false
        defer {
            if !prepared {
                try? fileManager.removeItem(at: rootURL)
            }
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.moveItem(at: downloadedURL, to: zipURL)
        try validateDigest(of: zipURL, expectedDigest: expectedDigest)
        try fileManager.createDirectory(at: unzipURL, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, unzipURL.path])

        guard let extractedAppURL = try findAppBundle(in: unzipURL) else {
            throw UpdateInstallError.appBundleMissing
        }
        let stagedAppURL = rootURL.appendingPathComponent("Lightbox.app", isDirectory: true)
        try fileManager.moveItem(at: extractedAppURL, to: stagedAppURL)
        prepared = true
        return stagedAppURL
    }

    static func installPreparedUpdate(_ stagedAppURL: URL, expectedVersion: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightboxInstall-\(UUID().uuidString).sh")
        do {
            let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
            guard currentAppURL.pathExtension == "app" else {
                throw UpdateInstallError.currentAppBundleMissing
            }
            try validateBundleMetadata(
                for: stagedAppURL,
                currentBundleIdentifier: Bundle.main.bundleIdentifier,
                expectedVersion: expectedVersion
            )
            try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagedAppURL.path])

            let processID = String(ProcessInfo.processInfo.processIdentifier)
            let script = installScript

            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path, currentAppURL.path, stagedAppURL.path, processID]
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: stagedAppURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
        }
    }

    static let installScript = """
        #!/bin/sh
        set -eu

        CURRENT_APP="$1"
        STAGED_APP="$2"
        CURRENT_PID="$3"
        STAGING_ROOT="$(dirname "$STAGED_APP")"
        BACKUP_APP="${CURRENT_APP}.old-${CURRENT_PID}-$(date +%s)"
        HEALTH_MARKER="$STAGING_ROOT/launch-healthy"
        HEALTH_ATTEMPTS="${4:-60}"
        HEALTH_INTERVAL="${5:-0.25}"
        INSTALL_SUCCEEDED=0
        NEW_APP_PID=""

        terminate_new_app() {
          if [ -n "$NEW_APP_PID" ] && /bin/kill -0 "$NEW_APP_PID" 2>/dev/null; then
            /bin/kill -TERM "$NEW_APP_PID" 2>/dev/null || true
            (
              /bin/sleep 1
              /bin/kill -KILL "$NEW_APP_PID" 2>/dev/null || true
            ) &
            FORCE_KILL_PID=$!
            wait "$NEW_APP_PID" 2>/dev/null || true
            /bin/kill -TERM "$FORCE_KILL_PID" 2>/dev/null || true
            wait "$FORCE_KILL_PID" 2>/dev/null || true
          elif [ -n "$NEW_APP_PID" ]; then
            wait "$NEW_APP_PID" 2>/dev/null || true
          fi
          NEW_APP_PID=""
        }

        finish_install() {
          STATUS=$?
          trap - EXIT HUP INT TERM
          if [ "$INSTALL_SUCCEEDED" -eq 0 ]; then
            terminate_new_app
          fi
          if [ "$INSTALL_SUCCEEDED" -eq 0 ] && [ -e "$BACKUP_APP" ]; then
            /bin/rm -rf "$CURRENT_APP"
            if /bin/mv "$BACKUP_APP" "$CURRENT_APP"; then
              /bin/rm -rf "$STAGING_ROOT"
              /usr/bin/open -n "$CURRENT_APP" >/dev/null 2>&1 || true
            fi
          elif [ "$INSTALL_SUCCEEDED" -eq 0 ]; then
            /bin/rm -rf "$STAGING_ROOT"
          elif [ "$INSTALL_SUCCEEDED" -eq 1 ]; then
            /bin/rm -rf "$BACKUP_APP" "$STAGING_ROOT"
          fi
          /bin/rm -f "$0"
          exit "$STATUS"
        }
        trap finish_install EXIT HUP INT TERM

        while /bin/kill -0 "$CURRENT_PID" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if [ -e "$CURRENT_APP" ]; then
          /bin/mv "$CURRENT_APP" "$BACKUP_APP"
        fi

        /usr/bin/ditto "$STAGED_APP" "$CURRENT_APP"
        /bin/rm -f "$HEALTH_MARKER"
        NEW_APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CURRENT_APP/Contents/Info.plist")"
        case "$NEW_APP_EXECUTABLE_NAME" in
          ""|*/*) exit 1 ;;
        esac
        NEW_APP_EXECUTABLE="$CURRENT_APP/Contents/MacOS/$NEW_APP_EXECUTABLE_NAME"
        [ -x "$NEW_APP_EXECUTABLE" ]
        "$NEW_APP_EXECUTABLE" --lightbox-update-health-marker "$HEALTH_MARKER" >/dev/null 2>&1 &
        NEW_APP_PID=$!

        ATTEMPTS=0
        while [ ! -f "$HEALTH_MARKER" ] && [ "$ATTEMPTS" -lt "$HEALTH_ATTEMPTS" ]; do
          /bin/sleep "$HEALTH_INTERVAL"
          ATTEMPTS=$((ATTEMPTS + 1))
        done
        [ -f "$HEALTH_MARKER" ]
        INSTALL_SUCCEEDED=1
        """

    static func validateDigest(of fileURL: URL, expectedDigest: String) throws {
        let prefix = "sha256:"
        guard expectedDigest.lowercased().hasPrefix(prefix) else {
            throw UpdateInstallError.invalidDigest
        }
        let expectedHash = String(expectedDigest.dropFirst(prefix.count)).lowercased()
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard expectedHash.count == 64,
              expectedHash.unicodeScalars.allSatisfy(hexCharacters.contains)
        else {
            throw UpdateInstallError.invalidDigest
        }

        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let actualHash = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard actualHash == expectedHash else {
            throw UpdateInstallError.digestMismatch
        }
    }

    private static func findAppBundle(in directory: URL) throws -> URL? {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        if let appURL = contents.first(where: { $0.pathExtension == "app" }) {
            return appURL
        }

        for child in contents {
            let resourceValues = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else { continue }
            if let appURL = try findAppBundle(in: child) {
                return appURL
            }
        }

        return nil
    }

    static func validateBundleMetadata(
        for stagedAppURL: URL,
        currentBundleIdentifier: String?,
        expectedVersion: String
    ) throws {
        guard let stagedBundle = Bundle(url: stagedAppURL),
              let stagedBundleIdentifier = stagedBundle.bundleIdentifier,
              let currentBundleIdentifier,
              stagedBundleIdentifier == currentBundleIdentifier
        else {
            throw UpdateInstallError.bundleIdentifierMismatch
        }
        guard let stagedVersion = stagedBundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              LightboxUpdateChecker.normalizedVersion(stagedVersion)
                == LightboxUpdateChecker.normalizedVersion(expectedVersion)
        else {
            throw UpdateInstallError.appVersionMismatch
        }
    }

    private static func run(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "command failed"
            throw UpdateInstallError.toolFailed(message)
        }
    }
}

enum LightboxUpdateHealth {
    static let markerArgument = "--lightbox-update-health-marker"

    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(markerArgument)
    }

    @discardableResult
    static func recordLaunch(
        arguments: [String] = CommandLine.arguments,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let argumentIndex = arguments.firstIndex(of: markerArgument),
              arguments.indices.contains(argumentIndex + 1)
        else {
            return false
        }

        let markerURL = URL(fileURLWithPath: arguments[argumentIndex + 1]).standardizedFileURL
        let stagingRoot = markerURL.deletingLastPathComponent()
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        let stagingValues = try? stagingRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard markerURL.lastPathComponent == "launch-healthy",
              stagingRoot.lastPathComponent.hasPrefix("LightboxUpdate-"),
              stagingValues?.isDirectory == true,
              stagingValues?.isSymbolicLink != true,
              stagingRoot.resolvingSymlinksInPath().deletingLastPathComponent()
                == temporaryDirectory.resolvingSymlinksInPath()
        else {
            return false
        }

        do {
            try Data().write(to: markerURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

enum UpdateError: LocalizedError {
    case assetDigestMissing
    case compatibleAssetMissing
    case unavailable

    var errorDescription: String? {
        switch self {
        case .assetDigestMissing:
            return "The update does not include a SHA-256 digest."
        case .compatibleAssetMissing:
            return "This release does not include a compatible Lightbox update."
        case .unavailable:
            return "GitHub Releases is unavailable."
        }
    }
}

enum UpdateInstallError: LocalizedError {
    case appBundleMissing
    case appVersionMismatch
    case bundleIdentifierMismatch
    case currentAppBundleMissing
    case digestMismatch
    case downloadFailed
    case invalidDigest
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .appBundleMissing:
            return "The downloaded update did not contain Lightbox.app."
        case .appVersionMismatch:
            return "The downloaded app version does not match the selected update."
        case .bundleIdentifierMismatch:
            return "The downloaded update does not match this Lightbox app."
        case .currentAppBundleMissing:
            return "This copy of Lightbox is not running from an app bundle."
        case .digestMismatch:
            return "The downloaded update failed its SHA-256 integrity check."
        case .downloadFailed:
            return "The update download failed."
        case .invalidDigest:
            return "The update contains an invalid SHA-256 digest."
        case let .toolFailed(message):
            return message
        }
    }
}
