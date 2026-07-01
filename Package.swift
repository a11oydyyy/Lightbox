// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LightboxNative",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "LightboxNative",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LightboxNativeTests",
            dependencies: ["LightboxNative"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
