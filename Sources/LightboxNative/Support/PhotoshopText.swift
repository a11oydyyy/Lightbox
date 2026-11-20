import Foundation

/// Strings for opening in Photoshop.
struct PhotoshopText {
    let language: LightboxResolvedLanguage

    init(_ language: LightboxLanguage) {
        self.language = language.resolved
    }

    var openInPhotoshop: String {
        switch language {
        case .english: "Open in Photoshop"
        case .simplifiedChinese: "在 Photoshop 中打开"
        case .traditionalChinese: "在 Photoshop 中開啟"
        case .japanese: "Photoshop で開く"
        }
    }
}
