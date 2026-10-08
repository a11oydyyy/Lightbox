import Testing
@testable import LightboxNative

@Test func localBuildVariantsKeepIndependentCaches() {
    let plugin = "io.github.a11oydyyy.Lightbox.local.plugins"
    let macos = "io.github.a11oydyyy.Lightbox.local.macos27"
    let names = [plugin, macos, LightboxRuntime.localBundleIdentifier].map {
        LightboxRuntime.cacheDirectoryName(for: $0)
    }
    #expect(Set(names).count == 3)
    #expect(!names.contains("Lightbox"))
    #expect(LightboxRuntime.cacheDirectoryName(for: LightboxRuntime.localBundleIdentifier) == "LightboxLocal")
}

@Test func shippingBuildsPreserveExistingCacheLocation() {
    for identifier in [nil, "io.github.a11oydyyy.Lightbox", LightboxRuntime.compatibilityBundleIdentifier,
                       "io.github.a11oydyyy.Lightbox.locality"] as [String?] {
        #expect(LightboxRuntime.cacheDirectoryName(for: identifier) == "Lightbox")
    }
}
