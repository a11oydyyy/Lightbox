import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LightboxPluginManifest: Codable, Equatable, Sendable {
    var apiVersion: Int
    var identifier: String
    var name: String
    var version: String
    var application: String
    var symbol: String?
}

struct InstalledLightboxPlugin: Identifiable, Equatable, Sendable {
    var manifest: LightboxPluginManifest
    var packageURL: URL
    var applicationURL: URL
    var id: String { manifest.identifier }
}

enum LightboxPluginError: LocalizedError {
    case invalidPackage, unsupportedVersion, alreadyInstalled

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "插件包无效，请选择完整的 .lightboxplugin 文件。"
        case .unsupportedVersion: "这个插件需要更新版本的 Lightbox。"
        case .alreadyInstalled: "已安装这个插件。可在插件文件夹中移走旧版本后重新安装。"
        }
    }
}

enum LightboxPluginCatalog {
    static func inspect(_ package: URL) throws -> InstalledLightboxPlugin {
        guard package.pathExtension == "lightboxplugin" else { throw LightboxPluginError.invalidPackage }
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard manifestURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw LightboxPluginError.invalidPackage
        }
        let manifest = try JSONDecoder().decode(LightboxPluginManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.apiVersion == 1 else { throw LightboxPluginError.unsupportedVersion }
        guard manifest.identifier.range(of: "^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$", options: .regularExpression) != nil,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.application.hasPrefix("/"),
              !manifest.application.split(separator: "/").contains("..") else {
            throw LightboxPluginError.invalidPackage
        }
        let app = root.appendingPathComponent(manifest.application).resolvingSymlinksInPath().standardizedFileURL
        guard app.path.hasPrefix(root.path + "/"), app.pathExtension == "app",
              let bundle = Bundle(url: app), bundle.bundleIdentifier == manifest.identifier,
              let executable = bundle.executableURL,
              executable.resolvingSymlinksInPath().path.hasPrefix(app.path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LightboxPluginError.invalidPackage
        }
        return InstalledLightboxPlugin(manifest: manifest, packageURL: package, applicationURL: app)
    }

    static func discover(in directory: URL) -> [InstalledLightboxPlugin] {
        let packages = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var identifiers = Set<String>()
        return packages.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? inspect($0) }
            .filter { identifiers.insert($0.id).inserted }
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    @discardableResult
    static func install(_ package: URL, in directory: URL) throws -> InstalledLightboxPlugin {
        let plugin = try inspect(package)
        let destination = directory.appendingPathComponent(plugin.id + ".lightboxplugin")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LightboxPluginError.alreadyInstalled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(UUID()).lightboxplugin")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: package, to: staging)
        _ = try inspect(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return try inspect(destination)
    }
}

@MainActor
final class LightboxPluginHost: ObservableObject {
    static let shared = LightboxPluginHost()
    @Published private(set) var plugins: [InstalledLightboxPlugin] = []
    let supportDirectory: URL
    var directory: URL { supportDirectory.appendingPathComponent("Plugins", isDirectory: true) }
    private var activationObserver: AnyCancellable?

    init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LightboxRuntime.cacheDirectoryName(for: Bundle.main.bundleIdentifier), isDirectory: true)
        refresh()
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() { plugins = LightboxPluginCatalog.discover(in: directory) }

    func install() {
        let panel = NSOpenPanel()
        panel.title = "安装插件"
        panel.prompt = "安装"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "lightboxplugin") ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LightboxPluginCatalog.install(url, in: directory)
            refresh()
        } catch { show(error) }
    }

    func revealDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { show(error) }
    }

    func open(_ plugin: InstalledLightboxPlugin, images: [URL]) {
        guard !images.isEmpty else { return }
        do {
            let current = try LightboxPluginCatalog.inspect(plugin.packageURL)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--host-support-directory", supportDirectory.path]
            // Each invocation owns its selection and data store, including when
            // the test app and installed app are used at the same time.
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.open(images, withApplicationAt: current.applicationURL, configuration: configuration) { _, error in
                if let error { Task { @MainActor in self.show(error) } }
            }
        } catch { show(error) }
    }

    private func show(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "无法使用插件"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

extension AppState {
    var pluginImageURLs: [URL] {
        if let asset = previewAsset { return [asset.sourceURL].compactMap { $0 } }
        if !selectedAssetIDs.isEmpty { return activeAssets.filter { selectedAssetIDs.contains($0.id) }.compactMap(\.sourceURL) }
        return [explicitlySelectedAsset?.sourceURL].compactMap { $0 }
    }
}
