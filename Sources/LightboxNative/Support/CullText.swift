import Foundation

/// Strings for culling in the preview.
struct CullText {
    let language: LightboxResolvedLanguage

    init(_ language: LightboxLanguage) {
        self.language = language.resolved
    }

    private func pick(_ en: String, _ hans: String, _ hant: String, _ ja: String) -> String {
        switch language {
        case .english: en
        case .simplifiedChinese: hans
        case .traditionalChinese: hant
        case .japanese: ja
        }
    }

    /// The badge after a mark.
    func feedback(_ mark: CullMark) -> String {
        switch mark {
        case .keep: pick("Keep", "保留", "保留", "採用")
        case .reject: pick("Reject", "淘汰", "淘汰", "除外")
        case .clear: pick("Unmarked", "已取消标记", "已取消標記", "マークを解除")
        }
    }

    /// Edit › Undo's name for the mark.
    func actionName(_ mark: CullMark) -> String {
        switch mark {
        case .keep: pick("Mark as Keep", "标为保留", "標為保留", "採用にする")
        case .reject: pick("Mark as Reject", "标为淘汰", "標為淘汰", "除外にする")
        case .clear: pick("Clear Mark", "取消标记", "取消標記", "マークを解除")
        }
    }

    /// Shown while the preview is at 100%.
    var zoomBadge: String { "100%" }

    /// Image › Actual Size, Z beside it.
    var zoomMenuItem: String {
        pick("Actual Size", "实际大小", "實際大小", "実際のサイズ")
    }

    /// The preview's zoom button.
    var zoomButton: String {
        pick("Actual Size (Z)", "实际大小 (Z)", "實際大小 (Z)", "実際のサイズ (Z)")
    }
}
