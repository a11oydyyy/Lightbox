import Foundation

enum LightboxRuntime {
    static let localBundleIdentifier = "io.github.a11oydyyy.Lightbox.local"

    static func cacheDirectoryName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "Lightbox" }
        if bundleIdentifier == localBundleIdentifier { return "LightboxLocal" }
        if bundleIdentifier.hasPrefix(localBundleIdentifier + ".") {
            return bundleIdentifier
        }
        return "Lightbox"
    }
}
