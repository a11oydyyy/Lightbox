import Foundation

enum LightboxRuntime {
    static let compatibilityBundleIdentifier = "io.github.a11oydyyy.Lightbox13"
    static let localBundleIdentifier = "io.github.a11oydyyy.Lightbox.local"

    static func cacheDirectoryName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "Lightbox" }
        if bundleIdentifier == localBundleIdentifier { return "LightboxLocal" }
        if bundleIdentifier.hasPrefix(localBundleIdentifier + ".") {
            return bundleIdentifier
        }
        return "Lightbox"
    }

    static var isCompatibilityApp: Bool {
        Bundle.main.bundleIdentifier == compatibilityBundleIdentifier
    }

    static var usesCompatibilityPerformanceMode: Bool {
        isCompatibilityApp
    }
}
