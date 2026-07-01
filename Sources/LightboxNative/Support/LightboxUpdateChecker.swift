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

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CheckResult: Equatable {
        case updateAvailable(version: String, releaseURL: URL, assetURL: URL)
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

        guard isVersion(latestVersion, newerThan: currentVersion),
              let asset = preferredAsset(in: release, compatibility: compatibility)
        else {
            return .upToDate(version: latestVersion, releaseURL: release.htmlURL)
        }

        return .updateAvailable(
            version: latestVersion,
            releaseURL: release.htmlURL,
            assetURL: asset.browserDownloadURL
        )
    }

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func preferredAsset(in release: Release, compatibility: Bool) -> Asset? {
        release.assets.first { asset in
            let name = asset.name.lowercased()
            if compatibility {
                return name.contains("intel") || name.contains("x86")
            }
            return name.hasPrefix("lightbox-v") && name.hasSuffix(".zip")
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
    static func prepareUpdate(from assetURL: URL) async throws -> URL {
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

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.moveItem(at: downloadedURL, to: zipURL)
        try fileManager.createDirectory(at: unzipURL, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, unzipURL.path])

        guard let appURL = try findAppBundle(in: unzipURL) else {
            throw UpdateInstallError.appBundleMissing
        }
        return appURL
    }

    static func installPreparedUpdate(_ stagedAppURL: URL) throws {
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentAppURL.pathExtension == "app" else {
            throw UpdateInstallError.currentAppBundleMissing
        }
        try validateBundleIdentifier(for: stagedAppURL)

        let processID = String(ProcessInfo.processInfo.processIdentifier)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightboxInstall-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        set -eu

        CURRENT_APP="$1"
        STAGED_APP="$2"
        CURRENT_PID="$3"
        STAGING_ROOT="$(dirname "$(dirname "$STAGED_APP")")"
        BACKUP_APP="${CURRENT_APP}.old-$(date +%s)"

        while /bin/kill -0 "$CURRENT_PID" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if [ -e "$CURRENT_APP" ]; then
          /bin/mv "$CURRENT_APP" "$BACKUP_APP"
        fi

        /usr/bin/ditto "$STAGED_APP" "$CURRENT_APP"
        /usr/bin/xattr -cr "$CURRENT_APP" >/dev/null 2>&1 || true
        /usr/bin/open -n "$CURRENT_APP"
        /bin/rm -rf "$BACKUP_APP" "$STAGING_ROOT" "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, currentAppURL.path, stagedAppURL.path, processID]
        try process.run()
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

    private static func validateBundleIdentifier(for stagedAppURL: URL) throws {
        guard let stagedBundle = Bundle(url: stagedAppURL),
              let stagedBundleIdentifier = stagedBundle.bundleIdentifier,
              let currentBundleIdentifier = Bundle.main.bundleIdentifier,
              stagedBundleIdentifier == currentBundleIdentifier
        else {
            throw UpdateInstallError.bundleIdentifierMismatch
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

enum UpdateError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "GitHub Releases is unavailable."
        }
    }
}

enum UpdateInstallError: LocalizedError {
    case appBundleMissing
    case bundleIdentifierMismatch
    case currentAppBundleMissing
    case downloadFailed
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .appBundleMissing:
            return "The downloaded update did not contain Lightbox.app."
        case .bundleIdentifierMismatch:
            return "The downloaded update does not match this Lightbox app."
        case .currentAppBundleMissing:
            return "This copy of Lightbox is not running from an app bundle."
        case .downloadFailed:
            return "The update download failed."
        case let .toolFailed(message):
            return message
        }
    }
}
