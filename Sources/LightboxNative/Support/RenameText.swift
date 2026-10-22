import Foundation

/// Every string the rename sheet, menus and alerts use, in one place.
struct RenameText {
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

    var menuItem: String { pick("Rename…", "重命名…", "重新命名…", "名前を変更…") }
    var undoAction: String { pick("Rename", "重命名", "重新命名", "名前を変更") }
    var renameButton: String { pick("Rename", "重命名", "重新命名", "名前を変更") }
    var cancelButton: String { pick("Cancel", "取消", "取消", "キャンセル") }
    var newName: String { pick("New name", "新名称", "新名稱", "新しい名前") }

    func title(count: Int, name: String) -> String {
        guard count > 1 else { return pick("Rename “\(name)”", "重命名“\(name)”", "重新命名「\(name)」", "“\(name)”の名前を変更") }
        return pick("Rename \(count) Items", "重命名 \(count) 个项目", "重新命名 \(count) 個項目", "\(count)項目の名前を変更")
    }

    var replaceMode: String { pick("Replace Text", "替换文本", "取代文字", "テキストを置き換える") }
    var addMode: String { pick("Add Text", "添加文本", "加入文字", "テキストを追加") }
    var formatMode: String { pick("Format", "格式", "格式", "フォーマット") }
    var find: String { pick("Find", "查找", "尋找", "検索") }
    var replaceWith: String { pick("Replace with", "替换为", "取代為", "置き換え") }
    var text: String { pick("Text", "文本", "文字", "テキスト") }
    var beforeName: String { pick("Before Name", "名称前", "名稱前", "名前の前") }
    var afterName: String { pick("After Name", "名称后", "名稱後", "名前の後") }
    var customName: String { pick("Name", "名称", "名稱", "名前") }
    var startNumber: String { pick("Start numbers at", "起始编号", "起始編號", "開始番号") }
    var formatHint: String { pick("Name, then a number in the current order", "名称加上按当前顺序的编号", "名稱加上按目前順序的編號", "名前と現在の順序の番号") }

    var newFolderMenuItem: String { pick("New Folder", "新建文件夹", "新增資料夾", "新規フォルダ") }
    var newFolderUndo: String { pick("New Folder", "新建文件夹", "新增資料夾", "新規フォルダ") }
    var untitledFolder: String { pick("untitled folder", "未命名文件夹", "未命名資料夾", "名称未設定フォルダ") }
    var createButton: String { pick("Create", "创建", "建立", "作成") }

    func newFolderTitle(in folder: String) -> String {
        pick("New Folder in “\(folder)”", "在“\(folder)”中新建文件夹", "在「\(folder)」中新增資料夾", "“\(folder)”に新規フォルダ")
    }

    func folderNotEmpty(_ name: String) -> String {
        pick("“\(name)” isn’t empty any more, so it was kept.", "“\(name)”已不是空的，因此保留。",
             "「\(name)」已不是空的，因此保留。", "“\(name)”は空ではないため残しました。")
    }

    func putBackFailed(_ name: String) -> String {
        pick("“\(name)” couldn’t be put back from the Trash.", "无法从废纸篓放回“\(name)”。",
             "無法從垃圾桶放回「\(name)」。", "“\(name)”をゴミ箱から戻せませんでした。")
    }

    func moreItems(_ count: Int) -> String {
        pick("and \(count) more", "另外 \(count) 个", "另外 \(count) 個", "ほか\(count)件")
    }

    func extensionChange(from old: String, to new: String) -> String {
        let old = old.isEmpty ? pick("none", "无", "無", "なし") : ".\(old)"
        let new = new.isEmpty ? pick("none", "无", "無", "なし") : ".\(new)"
        return pick("The extension changes from \(old) to \(new).", "扩展名将从 \(old) 改为 \(new)。",
                    "副檔名會從 \(old) 改為 \(new)。", "拡張子が \(old) から \(new) に変わります。")
    }

    func message(for issue: FileRenameIssue) -> String {
        switch issue {
        case .empty:
            pick("Enter a name.", "请输入名称。", "請輸入名稱。", "名前を入力してください。")
        case .invalidCharacter:
            pick("Names can’t contain “/” or “:”.", "名称不能包含“/”或“:”。", "名稱不能包含「/」或「:」。", "名前に「/」や「:」は使えません。")
        case .leadingDot:
            pick("Names starting with “.” are hidden; use another name.", "以“.”开头的名称会被隐藏，请换一个名称。",
                 "以「.」開頭的名稱會被隱藏，請換一個名稱。", "「.」で始まる名前は非表示になります。別の名前にしてください。")
        case .tooLong:
            pick("The name is too long.", "名称太长。", "名稱太長。", "名前が長すぎます。")
        case .duplicate(let name):
            pick("More than one item would be named “\(name)”.", "多个项目会使用相同名称“\(name)”。",
                 "多個項目會使用相同名稱「\(name)」。", "複数の項目が“\(name)”になります。")
        case .exists(let name):
            pick("An item named “\(name)” already exists.", "已有名为“\(name)”的项目。",
                 "已有名為「\(name)」的項目。", "“\(name)”という項目はすでにあります。")
        case .failed(let name):
            pick("Couldn’t rename to “\(name)”. Nothing was changed.", "无法重命名为“\(name)”，没有任何更改。",
                 "無法重新命名為「\(name)」，沒有任何變更。", "“\(name)”に変更できませんでした。何も変更されていません。")
        }
    }
}
