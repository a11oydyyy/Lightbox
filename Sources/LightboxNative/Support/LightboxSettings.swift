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
    case traditionalChinese
    case japanese

    var id: String { rawValue }

    var resolved: LightboxResolvedLanguage {
        switch self {
        case .system:
            return Self.resolveSystemLanguage(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        case .english:
            return .english
        case .traditionalChinese:
            return .traditionalChinese
        case .simplifiedChinese:
            return .simplifiedChinese
        case .japanese:
            return .japanese
        }
    }
    var locale: Locale {
        switch resolved {
        case .english: return Locale(identifier: "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        case .traditionalChinese: return Locale(identifier: "zh-Hant")
        case .japanese: return Locale(identifier: "ja")
        }
    }

    static func resolveSystemLanguage(identifier: String) -> LightboxResolvedLanguage {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        if parts.first == "zh" {
            if parts.contains("hant") { return .traditionalChinese }
            if parts.contains("hans") { return .simplifiedChinese }
            return parts.contains(where: { ["tw", "hk", "mo"].contains(String($0)) }) ? .traditionalChinese : .simplifiedChinese
        }
        return parts.first == "ja" ? .japanese : .english
    }

}

enum LightboxResolvedLanguage {
    case english
    case simplifiedChinese
    case traditionalChinese
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
    case cancel
    case checkForUpdates
    case checkingForUpdates
    case clear
    case clearCompareTray
    case close
    case closeTab
    case closeComparison
    case closeFilters
    case closeSidebar
    case colorMode
    case compare
    case compareSelection
    case copy
    case copyingFiles
    case copyPath
    case custom
    case customColor
    case dark
    case defaultApp
    case downloadingUpdate
    case english
    case fileTransferCancelled
    case fileTransferComplete
    case fileTransferFailed
    case folderPathPlaceholder
    case folderUnavailable
    case github
    case githubReleases
    case releaseNotes
    case reportIssue
    case automaticallyCheckUpdates
    case automaticUpdateHelp
    case lastUpdateCheck
    case goBack
    case goForward
    case goToFolder
    case goToParentFolder
    case expandedState
    case collapsedState
    case folderTileWidth
    case grid
    case currentFolderScope
    case includeSubfolders
    case includeSubfoldersHelp
    case scanningSubfolders
    case searchingImages
    case recursiveResultsIncomplete
    case hoverGlow
    case installUpdate
    case installingUpdate
    case japanese
    case language
    case light
    case liquidGlassOpacity
    case masonry
    case movingFiles
    case moveToTrash
    case noImagesHere
    case noMatches
    case newTab
    case open
    case openFilters
    case openFolder
    case openFullDiskAccess
    case openInNewTab
    case openSidebar
    case openWith
    case other
    case path
    case pinCurrentPath
    case preparingPreviews
    case previousTab
    case refreshLibrary
    case remove
    case restore
    case scanningFolder
    case search
    case searchResultsLimited
    case nextTab
    case settings
    case share
    case showInFinder
    case startBrowsing
    case startOpenFolder
    case startBrowsingHint
    case recentFolders
    case noPinnedFolders
    case noRecentFolders
    case locateInSidebar
    case showApplications
    case showDesktop
    case showDocuments
    case showDownloads
    case showFolderCards
    case folders
    case showHiddenFiles
    case showICloudDrive
    case showMovies
    case showMusic
    case showPictures
    case showVolumes
    case sidebar
    case sidebarWidth
    case sidebarPinned
    case sidebarLocations
    case sidebarVolumes
    case simplifiedChinese
    case traditionalChinese
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
    case tabs
    case trash
    case trashAccessDenied
    case unpinFolder
    case updateAvailable
    case updateAvailableMessage
    case updateAvailableStatus
    case updateCheckFailed
    case updates
    case imageSize
    case version
}

enum LightboxSettingsStore {
    private enum Key {
        static let colorMode = "Lightbox.colorMode"
        static let language = "Lightbox.language"
        static let sidebarCollapsed = "Lightbox.sidebar.collapsed"
        static let sidebarWidth = "Lightbox.sidebar.width"
        static let sidebarVisibleLocationIDs = "Lightbox.sidebar.visibleLocationIDs"
        static let showFolderCards = "Lightbox.gallery.showFolderCards"
        static let showsHiddenItems = "Lightbox.gallery.showsHiddenItems"
    }

    static let defaultGlassOpacity = 0.85
    static let defaultSidebarCollapsed = true
    static let defaultSidebarWidth: CGFloat = 236
    static let sidebarWidthRange: ClosedRange<CGFloat> = 188...360
    static let defaultSidebarLocationIDs: Set<SidebarLocationID> = Set(SidebarLocationID.allCases)
    static let defaultShowFolderCards = true
    static let defaultShowsHiddenItems = false

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

    static func loadShowsHiddenItems() -> Bool {
        guard UserDefaults.standard.object(forKey: Key.showsHiddenItems) != nil else {
            return defaultShowsHiddenItems
        }

        return UserDefaults.standard.bool(forKey: Key.showsHiddenItems)
    }

    static func saveShowsHiddenItems(_ isVisible: Bool) {
        UserDefaults.standard.set(isVisible, forKey: Key.showsHiddenItems)
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
        case .traditionalChinese:
            return traditionalChinese[key] ?? english[key] ?? key.rawValue
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
        case .traditionalChinese:
            return traditionalChinese[key] != nil
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
        case .traditionalChinese:
            return "已選取 \(count) 個項目"
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
        case .traditionalChinese:
            return traditionalChineseColorTags[tagName] ?? englishColorTags[tagName] ?? tagName
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
        case .traditionalChinese:
            return "篩選\(colorName)標籤"
        case .simplifiedChinese:
            return "筛选\(colorName)标签"
        case .japanese:
            return "\(colorName)タグで絞り込み"
        }
    }

    private static let english: [LightboxTextKey: String] = [
        .imageSize: "Image size",
        .sidebarPinned: "Pinned",
        .sidebarLocations: "Locations",
        .sidebarVolumes: "Volumes",
        .about: "About",
        .addSelectedToCompareTray: "Add Selected to Compare Tray",
        .addToCompareTray: "Add to Compare Tray",
        .appearance: "Appearance",
        .appDescription: "Native image browser and comparison workspace.",
        .assetMenu: "Asset",
        .alreadyUpToDate: "Lightbox is up to date",
        .alreadyUpToDateMessage: "You are on the latest version (%@).",
        .alreadyUpToDateStatus: "Current: %@",
        .cancel: "Cancel",
        .checkForUpdates: "Check for Updates",
        .checkingForUpdates: "Checking...",
        .clear: "Clear",
        .clearCompareTray: "Clear Compare Tray",
        .close: "Close",
        .closeTab: "Close Tab",
        .closeComparison: "Close Comparison",
        .closeFilters: "Close filters",
        .closeSidebar: "Close Sidebar",
        .colorMode: "Color Mode",
        .compare: "Compare",
        .compareSelection: "Compare Selection",
        .copy: "Copy",
        .copyingFiles: "Copying",
        .copyPath: "Copy Path",
        .custom: "Custom",
        .customColor: "Custom Color",
        .dark: "Dark",
        .defaultApp: "Default",
        .downloadingUpdate: "Downloading update...",
        .english: "English",
        .fileTransferCancelled: "File operation cancelled",
        .fileTransferComplete: "File operation complete",
        .fileTransferFailed: "File operation failed",
        .folderPathPlaceholder: "Enter a folder path",
        .folderUnavailable: "Folder not found or unavailable",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .releaseNotes: "Release Notes",
        .reportIssue: "Report an Issue",
        .automaticallyCheckUpdates: "Automatically check for updates",
        .automaticUpdateHelp: "Checks daily in the background. View and install available updates here; installation always requires confirmation.",
        .lastUpdateCheck: "Last checked",
        .goBack: "Back",
        .goForward: "Forward",
        .goToFolder: "Go to Folder...",
        .goToParentFolder: "Go to parent folder",
        .expandedState: "Expanded",
        .collapsedState: "Collapsed",
        .folderTileWidth: "Folder tile width",
        .grid: "Grid",
        .hoverGlow: "Hover Glow",
        .installUpdate: "Install Update",
        .installingUpdate: "Installing update...",
        .japanese: "日本語",
        .language: "Language",
        .light: "Light",
        .liquidGlassOpacity: "Liquid Glass Opacity",
        .currentFolderScope: "This folder",
        .includeSubfolders: "Include subfolders",
        .includeSubfoldersHelp: "Choose whether to browse and search images in this folder only, or in all its subfolders too.",
        .scanningSubfolders: "Scanning subfolders…",
        .searchingImages: "Searching images…",
        .recursiveResultsIncomplete: "Some folders could not be read. The displayed images may be incomplete.",
        .masonry: "Masonry",
        .movingFiles: "Moving",
        .moveToTrash: "Move to Trash",
        .noImagesHere: "No images here",
        .noMatches: "No matches",
        .newTab: "New Tab",
        .openFilters: "Open filters",
        .open: "Open",
        .openFolder: "Add Folder...",
        .openFullDiskAccess: "Open Full Disk Access",
        .openInNewTab: "Open in New Tab",
        .openSidebar: "Open Sidebar",
        .openWith: "Open With",
        .other: "Other...",
        .path: "Path",
        .pinCurrentPath: "Pin Current Path",
        .preparingPreviews: "Preparing previews",
        .previousTab: "Previous Tab",
        .refreshLibrary: "Refresh",
        .remove: "Remove",
        .restore: "Restore",
        .scanningFolder: "Scanning folder",
        .search: "Search",
        .searchResultsLimited: "Some results are hidden. Narrow the search.",
        .nextTab: "Next Tab",
        .settings: "Settings",
        .share: "Share...",
        .showInFinder: "Show in Finder",
        .locateInSidebar: "Locate in Sidebar",
        .startBrowsing: "Browse your images",
        .startOpenFolder: "Open Folder...",
        .startBrowsingHint: "Choose a folder to begin.",
        .recentFolders: "Recently visited",
        .noPinnedFolders: "Pin folders from the sidebar for quick access.",
        .noRecentFolders: "Folders you open will appear here.",
        .showApplications: "Show Applications",
        .showDesktop: "Show Desktop",
        .showDocuments: "Show Documents",
        .showDownloads: "Show Downloads",
        .showFolderCards: "Show Folders",
        .folders: "Folders",
        .showHiddenFiles: "Show Hidden Files",
        .showICloudDrive: "Show iCloud Drive",
        .showMovies: "Show Movies",
        .showMusic: "Show Music",
        .showPictures: "Show Pictures",
        .showVolumes: "Show Volumes",
        .sidebar: "Sidebar",
        .sidebarWidth: "Sidebar Width",
        .simplifiedChinese: "简体中文",
        .traditionalChinese: "繁體中文",
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
        .tabs: "Tabs",
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
        .imageSize: "图片大小",
        .sidebarPinned: "固定",
        .sidebarLocations: "位置",
        .sidebarVolumes: "磁盘",
        .about: "关于",
        .addSelectedToCompareTray: "加入对比暂存区",
        .addToCompareTray: "加入对比暂存区",
        .appearance: "外观",
        .appDescription: "原生图片浏览与对比工作区。",
        .assetMenu: "图片",
        .alreadyUpToDate: "Lightbox 已是最新版",
        .alreadyUpToDateMessage: "当前已经是最新版本（%@）。",
        .alreadyUpToDateStatus: "当前版本：%@",
        .cancel: "取消",
        .checkForUpdates: "检查更新",
        .checkingForUpdates: "正在检查...",
        .clear: "清除",
        .clearCompareTray: "清空对比暂存区",
        .close: "关闭",
        .closeTab: "关闭标签页",
        .closeComparison: "关闭对比",
        .closeFilters: "收起筛选",
        .closeSidebar: "收起侧边栏",
        .colorMode: "颜色模式",
        .compare: "对比",
        .compareSelection: "对比所选图片",
        .copy: "复制",
        .copyingFiles: "正在复制",
        .copyPath: "复制路径",
        .custom: "自定义",
        .customColor: "自定义颜色",
        .dark: "深色",
        .defaultApp: "默认",
        .downloadingUpdate: "正在下载更新...",
        .english: "English",
        .fileTransferCancelled: "文件操作已取消",
        .fileTransferComplete: "文件操作已完成",
        .fileTransferFailed: "文件操作失败",
        .folderPathPlaceholder: "输入文件夹路径",
        .folderUnavailable: "找不到文件夹或无法访问",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .releaseNotes: "更新日志",
        .reportIssue: "反馈问题",
        .automaticallyCheckUpdates: "自动检查更新",
        .automaticUpdateHelp: "每天在后台检查，可在此查看并安装新版；安装前始终需要确认。",
        .lastUpdateCheck: "最近检查",
        .goBack: "后退",
        .goForward: "前进",
        .goToFolder: "前往文件夹...",
        .goToParentFolder: "返回上级文件夹",
        .expandedState: "已展开",
        .collapsedState: "已收起",
        .folderTileWidth: "文件夹胶囊宽度",
        .grid: "网格",
        .hoverGlow: "悬停光晕",
        .installUpdate: "安装更新",
        .installingUpdate: "正在安装更新...",
        .japanese: "日本語",
        .language: "语言",
        .light: "浅色",
        .liquidGlassOpacity: "Liquid Glass 透明度",
        .currentFolderScope: "当前文件夹",
        .includeSubfolders: "包含子文件夹",
        .includeSubfoldersHelp: "切换浏览和搜索范围：仅当前文件夹，或包含所有子文件夹中的图片。",
        .scanningSubfolders: "正在扫描子文件夹…",
        .searchingImages: "正在搜索图片…",
        .recursiveResultsIncomplete: "部分文件夹无法读取，当前显示的图片可能不完整。",
        .masonry: "瀑布流",
        .movingFiles: "正在搬移",
        .moveToTrash: "移到废纸篓",
        .noImagesHere: "这里还没有图片",
        .noMatches: "没有匹配结果",
        .newTab: "新建标签页",
        .openFilters: "打开筛选",
        .open: "打开",
        .openFolder: "添加文件夹...",
        .openFullDiskAccess: "打开完全磁盘访问权限",
        .openInNewTab: "在新标签页中打开",
        .openSidebar: "打开侧边栏",
        .openWith: "打开方式",
        .other: "其他...",
        .path: "路径",
        .pinCurrentPath: "固定当前路径",
        .preparingPreviews: "准备预览",
        .previousTab: "上一个标签页",
        .refreshLibrary: "刷新",
        .remove: "移除",
        .restore: "恢复",
        .scanningFolder: "正在扫描文件夹",
        .search: "搜索",
        .searchResultsLimited: "结果可能不完整，请缩小关键词",
        .nextTab: "下一个标签页",
        .settings: "设置",
        .share: "分享...",
        .showInFinder: "在 Finder 中显示",
        .locateInSidebar: "在侧栏中定位",
        .startBrowsing: "开始浏览",
        .startOpenFolder: "打开文件夹...",
        .startBrowsingHint: "从一个文件夹开始。",
        .recentFolders: "最近访问",
        .noPinnedFolders: "将常用文件夹固定到侧栏，方便再次打开。",
        .noRecentFolders: "打开过的文件夹会显示在这里。",
        .showApplications: "显示应用程序",
        .showDesktop: "显示桌面",
        .showDocuments: "显示文稿",
        .showDownloads: "显示下载",
        .showFolderCards: "显示文件夹",
        .folders: "文件夹",
        .showHiddenFiles: "显示隐藏文件",
        .showICloudDrive: "显示 iCloud Drive",
        .showMovies: "显示影片",
        .showMusic: "显示音乐",
        .showPictures: "显示图片",
        .showVolumes: "显示磁盘",
        .sidebar: "侧边栏",
        .sidebarWidth: "侧边栏宽度",
        .simplifiedChinese: "简体中文",
        .traditionalChinese: "繁體中文",
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
        .tabs: "标签页",
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

    private static let traditionalChinese: [LightboxTextKey: String] = [
        .imageSize: "圖片大小",
        .sidebarPinned: "固定",
        .sidebarLocations: "位置",
        .sidebarVolumes: "磁碟",
        .about: "關於",
        .addSelectedToCompareTray: "加入比較暫存區",
        .addToCompareTray: "加入比較暫存區",
        .appearance: "外觀",
        .appDescription: "原生圖片瀏覽與比較工作區。",
        .assetMenu: "圖片",
        .alreadyUpToDate: "Lightbox 已是最新版",
        .alreadyUpToDateMessage: "目前已經是最新版本（%@）。",
        .alreadyUpToDateStatus: "目前版本：%@",
        .cancel: "取消",
        .checkForUpdates: "檢查更新",
        .checkingForUpdates: "正在檢查...",
        .clear: "清除",
        .clearCompareTray: "清空比較暫存區",
        .close: "關閉",
        .closeTab: "關閉標籤頁",
        .closeComparison: "關閉比較",
        .closeFilters: "收起篩選",
        .closeSidebar: "收起側邊欄",
        .colorMode: "顏色模式",
        .compare: "比較",
        .compareSelection: "比較所選圖片",
        .copy: "複製",
        .copyingFiles: "正在複製",
        .copyPath: "複製路徑",
        .custom: "自訂",
        .customColor: "自訂顏色",
        .dark: "深色",
        .defaultApp: "預設",
        .downloadingUpdate: "正在下載更新...",
        .english: "English",
        .fileTransferCancelled: "檔案操作已取消",
        .fileTransferComplete: "檔案操作已完成",
        .fileTransferFailed: "檔案操作失敗",
        .folderPathPlaceholder: "輸入資料夾路徑",
        .folderUnavailable: "找不到資料夾或無法存取",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .releaseNotes: "更新日誌",
        .reportIssue: "回報問題",
        .automaticallyCheckUpdates: "自動檢查更新",
        .automaticUpdateHelp: "每天在後台檢查，可在此查看並安裝新版；安裝前始終需要確認。",
        .lastUpdateCheck: "最近檢查",
        .goBack: "後退",
        .goForward: "前進",
        .goToFolder: "前往資料夾...",
        .goToParentFolder: "返回上級資料夾",
        .expandedState: "已展開",
        .collapsedState: "已收起",
        .folderTileWidth: "資料夾膠囊寬度",
        .grid: "網格",
        .hoverGlow: "懸停光暈",
        .installUpdate: "安裝更新",
        .installingUpdate: "正在安裝更新...",
        .japanese: "日本語",
        .language: "語言",
        .light: "淺色",
        .liquidGlassOpacity: "Liquid Glass 透明度",
        .currentFolderScope: "目前資料夾",
        .includeSubfolders: "包含子資料夾",
        .includeSubfoldersHelp: "切換瀏覽和搜尋範圍：僅目前資料夾，或包含所有子資料夾中的圖片。",
        .scanningSubfolders: "正在掃描子資料夾…",
        .searchingImages: "正在搜尋圖片…",
        .recursiveResultsIncomplete: "部分資料夾無法讀取，目前顯示的圖片可能不完整。",
        .masonry: "瀑布流",
        .movingFiles: "正在搬移",
        .moveToTrash: "移到廢紙簍",
        .noImagesHere: "這裡還沒有圖片",
        .noMatches: "沒有符合的結果",
        .newTab: "新增標籤頁",
        .openFilters: "開啟篩選",
        .open: "開啟",
        .openFolder: "加入資料夾...",
        .openFullDiskAccess: "開啟完整磁碟取用權限",
        .openInNewTab: "在新標籤頁中開啟",
        .openSidebar: "開啟側邊欄",
        .openWith: "開啟方式",
        .other: "其他...",
        .path: "路徑",
        .pinCurrentPath: "固定目前路徑",
        .preparingPreviews: "準備預覽",
        .previousTab: "上一個標籤頁",
        .refreshLibrary: "重新整理",
        .remove: "移除",
        .restore: "回復",
        .scanningFolder: "正在掃描資料夾",
        .search: "搜尋",
        .searchResultsLimited: "結果可能不完整，請縮小關鍵字",
        .nextTab: "下一個標籤頁",
        .settings: "設定",
        .share: "分享...",
        .showInFinder: "在 Finder 中顯示",
        .locateInSidebar: "在側欄中定位",
        .startBrowsing: "開始瀏覽",
        .startOpenFolder: "開啟資料夾...",
        .startBrowsingHint: "從一個資料夾開始。",
        .recentFolders: "最近開啟",
        .noPinnedFolders: "將常用資料夾固定到側欄，方便再次開啟。",
        .noRecentFolders: "開啟過的資料夾會顯示在這裡。",
        .showApplications: "顯示應用程式",
        .showDesktop: "顯示桌面",
        .showDocuments: "顯示文稿",
        .showDownloads: "顯示下載",
        .showFolderCards: "顯示資料夾",
        .folders: "資料夾",
        .showHiddenFiles: "顯示隱藏檔案",
        .showICloudDrive: "顯示 iCloud Drive",
        .showMovies: "顯示影片",
        .showMusic: "顯示音樂",
        .showPictures: "顯示圖片",
        .showVolumes: "顯示磁碟",
        .sidebar: "側邊欄",
        .sidebarWidth: "側邊欄寬度",
        .simplifiedChinese: "简体中文",
        .traditionalChinese: "繁體中文",
        .switchToGrid: "切換到網格",
        .switchToMasonry: "切換到瀑布流",
        .sort: "排序",
        .sortAscending: "正序",
        .sortBy: "排序方式",
        .sortDescending: "倒序",
        .sortFileName: "檔名",
        .sortSize: "大小",
        .sortTag: "標籤",
        .sortTime: "時間",
        .sortType: "類型",
        .system: "跟隨系統",
        .tabs: "標籤頁",
        .trash: "廢紙簍",
        .trashAccessDenied: "允許完整磁碟取用後才能查看系統廢紙簍",
        .unpinFolder: "取消固定資料夾",
        .updateAvailable: "發現新版本",
        .updateAvailableMessage: "Lightbox %@ 可用。現在安裝嗎？應用會自動重新啟動。",
        .updateAvailableStatus: "可更新：%@",
        .updateCheckFailed: "更新失敗",
        .updates: "更新",
        .version: "版本"
    ]

    private static let japanese: [LightboxTextKey: String] = [
        .imageSize: "画像サイズ",
        .sidebarPinned: "固定",
        .sidebarLocations: "場所",
        .sidebarVolumes: "ディスク",
        .about: "情報",
        .addSelectedToCompareTray: "選択項目を比較トレイに追加",
        .addToCompareTray: "比較トレイに追加",
        .appearance: "外観",
        .appDescription: "ネイティブ画像ブラウザと比較ワークスペース。",
        .assetMenu: "画像",
        .alreadyUpToDate: "Lightbox は最新です",
        .alreadyUpToDateMessage: "現在のバージョンは最新です（%@）。",
        .alreadyUpToDateStatus: "現在: %@",
        .cancel: "キャンセル",
        .checkForUpdates: "アップデートを確認",
        .checkingForUpdates: "確認中...",
        .clear: "クリア",
        .clearCompareTray: "比較トレイをクリア",
        .close: "閉じる",
        .closeTab: "タブを閉じる",
        .closeComparison: "比較を閉じる",
        .closeFilters: "フィルタを閉じる",
        .closeSidebar: "サイドバーを閉じる",
        .colorMode: "カラーモード",
        .compare: "比較",
        .compareSelection: "選択項目を比較",
        .copy: "コピー",
        .copyingFiles: "コピー中",
        .copyPath: "パスをコピー",
        .custom: "カスタム",
        .customColor: "カスタムカラー",
        .dark: "ダーク",
        .defaultApp: "デフォルト",
        .downloadingUpdate: "アップデートをダウンロード中...",
        .english: "English",
        .fileTransferCancelled: "ファイル操作をキャンセルしました",
        .fileTransferComplete: "ファイル操作が完了しました",
        .fileTransferFailed: "ファイル操作に失敗しました",
        .folderPathPlaceholder: "フォルダのパスを入力",
        .folderUnavailable: "フォルダが見つからないか、アクセスできません",
        .github: "GitHub",
        .githubReleases: "GitHub Releases",
        .releaseNotes: "リリースノート",
        .reportIssue: "問題を報告",
        .automaticallyCheckUpdates: "アップデートを自動確認",
        .automaticUpdateHelp: "毎日バックグラウンドで確認します。新しいバージョンはここからインストールでき、必ず確認が必要です。",
        .lastUpdateCheck: "前回の確認",
        .goBack: "戻る",
        .goForward: "進む",
        .goToFolder: "フォルダへ移動...",
        .goToParentFolder: "親フォルダへ移動",
        .expandedState: "展開済み",
        .collapsedState: "折りたたみ",
        .folderTileWidth: "フォルダの幅",
        .grid: "グリッド",
        .hoverGlow: "ホバーグロー",
        .installUpdate: "アップデートをインストール",
        .installingUpdate: "アップデートをインストール中...",
        .japanese: "日本語",
        .language: "言語",
        .light: "ライト",
        .liquidGlassOpacity: "Liquid Glass の透明度",
        .currentFolderScope: "現在のフォルダ",
        .includeSubfolders: "サブフォルダを含む",
        .includeSubfoldersHelp: "現在のフォルダ内だけ、またはすべてのサブフォルダ内の画像も表示・検索します。",
        .scanningSubfolders: "サブフォルダをスキャン中…",
        .searchingImages: "画像を検索中…",
        .recursiveResultsIncomplete: "一部のフォルダを読み取れません。画像がすべて表示されていない可能性があります。",
        .masonry: "メイソンリー",
        .movingFiles: "移動中",
        .moveToTrash: "ゴミ箱に移動",
        .noImagesHere: "ここには画像がありません",
        .noMatches: "一致する項目がありません",
        .newTab: "新規タブ",
        .openFilters: "フィルタを開く",
        .open: "開く",
        .openFolder: "フォルダを追加...",
        .openFullDiskAccess: "フルディスクアクセスを開く",
        .openInNewTab: "新しいタブで開く",
        .openSidebar: "サイドバーを開く",
        .openWith: "このアプリケーションで開く",
        .other: "その他...",
        .path: "パス",
        .pinCurrentPath: "現在のパスを固定",
        .preparingPreviews: "プレビューを準備中",
        .previousTab: "前のタブ",
        .refreshLibrary: "更新",
        .remove: "削除",
        .restore: "復元",
        .scanningFolder: "フォルダをスキャン中",
        .search: "検索",
        .searchResultsLimited: "一部の結果が非表示です。検索語を絞り込んでください。",
        .nextTab: "次のタブ",
        .settings: "設定",
        .share: "共有...",
        .showInFinder: "Finder に表示",
        .locateInSidebar: "サイドバーで表示",
        .startBrowsing: "画像をブラウズ",
        .startOpenFolder: "フォルダを開く...",
        .startBrowsingHint: "フォルダを選んで始めましょう。",
        .recentFolders: "最近のフォルダ",
        .noPinnedFolders: "よく使うフォルダをサイドバーに固定できます。",
        .noRecentFolders: "開いたフォルダがここに表示されます。",
        .showApplications: "アプリケーションを表示",
        .showDesktop: "デスクトップを表示",
        .showDocuments: "書類を表示",
        .showDownloads: "ダウンロードを表示",
        .showFolderCards: "フォルダを表示",
        .folders: "フォルダ",
        .showHiddenFiles: "隠しファイルを表示",
        .showICloudDrive: "iCloud Drive を表示",
        .showMovies: "ムービーを表示",
        .showMusic: "ミュージックを表示",
        .showPictures: "ピクチャを表示",
        .showVolumes: "ボリュームを表示",
        .sidebar: "サイドバー",
        .sidebarWidth: "サイドバー幅",
        .simplifiedChinese: "简体中文",
        .traditionalChinese: "繁體中文",
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
        .tabs: "タブ",
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

    private static let traditionalChineseColorTags: [String: String] = [
        "Red": "紅色", "Orange": "橙色", "Yellow": "黃色", "Green": "綠色",
        "Blue": "藍色", "Purple": "紫色", "Gray": "灰色"
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
