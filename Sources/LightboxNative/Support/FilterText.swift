import Foundation

/// Strings for the attribute filters (bottom bar, View menu, empty state).
struct FilterText {
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

    var title: String { pick("Sort & Filter", "排序与筛选", "排序與篩選", "並べ替えとフィルタ") }
    var menuTitle: String { pick("Sort & Filter…", "排序与筛选…", "排序與篩選…", "並べ替えとフィルタ…") }
    var clear: String { pick("Clear Filters", "清除筛选", "清除篩選", "フィルタをクリア") }
    var noMatches: String {
        pick("Nothing matches these filters", "没有符合筛选条件的项目", "沒有符合篩選條件的項目",
             "フィルタに一致する項目がありません")
    }
    func activeCount(_ count: Int) -> String {
        pick("\(count) filter\(count == 1 ? "" : "s") on", "已启用 \(count) 项筛选", "已啟用 \(count) 項篩選",
             "\(count) 件のフィルタ")
    }

    var kind: String { pick("Kind", "种类", "種類", "種類") }
    var orientation: String { pick("Orientation", "方向", "方向", "向き") }
    var longEdge: String { pick("Long Edge", "长边", "長邊", "長辺") }
    var dateAdded: String { pick("Date Added", "添加日期", "加入日期", "追加日") }
    var fileSize: String { pick("File Size", "文件大小", "檔案大小", "ファイルサイズ") }
    var cameraRaw: String { "Camera Raw" }

    /// The bottom bar's filter droplet once more than one filter is on.
    func filtered(_ count: Int) -> String {
        pick("\(count) Filters", "已筛选 \(count) 项", "已篩選 \(count) 項", "フィルタ \(count) 件")
    }

    /// The bottom bar's filter droplet for a single filter: its choice, named
    /// where the choice alone would be unclear.
    func chip(_ filter: GalleryAttributeFilter) -> String {
        if filter.activeCount > 1 { return filtered(filter.activeCount) }
        if filter.kind != .any { return label(filter.kind) }
        if filter.orientation != .any { return label(filter.orientation) }
        if filter.pixelSize != .any { return longEdge + " " + label(filter.pixelSize) }
        if filter.addedDate != .any {
            let date = label(filter.addedDate)
            return pick("Added \(date)", "\(date)添加", "\(date)加入", "\(date)追加")
        }
        if filter.fileSize != .any { return label(filter.fileSize) }
        if filter.cameraRaw != .any {
            let state = label(filter.cameraRaw)
            return pick("Camera Raw: \(state)", "Camera Raw \(state)", "Camera Raw \(state)", "Camera Raw \(state)")
        }
        return title
    }
    /// One more image per row (the slider's small dot, ⌘−).
    var moreColumns: String { pick("Smaller Thumbnails", "缩小缩略图", "縮小縮圖", "サムネールを小さく") }
    /// One fewer image per row (the slider's large dot, ⌘=).
    var fewerColumns: String { pick("Larger Thumbnails", "放大缩略图", "放大縮圖", "サムネールを大きく") }
    var moreColumnsHelp: String {
        pick("One more image per row (⌘−)", "每行多一张（⌘−）", "每行多一張（⌘−）", "1 行に 1 枚多く（⌘−）")
    }
    var fewerColumnsHelp: String {
        pick("One fewer image per row (⌘=)", "每行少一张（⌘=）", "每行少一張（⌘=）", "1 行に 1 枚少なく（⌘=）")
    }
    var any: String { pick("Any", "不限", "不限", "すべて") }

    func label(_ kind: GalleryAttributeFilter.Kind) -> String {
        switch kind {
        case .any: any
        case .photos: pick("Photos", "照片", "照片", "写真")
        case .raw: "RAW"
        case .videos: pick("Videos", "视频", "影片", "ビデオ")
        case .documents: pick("Documents", "文档", "文件", "書類")
        }
    }

    func label(_ orientation: GalleryAttributeFilter.Orientation) -> String {
        switch orientation {
        case .any: any
        case .landscape: pick("Landscape", "横向", "橫向", "横長")
        case .portrait: pick("Portrait", "竖向", "直向", "縦長")
        case .square: pick("Square", "方形", "方形", "正方形")
        }
    }

    func label(_ size: GalleryAttributeFilter.PixelSize) -> String {
        switch size {
        case .any: any
        case .under2000: "< 2000 px"
        case .atLeast2000: "≥ 2000"
        case .atLeast4000: "≥ 4000"
        case .atLeast6000: "≥ 6000"
        }
    }

    func label(_ date: GalleryAttributeFilter.AddedDate) -> String {
        switch date {
        case .any: any
        case .today: pick("Today", "今天", "今天", "今日")
        case .thisWeek: pick("This Week", "本周", "本週", "今週")
        case .thisMonth: pick("This Month", "本月", "本月", "今月")
        case .thisYear: pick("This Year", "今年", "今年", "今年")
        }
    }

    func label(_ state: GalleryAttributeFilter.CameraRaw) -> String {
        switch state {
        case .any: any
        case .edited: pick("Edited", "已调整", "已調整", "調整済み")
        case .unedited: pick("Not Edited", "未调整", "未調整", "未調整")
        }
    }

    func label(_ size: GalleryAttributeFilter.FileSize) -> String {
        switch size {
        case .any: any
        case .under1MB: "< 1 MB"
        case .from1To10MB: "1–10 MB"
        case .from10To50MB: "10–50 MB"
        case .over50MB: "≥ 50 MB"
        }
    }
}
