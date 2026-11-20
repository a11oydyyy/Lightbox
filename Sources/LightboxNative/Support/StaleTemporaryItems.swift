import AppKit
import Darwin
import Foundation

/// Temporary items a crash can leave behind in a folder:
/// `.lightbox-transfer-*` and `.lightbox-export-*` are partial copies and go to
/// the Trash; `.lightbox-rename-*` is a user's real file under a hidden name
/// and is offered back under its own name. Entries younger than `safetyWindow`
/// (another process may still be working) and entries this process is using
/// right now (`inUse`, however old they look) are never touched.
enum StaleTemporaryItems {
    static let safetyWindow: TimeInterval = 3600
    static let renamePrefix = ".lightbox-rename-"

    enum Kind: Equatable, Sendable { case partialCopy, renamedOriginal }

    struct Outcome: Equatable, Sendable {
        var trashed: [URL] = []
        /// Real files under a temporary name; the caller offers to reveal them.
        var renamedOriginals: [URL] = []
    }

    static func kind(ofName name: String) -> Kind? {
        if name.hasPrefix(".lightbox-transfer-") || name.hasPrefix(".lightbox-export-") { return .partialCopy }
        if name.hasPrefix(renamePrefix) { return .renamedOriginal }
        return nil
    }

    // MARK: In-use registry

    private static let inUseNames = Locked(Set<String>())

    /// Marks a temporary item this process is creating or filling. Keyed by
    /// the name alone: it carries a UUID, so it is unique whatever path
    /// spelling (`/tmp`, `/private/tmp`) the folder is reached by.
    static func registerInUse(_ url: URL) {
        inUseNames.withLock { _ = $0.insert(url.lastPathComponent) }
    }

    static func unregisterInUse(_ url: URL) {
        inUseNames.withLock { _ = $0.remove(url.lastPathComponent) }
    }

    static func isInUse(_ url: URL) -> Bool {
        inUseNames.withLock { $0.contains(url.lastPathComponent) }
    }

    // MARK: Rename temporary names

    /// What a `.lightbox-rename-<UUID>-<index>[-<original name>]` name says.
    /// The original name is absent in names written before it was recorded.
    struct RenameLeftover: Equatable, Sendable {
        var index: Int
        var original: String?
    }

    /// `.lightbox-rename-<UUID>-<index>-<original>`; when that exceeds
    /// `NAME_MAX` bytes the original's base name is cut on a character
    /// boundary and its extension kept.
    static func renameTemporaryName(id: UUID = UUID(), index: Int, original: String) -> String {
        let head = "\(renamePrefix)\(id.uuidString)-\(index)-"
        let budget = Int(NAME_MAX) - head.utf8.count
        guard original.utf8.count > budget else { return head + original }
        var suffix = original.pathExtensionSuffix
        if suffix.utf8.count >= budget { suffix = "" }
        var base = Array(String(original.unicodeScalars.dropLast(suffix.unicodeScalars.count)))
        while !base.isEmpty, String(base).utf8.count + suffix.utf8.count > budget { base.removeLast() }
        return head + String(base) + suffix
    }

    static func parseRenameLeftover(_ name: String) -> RenameLeftover? {
        guard name.hasPrefix(renamePrefix) else { return nil }
        let rest = name.dropFirst(renamePrefix.count)
        guard rest.count > 37, UUID(uuidString: String(rest.prefix(36))) != nil else { return nil }
        var tail = rest.dropFirst(36)
        guard tail.first == "-" else { return nil }
        tail = tail.dropFirst()
        let digits = tail.prefix { $0.isASCII && $0.isNumber }
        guard let index = Int(digits) else { return nil }
        let after = tail.dropFirst(digits.count)
        if after.isEmpty { return RenameLeftover(index: index, original: nil) }
        guard after.first == "-", after.count > 1 else { return nil }
        return RenameLeftover(index: index, original: String(after.dropFirst()))
    }

    /// The visible name a leftover is restored to; a name written without the
    /// original (or one that cannot safely be reused) becomes `Recovered <index>`.
    static func restoredName(forTemporaryName name: String) -> String {
        let leftover = parseRenameLeftover(name)
        if let original = leftover?.original, !original.isEmpty, original != ".", original != "..",
           !original.contains("/"), kind(ofName: original) == nil {
            return original
        }
        return "Recovered \(leftover?.index ?? 0)"
    }

    /// Puts each leftover back in its own folder under its original name,
    /// never replacing anything: a taken name gets " 2", " 3"… as moves do.
    /// Returns where each restored item ended up. Blocks on file I/O; call off
    /// the main thread.
    static func restore(_ urls: [URL]) -> [URL] {
        var restored: [URL] = []
        for url in urls {
            let folder = url.deletingLastPathComponent()
            let wanted = folder.appendingPathComponent(restoredName(forTemporaryName: url.lastPathComponent))
            func next() -> URL? {
                try? FileTransferService.availableDestinationURL(
                    for: wanted, in: folder, operation: .move, shouldCancel: { false })
            }
            guard var target = next() else { continue }
            while true {
                let error = ExclusiveRename.rename(url, to: target)
                if error == 0 { restored.append(target); break }
                guard error == EEXIST, let another = next(), another != target else { break }
                target = another
            }
        }
        return restored
    }

    /// Names a directory read already produced; only matching ones are
    /// examined (one `lstat` each), so a clean folder costs nothing extra.
    /// Blocks on file I/O; call off the main thread.
    static func process(
        names: [String],
        in folder: URL,
        now: Date = Date(),
        trash: (URL) -> URL?
    ) -> Outcome {
        var outcome = Outcome()
        for name in names {
            guard let kind = kind(ofName: name) else { continue }
            let url = folder.appendingPathComponent(name)
            guard !isInUse(url) else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            // A rename keeps mtime, so ctime says when it was last moved or written.
            let touched = max(info.st_mtimespec.tv_sec, info.st_ctimespec.tv_sec)
            guard now.timeIntervalSince1970 - TimeInterval(touched) >= safetyWindow else { continue }
            switch kind {
            case .partialCopy:
                if let trashed = trash(url) { outcome.trashed.append(trashed) }
            case .renamedOriginal:
                outcome.renamedOriginals.append(url)
            }
        }
        return outcome
    }

    // MARK: Alert

    private static let alerted = Locked(Set<String>())

    /// Paths not yet shown in this run, so a refresh never repeats the alert.
    static func unannounced(_ urls: [URL]) -> [URL] {
        alerted.withLock { shown in urls.filter { shown.insert($0.path).inserted } }
    }

    /// Shown as a sheet on `window`, so nothing waits on it. `restored` runs on
    /// the main actor after the leftovers were put back.
    @MainActor
    static func presentRenamedOriginalsAlert(
        _ urls: [URL], language: LightboxLanguage, window: NSWindow, restored: @escaping @MainActor () -> Void
    ) {
        guard !urls.isEmpty else { return }
        let text = Text(language)
        let alert = NSAlert()
        alert.messageText = text.title(count: urls.count)
        alert.addButton(withTitle: text.restore)
        alert.addButton(withTitle: text.later)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task.detached(priority: .userInitiated) {
                _ = restore(urls)
                await MainActor.run { restored() }
            }
        }
    }

    struct Text {
        let language: LightboxResolvedLanguage
        init(_ language: LightboxLanguage) { self.language = language.resolved }

        private func pick(_ en: String, _ hans: String, _ hant: String, _ ja: String) -> String {
            switch language {
            case .english: en
            case .simplifiedChinese: hans
            case .traditionalChinese: hant
            case .japanese: ja
            }
        }

        func title(count: Int) -> String {
            pick("\(count) unfinished rename\(count == 1 ? "" : "s")", "\(count) 个未完成的重命名",
                 "\(count) 個未完成的重新命名", "未完了の名前変更 \(count) 件")
        }
        var restore: String { pick("Restore", "还原", "還原", "復元") }
        var later: String { pick("Later", "稍后", "稍後", "あとで") }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

private extension String {
    /// ".jpg" for "a.jpg", "" when there is no extension.
    var pathExtensionSuffix: String {
        let ext = (self as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext
    }
}
