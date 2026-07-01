import SwiftUI

enum LightboxColorMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum LightboxLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case japanese

    var id: String { rawValue }

    var resolved: LightboxResolvedLanguage {
        switch self {
        case .system:
            let code = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
            if code.hasPrefix("zh") {
                return .simplifiedChinese
            }
            if code.hasPrefix("ja") {
                return .japanese
            }
            return .english
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .japanese:
            return .japanese
        }
    }
}

enum LightboxResolvedLanguage {
    case english
    case simplifiedChinese
    case japanese
}

enum LightboxTextKey: String, CaseIterable {
    case about
    case addSelectedToCompareTray
    case addToCompareTray
    case appearance
    case appDescription
    case assetMenu
    case alreadyUpToDate
    case alreadyUpToDateMessage
    case alreadyUpToDateStatus
    case checkForUpdates
    case checkingForUpdates
    case chooseLibraryFolder
    case clear
    case clearCompareTray
    case close
    case closeComparison
    case closeFilters
    case closeSidebar
    case colorMode
    case compare
    case compareSelection
    case copy
    case copyPath
    case custom
    case customColor
    case dark
    case defaultApp
    case downloadingUpdate
    case dropImagesToImport
    case english
    case github
    case githubReleases
    case githubReserved
    case goToParentFolder
    case folderTileWidth
    case grid
    case hoverGlow
    case importImages
    case installUpdate
    case installingUpdate
    case japanese
    case language
    case library
    case light
    case liquidGlassOpacity
    case masonry
    case moveToTrash
    case noImagesHere
    case noMatches
    case openFilters
    case openFolder
    case openFullDiskAccess
    case openSidebar
    case openWith
    case other
    case path
    case pinCurrentPath
    case preparingPreviews
    case refreshLibrary
    case remove
    case restore
    case scanningFolder
    case search
    case settings
    case share
    case showInFinder
    case showApplications
    case showDesktop
    case showDocuments
    case showDownloads
    case showFolderCards
    case showICloudDrive
    case showMovies
    case showMusic
    case showPictures
    case showVolumes
    case sidebar
    case sidebarWidth
    case simplifiedChinese
    case switchToGrid
    case switchToMasonry
    case sort
    case sortAscending
    case sortBy
    case sortDescending
    case sortFileName
    case sortSize
    case sortTag
    case sortTime
    case sortType
    case system
    case trash
    case trashAccessDenied
    case unpinFolder
    case updateAvailable
    case updateAvailableMessage
    case updateAvailableStatus
    case updateCheckFailed
    case updates
    case version
}

enum LightboxSettingsStore {
    private enum Key {
        static let colorMode = "Lightbox.colorMode"
        static let glassOpacity = "Lightbox.glassOpacity"
        static let language = "Lightbox.language"
        static let sidebarCollapsed = "Lightbox.sidebar.collapsed"
        static let sidebarWidth = "Lightbox.sidebar.width"
        static let sidebarVisibleLocationIDs = "Lightbox.sidebar.visibleLocationIDs"
        static let showFolderCards = "Lightbox.gallery.showFolderCards"
    }

    static let defaultGlassOpacity = 0.58
    static let glassOpacityRange = 0.20...0.85
    static let defaultSidebarCollapsed = true
    static let defaultSidebarWidth: CGFloat = 236
    static let sidebarWidthRange: ClosedRange<CGFloat> = 188...360
    static let defaultSidebarLocationIDs: Set<SidebarLocationID> = Set(SidebarLocationID.allCases)
    static let defaultShowFolderCards = true

    static func loadColorMode() -> LightboxColorMode {
        guard let rawValue = UserDefaults.standard.string(forKey: Key.colorMode),
              let mode = LightboxColorMode(rawValue: rawValue)
        else {
            return .system
        }
        return mode
    }

    static func saveColorMode(_ mode: LightboxColorMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Key.colorMode)
    }

    static func loadGlassOpacity() -> Double {
        guard UserDefaults.standard.object(forKey: Key.glassOpacity) != nil else {
            return defaultGlassOpacity
        }
        return clampGlassOpacity(UserDefaults.standard.double(forKey: Key.glassOpacity))
    }

    static func saveGlassOpacity(_ opacity: Double) {
        UserDefaults.standard.set(clampGlassOpacity(opacity), forKey: Key.glassOpacity)
    }

    static func loadLanguage() -> LightboxLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: Key.language),
              let language = LightboxLanguage(rawValue: rawValue)
        else {
            return .english
        }
        return language
    }

    static func saveLanguage(_ language: LightboxLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: Key.language)
    }

    static func loadSidebarCollapsed() -> Bool {
        guard UserDefaults.standard.object(forKey: Key.sidebarCollapsed) != nil else {
            return defaultSidebarCollapsed
        }

        return UserDefaults.standard.bool(forKey: Key.sidebarCollapsed)
    }

    static func saveSidebarCollapsed(_ collapsed: Bool) {
        UserDefaults.standard.set(collapsed, forKey: Key.sidebarCollapsed)
    }

    static func loadSidebarWidth() -> CGFloat {
        guard UserDefaults.standard.object(forKey: Key.sidebarWidth) != nil else {
            return defaultSidebarWidth
        }

        return clampSidebarWidth(UserDefaults.standard.double(forKey: Key.sidebarWidth))
    }

    static func saveSidebarWidth(_ width: CGFloat) {
        UserDefaults.standard.set(clampSidebarWidth(width), forKey: Key.sidebarWidth)
    }

    static func loadSidebarVisibleLocationIDs() -> Set<SidebarLocationID> {
        guard let rawIDs = UserDefaults.standard.stringArray(forKey: Key.sidebarVisibleLocationIDs) else {
            return defaultSidebarLocationIDs
        }

        return Set(rawIDs.compactMap(SidebarLocationID.init(rawValue:)))
    }

    static func saveSidebarVisibleLocationIDs(_ ids: Set<SidebarLocationID>) {
        let rawIDs = SidebarLocationID.allCases
            .filter { ids.contains($0) }
            .map(\.rawValue)
        UserDefaults.standard.set(rawIDs, forKey: Key.sidebarVisibleLocationIDs)
    }

    static func loadShowFolderCards() -> Bool {
        guard UserDefaults.standard.object(forKey: Key.showFolderCards) != nil else {
            return defaultShowFolderCards
        }

        return UserDefaults.standard.bool(forKey: Key.showFolderCards)
    }

    static func saveShowFolderCards(_ isVisible: Bool) {
        UserDefaults.standard.set(isVisible, forKey: Key.showFolderCards)
    }

    static func clampGlassOpacity(_ opacity: Double) -> Double {
        min(glassOpacityRange.upperBound, max(glassOpacityRange.lowerBound, opacity))
    }

    static func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(sidebarWidthRange.upperBound, max(sidebarWidthRange.lowerBound, width))
    }
}

enum LightboxLocalization {
    static func text(_ key: LightboxTextKey, language: LightboxLanguage) -> String {
        switch language.resolved {
        case .english:
            return english[key] ?? key.rawValue
        case .simplifiedChinese:
            return simplifiedChinese[key] ?? english[key] ?? key.rawValue
        case .japanese:
            return japanese[key] ?? english[key] ?? key.rawValue
        }
    }

    static func hasTranslation(_ key: LightboxTextKey, language: LightboxResolvedLanguage) -> Bool {
        switch language {
        case .english:
            return english[key] != nil
        case .simplifiedChinese:
            return simplifiedChinese[key] != nil
        case .japanese:
            return japanese[key] != nil
        }
    }

    static func selectedCount(_ count: Int, language: LightboxLanguage) -> String {
        switch language.resolved {
        case .english:
            return "\(count) selected"
        case .simplifiedChinese:
            return "已选择 \(count) 项"
        case .japanese:
            return "\(count)件を選択"
        }
    }

    static func preparingPreviews(_ processed: Int?, total: Int?, language: LightboxLanguage) -> String {
        let base = text(.preparingPreviews, language: language)
        guard let processed, let total else {
            return base
        }
        return "\(base) \(min(processed, total))/\(total)"
    }

    static func colorTagName(_ tagName: String, language: LightboxLanguage) -> String {
        switch language.resolved {
        case .english:
            return englishColorTags[tagName] ?? tagName
        case .simplifiedChinese:
            return simplifiedChineseColorTags[tagName] ?? englishColorTags[tagName] ?? tagName
        case .japanese:
            return japaneseColorTags[tagName] ?? englishColorTags[tagName] ?? tagName
        }
    }

    static func filterColorTag(_ tagName: String, language: LightboxLanguage) -> String {
        let colorName = colorTagName(tagName, language: language)
        switch language.resolved {
        case .english:
            return "Filter \(colorName)"
        case .simplifiedChinese:
            return "筛选\(colorName)标签"
        case .japanese:
            return "\(colorName)タグで絞り込み"
        }
    }

    private static let english: [LightboxTextKey: String] = [
        .about: "About",
        .addSelectedToCompareTray: "Add Selected to Compare Tray",
        .addToCompareTray: "Add to Compare Tray",
        .appearance: "Appearance",
        .appDescription: "Native image library and comparison workspace.",
        .assetMenu: "Asset",
        .alreadyUpToDate: "Lightbox is up to date",
        .alreadyUpToDateMessage: "You are on the latest version (%@).",
        .alreadyUpToDateStatus: "Current: %@",
        .checkForUpdates: "Check for Updates",
        .checkingForUpdates: "Checking...",
        .chooseLibraryFolder: "Choose Library Folder...",
        .clear: "Clear",
        .clearCompareTray: "Clear Compare Tray",
        .close: "Close",
        .closeComparison: "Close Comparison",
        .closeFilters: "Close filters",
        .closeSidebar: "Close Sidebar",
        .colorMode: "Color Mode",
        .compare: "Compare",
        .compareSelection: "Compare Selection",
        .copy: "Copy",
        .copyPath: "Copy Path",
        .custom: "Custom",
        .customColor: "Custom Color",
        .dark: "Dark",
        .defaultApp: "Default",
        .downloadingUpdate: "Downloading update...",
        .dropImagesToImport: "Drop images to import",
        .english: "English",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .githubReserved: "Reserved",
        .goToParentFolder: "Go to parent folder",
        .folderTileWidth: "Folder tile width",
        .grid: "Grid",
        .hoverGlow: "Hover Glow",
        .importImages: "Import Images...",
        .installUpdate: "Install Update",
        .installingUpdate: "Installing update...",
        .japanese: "日本語",
        .language: "Language",
        .library: "Library",
        .light: "Light",
        .liquidGlassOpacity: "Liquid Glass Opacity",
        .masonry: "Masonry",
        .moveToTrash: "Move to Trash",
        .noImagesHere: "No images here",
        .noMatches: "No matches",
        .openFilters: "Open filters",
        .openFolder: "Add Folder...",
        .openFullDiskAccess: "Open Full Disk Access",
        .openSidebar: "Open Sidebar",
        .openWith: "Open With",
        .other: "Other...",
        .path: "Path",
        .pinCurrentPath: "Pin Current Path",
        .preparingPreviews: "Preparing previews",
        .refreshLibrary: "Refresh",
        .remove: "Remove",
        .restore: "Restore",
        .scanningFolder: "Scanning folder",
        .search: "Search",
        .settings: "Settings",
        .share: "Share...",
        .showInFinder: "Show in Finder",
        .showApplications: "Show Applications",
        .showDesktop: "Show Desktop",
        .showDocuments: "Show Documents",
        .showDownloads: "Show Downloads",
        .showFolderCards: "Show Folder Cards",
        .showICloudDrive: "Show iCloud Drive",
        .showMovies: "Show Movies",
        .showMusic: "Show Music",
        .showPictures: "Show Pictures",
        .showVolumes: "Show Volumes",
        .sidebar: "Sidebar",
        .sidebarWidth: "Sidebar Width",
        .simplifiedChinese: "简体中文",
        .switchToGrid: "Switch to grid",
        .switchToMasonry: "Switch to masonry",
        .sort: "Sort",
        .sortAscending: "Ascending",
        .sortBy: "Sort By",
        .sortDescending: "Descending",
        .sortFileName: "File Name",
        .sortSize: "Size",
        .sortTag: "Tag",
        .sortTime: "Time",
        .sortType: "Type",
        .system: "System",
        .trash: "Trash",
        .trashAccessDenied: "Allow Full Disk Access to view system Trash",
        .unpinFolder: "Unpin Folder",
        .updateAvailable: "Update Available",
        .updateAvailableMessage: "Lightbox %@ is available. Install it now? The app will restart.",
        .updateAvailableStatus: "Available: %@",
        .updateCheckFailed: "Update failed",
        .updates: "Updates",
        .version: "Version"
    ]

    private static let simplifiedChinese: [LightboxTextKey: String] = [
        .about: "关于",
        .addSelectedToCompareTray: "加入对比暂存区",
        .addToCompareTray: "加入对比暂存区",
        .appearance: "外观",
        .appDescription: "原生图片图库与对比工作区。",
        .assetMenu: "图片",
        .alreadyUpToDate: "Lightbox 已是最新版",
        .alreadyUpToDateMessage: "当前已经是最新版本（%@）。",
        .alreadyUpToDateStatus: "当前版本：%@",
        .checkForUpdates: "检查更新",
        .checkingForUpdates: "正在检查...",
        .chooseLibraryFolder: "选择图库目录...",
        .clear: "清除",
        .clearCompareTray: "清空对比暂存区",
        .close: "关闭",
        .closeComparison: "关闭对比",
        .closeFilters: "收起筛选",
        .closeSidebar: "收起侧边栏",
        .colorMode: "颜色模式",
        .compare: "对比",
        .compareSelection: "对比所选图片",
        .copy: "复制",
        .copyPath: "复制路径",
        .custom: "自定义",
        .customColor: "自定义颜色",
        .dark: "深色",
        .defaultApp: "默认",
        .downloadingUpdate: "正在下载更新...",
        .dropImagesToImport: "松开以导入图片",
        .english: "English",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .githubReserved: "预留",
        .goToParentFolder: "返回上级文件夹",
        .folderTileWidth: "文件夹胶囊宽度",
        .grid: "网格",
        .hoverGlow: "悬停光晕",
        .importImages: "导入图片...",
        .installUpdate: "安装更新",
        .installingUpdate: "正在安装更新...",
        .japanese: "日本語",
        .language: "语言",
        .library: "图库",
        .light: "浅色",
        .liquidGlassOpacity: "Liquid Glass 透明度",
        .masonry: "瀑布流",
        .moveToTrash: "移到废纸篓",
        .noImagesHere: "这里还没有图片",
        .noMatches: "没有匹配的图片",
        .openFilters: "打开筛选",
        .openFolder: "添加文件夹...",
        .openFullDiskAccess: "打开完全磁盘访问权限",
        .openSidebar: "打开侧边栏",
        .openWith: "打开方式",
        .other: "其他...",
        .path: "路径",
        .pinCurrentPath: "固定当前路径",
        .preparingPreviews: "准备预览",
        .refreshLibrary: "刷新",
        .remove: "移除",
        .restore: "恢复",
        .scanningFolder: "正在扫描文件夹",
        .search: "搜索",
        .settings: "设置",
        .share: "分享...",
        .showInFinder: "在 Finder 中显示",
        .showApplications: "显示应用程序",
        .showDesktop: "显示桌面",
        .showDocuments: "显示文稿",
        .showDownloads: "显示下载",
        .showFolderCards: "显示文件夹卡片",
        .showICloudDrive: "显示 iCloud Drive",
        .showMovies: "显示影片",
        .showMusic: "显示音乐",
        .showPictures: "显示图片",
        .showVolumes: "显示磁盘",
        .sidebar: "侧边栏",
        .sidebarWidth: "侧边栏宽度",
        .simplifiedChinese: "简体中文",
        .switchToGrid: "切换到网格",
        .switchToMasonry: "切换到瀑布流",
        .sort: "排序",
        .sortAscending: "正序",
        .sortBy: "排序方式",
        .sortDescending: "倒序",
        .sortFileName: "文件名",
        .sortSize: "大小",
        .sortTag: "标签",
        .sortTime: "时间",
        .sortType: "类型",
        .system: "跟随系统",
        .trash: "废纸篓",
        .trashAccessDenied: "允许完全磁盘访问后才能查看系统废纸篓",
        .unpinFolder: "取消固定文件夹",
        .updateAvailable: "发现新版本",
        .updateAvailableMessage: "Lightbox %@ 可用。现在安装吗？应用会自动重启。",
        .updateAvailableStatus: "可更新：%@",
        .updateCheckFailed: "更新失败",
        .updates: "更新",
        .version: "版本"
    ]

    private static let japanese: [LightboxTextKey: String] = [
        .about: "情報",
        .addSelectedToCompareTray: "選択項目を比較トレイに追加",
        .addToCompareTray: "比較トレイに追加",
        .appearance: "外観",
        .appDescription: "ネイティブ画像ライブラリと比較ワークスペース。",
        .assetMenu: "画像",
        .alreadyUpToDate: "Lightbox は最新です",
        .alreadyUpToDateMessage: "現在のバージョンは最新です（%@）。",
        .alreadyUpToDateStatus: "現在: %@",
        .checkForUpdates: "アップデートを確認",
        .checkingForUpdates: "確認中...",
        .chooseLibraryFolder: "ライブラリフォルダを選択...",
        .clear: "クリア",
        .clearCompareTray: "比較トレイをクリア",
        .close: "閉じる",
        .closeComparison: "比較を閉じる",
        .closeFilters: "フィルタを閉じる",
        .closeSidebar: "サイドバーを閉じる",
        .colorMode: "カラーモード",
        .compare: "比較",
        .compareSelection: "選択項目を比較",
        .copy: "コピー",
        .copyPath: "パスをコピー",
        .custom: "カスタム",
        .customColor: "カスタムカラー",
        .dark: "ダーク",
        .defaultApp: "デフォルト",
        .downloadingUpdate: "アップデートをダウンロード中...",
        .dropImagesToImport: "画像をドロップして読み込む",
        .english: "English",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .githubReserved: "予約済み",
        .goToParentFolder: "親フォルダへ移動",
        .folderTileWidth: "フォルダの幅",
        .grid: "グリッド",
        .hoverGlow: "ホバーグロー",
        .importImages: "画像を読み込む...",
        .installUpdate: "アップデートをインストール",
        .installingUpdate: "アップデートをインストール中...",
        .japanese: "日本語",
        .language: "言語",
        .library: "ライブラリ",
        .light: "ライト",
        .liquidGlassOpacity: "Liquid Glass の透明度",
        .masonry: "メイソンリー",
        .moveToTrash: "ゴミ箱に移動",
        .noImagesHere: "ここには画像がありません",
        .noMatches: "一致する画像がありません",
        .openFilters: "フィルタを開く",
        .openFolder: "フォルダを追加...",
        .openFullDiskAccess: "フルディスクアクセスを開く",
        .openSidebar: "サイドバーを開く",
        .openWith: "このアプリケーションで開く",
        .other: "その他...",
        .path: "パス",
        .pinCurrentPath: "現在のパスを固定",
        .preparingPreviews: "プレビューを準備中",
        .refreshLibrary: "更新",
        .remove: "削除",
        .restore: "復元",
        .scanningFolder: "フォルダをスキャン中",
        .search: "検索",
        .settings: "設定",
        .share: "共有...",
        .showInFinder: "Finder に表示",
        .showApplications: "アプリケーションを表示",
        .showDesktop: "デスクトップを表示",
        .showDocuments: "書類を表示",
        .showDownloads: "ダウンロードを表示",
        .showFolderCards: "フォルダカードを表示",
        .showICloudDrive: "iCloud Drive を表示",
        .showMovies: "ムービーを表示",
        .showMusic: "ミュージックを表示",
        .showPictures: "ピクチャを表示",
        .showVolumes: "ボリュームを表示",
        .sidebar: "サイドバー",
        .sidebarWidth: "サイドバー幅",
        .simplifiedChinese: "简体中文",
        .switchToGrid: "グリッドに切り替え",
        .switchToMasonry: "メイソンリーに切り替え",
        .sort: "並べ替え",
        .sortAscending: "昇順",
        .sortBy: "並べ替え",
        .sortDescending: "降順",
        .sortFileName: "ファイル名",
        .sortSize: "サイズ",
        .sortTag: "タグ",
        .sortTime: "時刻",
        .sortType: "種類",
        .system: "システム",
        .trash: "ゴミ箱",
        .trashAccessDenied: "システムのゴミ箱を表示するにはフルディスクアクセスを許可してください",
        .unpinFolder: "フォルダの固定を解除",
        .updateAvailable: "アップデートがあります",
        .updateAvailableMessage: "Lightbox %@ を利用できます。今すぐインストールしますか？アプリは再起動します。",
        .updateAvailableStatus: "利用可能: %@",
        .updateCheckFailed: "アップデートに失敗しました",
        .updates: "アップデート",
        .version: "バージョン"
    ]

    private static let englishColorTags: [String: String] = [
        "Red": "Red",
        "Orange": "Orange",
        "Yellow": "Yellow",
        "Green": "Green",
        "Blue": "Blue",
        "Purple": "Purple",
        "Gray": "Gray"
    ]

    private static let simplifiedChineseColorTags: [String: String] = [
        "Red": "红色",
        "Orange": "橙色",
        "Yellow": "黄色",
        "Green": "绿色",
        "Blue": "蓝色",
        "Purple": "紫色",
        "Gray": "灰色"
    ]

    private static let japaneseColorTags: [String: String] = [
        "Red": "赤",
        "Orange": "オレンジ",
        "Yellow": "黄",
        "Green": "緑",
        "Blue": "青",
        "Purple": "紫",
        "Gray": "グレー"
    ]
}
