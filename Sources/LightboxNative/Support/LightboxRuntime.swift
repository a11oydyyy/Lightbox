import Foundation

enum LightboxRuntime {
    static let compatibilityBundleIdentifier = "io.github.a11oydyyy.Lightbox13"

    static var isCompatibilityApp: Bool {
        Bundle.main.bundleIdentifier == compatibilityBundleIdentifier
    }

    static var usesCompatibilityPerformanceMode: Bool {
        isCompatibilityApp
    }
}
