import Foundation
import Testing
@testable import LightboxNative

private func writePlugin(in folder: URL, application: String = "图片分析.app", apiVersion: Int = 1) throws -> URL {
    let package = folder.appendingPathComponent("图片分析.lightboxplugin")
    let app = package.appendingPathComponent("图片分析.app/Contents")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": "test.image-analysis", "CFBundleExecutable": "Plugin", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    let executable = app.appendingPathComponent("MacOS/Plugin")
    try Data("fixture".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let manifest = LightboxPluginManifest(apiVersion: apiVersion, identifier: "test.image-analysis", name: "图片分析",
        version: "1.0", application: application, symbol: "sparkles")
    try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
    return package
}

@Test func pluginsAreAbsentUntilInstalledAndRetainTheirSeparateExecutable() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPlugin-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let directory = folder.appendingPathComponent("Host/Plugins")
    #expect(LightboxPluginCatalog.discover(in: directory).isEmpty)
    let source = try writePlugin(in: folder.appendingPathComponent("Source"))
    let installed = try LightboxPluginCatalog.install(source, in: directory)
    let discovered = LightboxPluginCatalog.discover(in: directory)
    #expect(discovered.count == 1)
    #expect(discovered.first?.id == "test.image-analysis")
    #expect(installed.applicationURL.path.hasPrefix(directory.path + "/"))
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path))
    let original = try Data(contentsOf: installed.packageURL.appendingPathComponent("manifest.json"))
    #expect(throws: LightboxPluginError.alreadyInstalled) { try LightboxPluginCatalog.install(source, in: directory) }
    #expect(try Data(contentsOf: installed.packageURL.appendingPathComponent("manifest.json")) == original)
}

@Test func pluginsRejectOutsideApplicationsAndUnsupportedProtocols() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxPluginInvalid-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let outside = try writePlugin(in: folder.appendingPathComponent("Outside"), application: "../Outside.app")
    #expect(throws: LightboxPluginError.invalidPackage) { try LightboxPluginCatalog.inspect(outside) }
    let unsupported = try writePlugin(in: folder.appendingPathComponent("Newer"), apiVersion: 2)
    #expect(throws: LightboxPluginError.unsupportedVersion) { try LightboxPluginCatalog.inspect(unsupported) }
    #expect(LightboxPluginCatalog.discover(in: unsupported.deletingLastPathComponent()).isEmpty)
    let symlink = try writePlugin(in: folder.appendingPathComponent("Symlink"), application: "External.app")
    try FileManager.default.createSymbolicLink(at: symlink.appendingPathComponent("External.app"),
        withDestinationURL: unsupported.appendingPathComponent("图片分析.app"))
    #expect(throws: LightboxPluginError.invalidPackage) { try LightboxPluginCatalog.inspect(symlink) }
}
