import Foundation

/// Strings for the list view and the grid/list switch.
struct FileListText {
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

    var asGrid: String { pick("as Gallery", "以图库显示", "以圖庫顯示", "ギャラリーで表示") }
    var asList: String { pick("as List", "以列表显示", "以列表顯示", "リストで表示") }
    var name: String { pick("Name", "名称", "名稱", "名前") }
    var dateAdded: String { pick("Date Added", "添加日期", "加入日期", "追加日") }
    var size: String { pick("Size", "大小", "大小", "サイズ") }
    var kind: String { pick("Kind", "种类", "種類", "種類") }
    var dimensions: String { pick("Dimensions", "尺寸", "尺寸", "寸法") }
    var tags: String { pick("Tags", "标签", "標籤", "タグ") }
    var location: String { pick("Where", "位置", "位置", "場所") }
    var folder: String { pick("Folder", "文件夹", "資料夾", "フォルダ") }
    var open: String { pick("Open", "打开", "打開", "開く") }
}
