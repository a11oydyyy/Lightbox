import Foundation

/// Strings for opening in Photoshop and exporting JPEGs through it.
struct ExportText {
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

    var openInPhotoshop: String { pick("Open in Photoshop", "在 Photoshop 中打开", "在 Photoshop 中開啟", "Photoshop で開く") }
    var exportMenuItem: String { pick("Export as JPEG…", "导出为 JPEG…", "轉存為 JPEG…", "JPEG として書き出す…") }

    func title(count: Int, name: String) -> String {
        count == 1
            ? pick("Export “\(name)” as JPEG", "将“\(name)”导出为 JPEG", "將「\(name)」轉存為 JPEG", "“\(name)”を JPEG として書き出す")
            : pick("Export \(count) Images as JPEG", "将 \(count) 张图片导出为 JPEG", "將 \(count) 張圖片轉存為 JPEG", "\(count) 枚を JPEG として書き出す")
    }

    var location: String { pick("Save To", "存储到", "儲存到", "保存先") }
    func subfolder(_ name: String) -> String {
        pick("“\(name)” folder beside each image", "每张图片旁的“\(name)”文件夹",
             "每張圖片旁的「\(name)」資料夾", "各画像と同じ場所の“\(name)”フォルダ")
    }
    var chooseFolder: String { pick("Choose Folder…", "选择文件夹…", "選擇資料夾…", "フォルダを選択…") }
    var quality: String { pick("Quality", "品质", "品質", "画質") }
    func qualityValue(_ value: Int) -> String {
        let word = switch value {
        case 0...4: pick("Low", "低", "低", "低")
        case 5...7: pick("Medium", "中", "中", "中")
        case 8...9: pick("High", "高", "高", "高")
        default: pick("Maximum", "最佳", "最佳", "最高")
        }
        return "\(value) · \(word)"
    }
    var convertToSRGB: String { pick("Convert to sRGB", "转换为 sRGB", "轉換為 sRGB", "sRGB に変換") }
    var limitLongEdge: String { pick("Fit Long Edge", "限制长边", "限制長邊", "長辺を制限") }
    var pixels: String { "px" }
    var exportButton: String { pick("Export", "导出", "轉存", "書き出す") }
    var cancelButton: String { pick("Cancel", "取消", "取消", "キャンセル") }

    var exporting: String { pick("Exporting JPEGs", "正在导出 JPEG", "正在轉存 JPEG", "JPEG を書き出し中") }

    // The title while an export runs and once it ends; numbers roll in place.
    func progress(_ done: Int, of total: Int) -> String {
        pick("Exporting \(done)/\(total)", "导出中 \(done)/\(total)", "轉存中 \(done)/\(total)", "書き出し中 \(done)/\(total)")
    }
    func exported(_ count: Int) -> String {
        pick("Exported \(count)", "已导出 \(count) 张", "已轉存 \(count) 張", "\(count) 枚書き出し完了")
    }
    func notExported(_ count: Int) -> String {
        pick("\(count) Not Exported", "\(count) 张未导出", "\(count) 張未轉存", "\(count) 枚書き出せず")
    }
    func existsTitle(count: Int, name: String) -> String {
        count == 1
            ? pick("“\(name)” already exists", "“\(name)”已存在", "「\(name)」已存在", "“\(name)”はすでにあります")
            : pick("\(count) JPEGs already exist", "\(count) 个 JPEG 已存在", "\(count) 個 JPEG 已存在", "\(count) 個の JPEG がすでにあります")
    }
    var replace: String { pick("Replace", "替换", "取代", "置き換える") }
    var keepBoth: String { pick("Keep Both", "保留两者", "保留兩者", "両方を残す") }
    var cancelled: String { pick("Export Stopped", "已停止导出", "已停止轉存", "書き出しを中止") }
    var stop: String { pick("Stop", "停止", "停止", "中止") }
    var done: String { pick("Done", "完成", "完成", "完了") }

    var notPermittedTitle: String {
        pick("Lightbox can’t control Photoshop", "Lightbox 无法控制 Photoshop", "Lightbox 無法控制 Photoshop", "Lightbox が Photoshop を操作できません")
    }
    var notPermittedMessage: String {
        pick("Allow it in System Settings › Privacy & Security › Automation, under Lightbox, then export again.",
             "请在“系统设置 › 隐私与安全性 › 自动化”中，于 Lightbox 下允许 Photoshop，然后重新导出。",
             "請到「系統設定 › 隱私權與安全性 › 自動化」，在 Lightbox 底下允許 Photoshop，再重新轉存。",
             "「システム設定 › プライバシーとセキュリティ › オートメーション」で Lightbox に Photoshop を許可してから、もう一度書き出してください。")
    }
    var openSettings: String { pick("Open System Settings", "打开系统设置", "打開系統設定", "システム設定を開く") }
}
