import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GlassSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedPaths: Set<String> = []
    @State private var pendingReveal: SidebarTreeRowID?
    @State private var availableRows: Set<SidebarTreeRowID> = []
    @State private var recentlyUnpinnedSources: [LibrarySource] = []

    private var visiblePinnedSources: [LibrarySource] {
        var items = appState.pinnedSidebarSources
        for source in recentlyUnpinnedSources where !items.contains(where: { $0.rootURL.standardizedFileURL.path == source.rootURL.standardizedFileURL.path }) {
            items.append(source)
        }
        return items.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        let selectedFolderPath = selectedFolderPath

        VStack(spacing: 0) {
            Color.clear
                .frame(height: 48)
                .background(WindowHeaderDragArea())

            ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    SidebarSection(title: appState.localized(.tabs)) {
                        ForEach(appState.tabs) { tab in
                            SidebarTabRow(tab: tab)
                        }
                        Button { appState.newTab() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: LightboxControlMetrics.iconSize, weight: .medium))
                                .foregroundStyle(LightboxColorTokens.secondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(height: LightboxControlMetrics.iconButtonSize)
                                .contentShape(RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius))
                        }
                        .buttonStyle(LightboxButtonHoverStyle(shape: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius)))
                        .background(LightboxColorTokens.primaryText.opacity(0.04), in: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius))
                        .help("\(appState.localized(.newTab)) (⌘T)")
                        .accessibilityLabel(appState.localized(.newTab))
                        .padding(.top, 4)
                    }

                    if !visiblePinnedSources.isEmpty {
                        SidebarSection(title: appState.localized(.sidebarPinned)) {
                            ForEach(visiblePinnedSources) { source in
                                SidebarPinnedFolderRow(
                                    title: source.displayName,
                                    url: source.rootURL,
                                    systemImage: "folder",
                                    selectedFolderPath: selectedFolderPath,
                                    isPinned: appState.isFolderPinned(source.rootURL),
                                    isRecentlyUnpinned: recentlyUnpinnedSources.contains(where: { $0.id == source.id }),
                                    togglePin: {
                                        togglePin(source: source)
                                    },
                                    canLocate: revealPlan(for: source.rootURL) != nil,
                                    locate: { locateFolder(source.rootURL) }
                                )
                            }
                        }
                    }

                    if !visiblePinnedSources.isEmpty {
                        Rectangle()
                            .fill(LightboxColorTokens.border.opacity(0.65))
                            .frame(height: 0.7)
                            .padding(.horizontal, 12)
                    }

                    let locations = appState.sidebarLocations.filter { $0 != .volumes }
                    if !locations.isEmpty {
                        SidebarSection(title: appState.localized(.sidebarLocations)) {
                            ForEach(locations) { location in
                                if let url = location.defaultURL {
                                    SidebarFolderNode(
                                        title: title(for: location),
                                        url: url,
                                        rootURL: url,
                                        sourceID: "location:\(location.rawValue)",
                                        systemImage: location.systemImage,
                                        depth: 0,
                                        selectedFolderPath: selectedFolderPath,
                                        expandedPaths: $expandedPaths,
                                        isPinned: appState.isFolderPinned(url),
                                        isRecentlyUnpinned: false,
                                        togglePin: {
                                            appState.togglePinFolderURL(url)
                                        }
                                    )
                                }
                            }
                        }
                    }

                    if appState.sidebarVisibleLocationIDs.contains(.volumes), !appState.sidebarVolumes.isEmpty {
                        SidebarSection(title: appState.localized(.sidebarVolumes)) {
                            ForEach(appState.sidebarVolumes) { volume in
                                SidebarFolderNode(
                                    title: volume.displayName,
                                    url: volume.url,
                                    rootURL: volume.url,
                                    sourceID: "volume:\(volume.id)",
                                    systemImage: "externaldrive",
                                    depth: 0,
                                    selectedFolderPath: selectedFolderPath,
                                    expandedPaths: $expandedPaths,
                                    isPinned: appState.isFolderPinned(volume.url),
                                    isRecentlyUnpinned: false,
                                    togglePin: {
                                        appState.togglePinFolderURL(volume.url)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .onPreferenceChange(SidebarTreeRowsKey.self) { rows in
                availableRows = rows
                revealPending(using: scrollProxy, available: rows)
            }
            .onChange(of: pendingReveal) { _ in
                revealPending(using: scrollProxy, available: availableRows)
            }
            }

            Divider()
                .opacity(0.34)
                .padding(.horizontal, 12)

            SidebarTrashRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: appState.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LightboxColorTokens.sidebar.opacity(appState.glassOpacity * 0.9))
        }
        .background(
            .ultraThinMaterial.opacity(appState.glassOpacity),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LightboxColorTokens.border.opacity(GlassTokens.sidebarStrokeOpacity(appState.glassOpacity)), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(GlassTokens.sidebarShadowOpacity(appState.glassOpacity)), radius: 10, y: 3)
        .padding(.leading, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: appState.currentFolderURL) { _ in
            pendingReveal = nil
        }
        .onChange(of: appState.activeTabID) { _ in pendingReveal = nil }
        .onChange(of: appState.selectedFilter) { _ in pendingReveal = nil }
    }

    private var selectedFolderPath: String? {
        guard !appState.isViewingTrash, !appState.isShowingStartPage else { return nil }
        return appState.currentFolderURL.standardizedFileURL.path
    }

    private func title(for location: SidebarLocationID) -> String {
        switch location {
        case .applications:
            "Applications"
        case .desktop:
            "Desktop"
        case .documents:
            "Documents"
        case .downloads:
            "Downloads"
        case .movies:
            "Movies"
        case .music:
            "Music"
        case .pictures:
            "Pictures"
        case .iCloudDrive:
            "iCloud Drive"
        case .volumes:
            "Volumes"
        }
    }

    private func togglePin(source: LibrarySource) {
        let path = source.rootURL.standardizedFileURL.path
        if appState.isFolderPinned(source.rootURL) {
            appState.unpinSource(source.id)
            if !recentlyUnpinnedSources.contains(where: { $0.rootURL.standardizedFileURL.path == path }) {
                recentlyUnpinnedSources.append(source)
            }
        } else {
            appState.pinSource(source, selectPinnedFolder: false)
            recentlyUnpinnedSources.removeAll { $0.rootURL.standardizedFileURL.path == path }
        }
    }

    private func revealPlan(for url: URL) -> SidebarTreeRevealPlan? {
        SidebarTreeRevealPlan(folder: url,
            roots: appState.sidebarLocations.compactMap(\.defaultURL) + appState.sidebarVolumes.map(\.url),
            showsHiddenItems: appState.showsHiddenItems)
    }

    private func locateFolder(_ url: URL) {
        guard let plan = revealPlan(for: url) else { return }
        expandedPaths.formUnion(plan.ancestors)
        pendingReveal = plan.row
    }

    private func revealPending(using proxy: ScrollViewProxy, available: Set<SidebarTreeRowID>) {
        guard let target = pendingReveal, available.contains(target) else { return }
        // Child folders load asynchronously. Scroll only once their actual row
        // has joined the layout, without guessing a loading delay.
        DispatchQueue.main.async {
            guard pendingReveal == target else { return }
            proxy.scrollTo(target, anchor: .center)
            pendingReveal = nil
        }
    }
}

struct SidebarTreeRowID: Hashable {
    var root: String
    var path: String
}

struct SidebarTreeRevealPlan {
    var row: SidebarTreeRowID
    var ancestors: Set<String> = []

    init?(folder: URL, roots: [URL], showsHiddenItems: Bool) {
        let folder = folder.standardizedFileURL
        guard let root = roots.map(\.standardizedFileURL).filter({
            folder.path == $0.path || folder.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/")
        }).max(by: { $0.path.count < $1.path.count }) else { return nil }
        let relativeComponents = folder.pathComponents.dropFirst(root.pathComponents.count)
        guard showsHiddenItems || !relativeComponents.contains(where: { $0.hasPrefix(".") }) else { return nil }
        row = SidebarTreeRowID(root: root.path, path: folder.path)
        var current = folder
        while current.path != root.path {
            current.deleteLastPathComponent()
            ancestors.insert(current.path)
        }
    }
}

private struct SidebarTreeRowsKey: PreferenceKey {
    static let defaultValue: Set<SidebarTreeRowID> = []
    static func reduce(value: inout Set<SidebarTreeRowID>, nextValue: () -> Set<SidebarTreeRowID>) {
        value.formUnion(nextValue())
    }
}

private enum SidebarRowControl: Hashable {
    case folder, disclosure, pin
}

private struct SidebarSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 10)
                .padding(.bottom, 1)

            content
        }
    }
}

private struct SidebarPinnedFolderRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var url: URL
    var systemImage: String
    var selectedFolderPath: String?
    var isPinned: Bool
    var isRecentlyUnpinned: Bool
    var togglePin: () -> Void
    var canLocate: Bool
    var locate: () -> Void

    @State private var isHovering = false
    @FocusState private var focusedControl: SidebarRowControl?
    @State private var colorTags: [String] = []

    private var path: String {
        url.standardizedFileURL.path
    }

    private var isSelected: Bool {
        selectedFolderPath == path
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    appState.openSidebarFolderInNewTab(url)
                } else {
                    appState.openSidebarFolder(url)
                }
            } label: {
                HStack(spacing: 10) {
                    SidebarSymbolIcon(symbol: systemImage, tags: colorTags)

                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    SidebarTagDots(tags: colorTags)
                }
                .foregroundStyle(rowTextColor)
                .padding(.leading, 8)
                .frame(height: 36)
                .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .folder)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(url.path)

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                    togglePin()
                }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? LightboxColorTokens.secondaryText : LightboxColorTokens.mutedText)
                    .frame(width: 22, height: 22)
                    .opacity(isHovering || focusedControl != nil ? 1 : 0)
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
            .focused($focusedControl, equals: .pin)
            .accessibilityLabel(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath))
            .help(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath))
        }
        .padding(.trailing, 6)
        .frame(height: 36)
        .background {
            let shape = RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
            if isSelected {
                shape.fill(LightboxColorTokens.navigationSelection)
                    .transition(.opacity)
            } else if isHovering {
                shape.fill(
                    LightboxColorTokens.primaryText
                        .opacity(LightboxSelectionTokens.hoverFillOpacity)
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
        .contextMenu {
            Button(appState.localized(.open)) {
                appState.openSidebarFolder(url)
            }
            Button(appState.localized(.openInNewTab)) {
                appState.openSidebarFolderInNewTab(url)
            }
            Divider()
            Button(appState.localized(.locateInSidebar), action: locate)
                .disabled(!canLocate)
            Button(appState.localized(.showInFinder)) {
                appState.revealSidebarURLInFinder(url)
            }
            Button(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath)) {
                togglePin()
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isSelected)
        .onHover { hovering in
            withAnimation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
        .task(id: path) {
            await loadColorTags()
        }
    }

    private var rowTextColor: Color {
        if isRecentlyUnpinned {
            return LightboxColorTokens.mutedText
        }
        return isSelected ? LightboxColorTokens.primaryText : LightboxColorTokens.secondaryText
    }

    @MainActor
    private func loadColorTags() async {
        if let cached = SidebarFolderTagCache.shared.cachedTags(for: url) {
            colorTags = cached
            return
        }

        colorTags = []
        let tags = await SidebarFolderTagCache.shared.tags(for: url)
        guard !Task.isCancelled else { return }
        colorTags = tags
    }
}

private struct SidebarFolderNode: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var url: URL
    var rootURL: URL
    var sourceID: String
    var systemImage: String
    var depth: Int
    var selectedFolderPath: String?
    @Binding var expandedPaths: Set<String>
    var isPinned: Bool
    var isRecentlyUnpinned: Bool
    var togglePin: () -> Void

    @State private var children: [LibraryFolderEntry] = []
    @State private var hasLoadedChildren = false
    @State private var isLoadingChildren = false
    @State private var isHovering = false
    @FocusState private var focusedControl: SidebarRowControl?
    @State private var colorTags: [String] = []

    private var path: String {
        url.standardizedFileURL.path
    }

    private var isExpanded: Bool {
        expandedPaths.contains(path)
    }

    private var isSelected: Bool {
        selectedFolderPath == path
    }

    private var childIndent: CGFloat {
        CGFloat(depth) * 13
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
                .id(SidebarTreeRowID(root: rootURL.standardizedFileURL.path, path: path))
                .preference(key: SidebarTreeRowsKey.self,
                    value: [SidebarTreeRowID(root: rootURL.standardizedFileURL.path, path: path)])

            // Keep descendants within their subtree while expanding. Collapse is immediate.
            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(children) { child in
                            SidebarFolderNode(
                                title: child.name,
                                url: child.url,
                                rootURL: rootURL,
                                sourceID: sourceID,
                                systemImage: "folder",
                                depth: depth + 1,
                                selectedFolderPath: selectedFolderPath,
                                expandedPaths: $expandedPaths,
                                isPinned: appState.isFolderPinned(child.url),
                                isRecentlyUnpinned: false,
                                togglePin: {
                                    appState.togglePinFolderURL(child.url)
                                }
                            )
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                    .task(id: "\(path)|hidden:\(appState.showsHiddenItems)") {
                        await loadChildrenIfNeeded(forceReload: true)
                    }
                }
            }
            .compositingGroup()
            .clipped()
        }
        .clipped()
        .animation(isExpanded ? MotionTokens.ifAllowed(MotionTokens.sidebarDisclosure, reduceMotion: reduceMotion) : nil, value: isExpanded)
    }

    private var row: some View {
        HStack(spacing: 4) {
            Button {
                toggleExpanded()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LightboxColorTokens.mutedText)
                    .frame(width: 14, height: 26)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasLoadedChildren || isExpanded ? 1 : 0.72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .disclosure)
            .accessibilityLabel(title)
            .accessibilityValue(appState.localized(isExpanded ? .expandedState : .collapsedState))

            HStack(spacing: 4) {
                Button {
                    if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                        appState.openSidebarFolderInNewTab(url)
                    } else {
                        appState.openSidebarFolder(url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        SidebarSymbolIcon(symbol: systemImage, tags: colorTags)

                        Text(title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 6)

                        SidebarTagDots(tags: colorTags)
                    }
                    .foregroundStyle(rowTextColor)
                    .padding(.leading, 8)
                    .frame(height: 36)
                    .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .folder)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(url.path)

                Button {
                    withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                        togglePin()
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pinColor)
                        .frame(width: 22, height: 22)
                            .opacity(isHovering || focusedControl != nil ? 1 : 0)
                        .contentShape(Circle())
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
                .focused($focusedControl, equals: .pin)
                .accessibilityLabel(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath))
                .help(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath))
            }
            .padding(.trailing, 6)
            .frame(height: 36)
            .background {
                let shape = RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                if isSelected {
                    shape.fill(LightboxColorTokens.navigationSelection)
                        .transition(.opacity)
                } else if isHovering {
                    shape.fill(
                        LightboxColorTokens.primaryText
                            .opacity(LightboxSelectionTokens.hoverFillOpacity)
                    )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            .contextMenu {
                Button(appState.localized(.open)) {
                    appState.openSidebarFolder(url)
                }
                Button(appState.localized(.openInNewTab)) {
                    appState.openSidebarFolderInNewTab(url)
                }
                Divider()
                Button(appState.localized(.showInFinder)) {
                    appState.revealSidebarURLInFinder(url)
                }
                Button(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath)) {
                    togglePin()
                }
            }
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isSelected)
            .onHover { hovering in
                withAnimation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
        }
        .onMoveCommand { direction in
            guard focusedControl != nil else { return }
            if direction == .right, !isExpanded { toggleExpanded() }
            if direction == .left, isExpanded { toggleExpanded() }
        }
        .padding(.leading, childIndent)
        .task(id: path) {
            await loadColorTags()
        }
    }

    private var rowTextColor: Color {
        if isRecentlyUnpinned {
            return LightboxColorTokens.mutedText
        }
        return isSelected ? LightboxColorTokens.primaryText : LightboxColorTokens.secondaryText
    }

    private var pinColor: Color {
        isPinned ? LightboxColorTokens.secondaryText : LightboxColorTokens.mutedText
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            Task {
                await loadChildrenIfNeeded()
            }
        }
    }

    @MainActor
    private func loadChildrenIfNeeded(forceReload: Bool = false) async {
        guard (!hasLoadedChildren || forceReload), (!isLoadingChildren || forceReload) else { return }
        isLoadingChildren = true
        let folderURL = url
        let folderSourceID = sourceID
        let folderRootURL = rootURL
        let showsHiddenItems = appState.showsHiddenItems
        let loadedChildren = await Task.detached(priority: .utility) {
            LocalImageSource.folders(
                in: folderURL,
                sourceID: folderSourceID,
                rootURL: folderRootURL,
                showsHiddenItems: showsHiddenItems
            )
        }.value
        guard !Task.isCancelled else {
            isLoadingChildren = false
            return
        }
        children = loadedChildren
        hasLoadedChildren = true
        isLoadingChildren = false
    }

    @MainActor
    private func loadColorTags() async {
        if let cached = SidebarFolderTagCache.shared.cachedTags(for: url) {
            colorTags = cached
            return
        }

        colorTags = []
        let tags = await SidebarFolderTagCache.shared.tags(for: url)
        guard !Task.isCancelled else { return }
        colorTags = tags
    }
}

private struct SidebarTagDots: View {
    var tags: [String]

    private var visibleTags: [MacColorTag] {
        MacColorTag.all.filter { tags.contains($0.name) }
    }

    var body: some View {
        HStack(spacing: MacTagDotMetrics.sidebarSpacing) {
            ForEach(visibleTags.prefix(3)) { tag in
                Circle()
                    .fill(tag.color)
                    .frame(
                        width: MacTagDotMetrics.sidebarDotDiameter,
                        height: MacTagDotMetrics.sidebarDotDiameter
                    )
            }
        }
        .frame(minWidth: visibleTags.isEmpty ? 0 : 19, alignment: .trailing)
    }
}

private struct SidebarTrashRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isSelected: Bool {
        appState.isViewingTrash
    }

    var body: some View {
        Button {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                appState.openTrashInNewTab()
            } else {
                appState.openTrashFromSidebar()
            }
        } label: {
            HStack(spacing: 10) {
                SidebarSymbolIcon(symbol: "trash")

                Text(appState.localized(.trash))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer()
            }
            .foregroundStyle(isSelected ? LightboxColorTokens.primaryText : LightboxColorTokens.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background {
                let shape = RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                if isSelected {
                    shape.fill(LightboxColorTokens.navigationSelection)
                        .transition(.opacity)
                } else if isHovering {
                    shape.fill(
                        LightboxColorTokens.primaryText
                            .opacity(LightboxSelectionTokens.hoverFillOpacity)
                    )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(
            shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
        ))
        .contextMenu {
            Button(appState.localized(.open)) {
                appState.openTrashFromSidebar()
            }
            Button(appState.localized(.openInNewTab)) {
                appState.openTrashInNewTab()
            }
            Divider()
            Button(appState.localized(.showInFinder)) {
                appState.revealSidebarURLInFinder(LightboxLibraryStore.primarySystemTrashFolder)
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isSelected)
        .onHover { hovering in
            withAnimation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
    }
}

struct SidebarSymbolIcon: View {
    var symbol: String
    var tags: [String] = []
    var url: URL?
    @State private var loadedTags: [String] = []
    private var filledSymbol: String {
        switch symbol {
        case "folder": "folder.fill"
        case "app": "square.stack.3d.up.fill"
        case "doc": "doc.text.fill"
        case "arrow.down.circle": "tray.and.arrow.down.fill"
        case "film": "film.fill"
        case "photo.on.rectangle": "photo.on.rectangle.angled"
        case "icloud": "icloud.fill"
        case "externaldrive": "externaldrive.fill"
        case "trash": "trash.fill"
        default: symbol
        }
    }
    private var color: Color {
        if symbol == "folder" {
            return LightboxColorTokens.folderColor(tags.isEmpty ? loadedTags : tags)
        }
        switch symbol {
        case "arrow.down.circle": return LightboxColorTokens.iconGreen
        case "music.note": return LightboxColorTokens.iconMusicRed
        case "icloud": return LightboxColorTokens.iconCloudBlue
        case "film": return LightboxColorTokens.iconPurple
        case "photo.on.rectangle": return LightboxColorTokens.iconOrange
        case "externaldrive", "trash": return LightboxColorTokens.secondaryText
        default: return LightboxColorTokens.accent
        }
    }
    // Keep each symbol within one hue; layer contrast comes from tonal depth.
    private var palette: (Color, Color, Color) {
        switch symbol {
        case "app":
            return (color, color.opacity(0.65), color.opacity(0.42))
        case "arrow.down.circle":
            return (color, color.opacity(0.55), color.opacity(0.55))
        case "photo.on.rectangle", "desktopcomputer":
            return (color, color.opacity(0.55), color.opacity(0.75))
        default:
            return (color, color, color)
        }
    }
    var body: some View {
        Image(systemName: filledSymbol)
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(symbol == "folder" ? .hierarchical : .palette)
            .foregroundStyle(palette.0, palette.1, palette.2)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url, symbol == "folder" else { return }
                loadedTags = await SidebarFolderTagCache.shared.tags(for: url)
            }
    }
}

private struct SidebarTabRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    var tab: LightboxTab
    @State private var hovering = false
    @State private var fileDropTargetID: UUID?
    private var active: Bool { appState.activeTabID == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            Button { appState.selectTab(tab.id) } label: {
                HStack(spacing: 8) {
                    SidebarSymbolIcon(symbol: tab.isStartPage ? "plus.square" : "folder", url: tab.isStartPage ? nil : tab.folderURL)
                    Text(appState.tabTitle(tab))
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])

            Button { appState.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(active || hovering ? 1 : 0)
            .help(appState.localized(.closeTab))
            .accessibilityLabel(appState.localized(.closeTab))
        }
        .foregroundStyle(LightboxColorTokens.primaryText)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(fileDropTargetID == tab.id ? LightboxColorTokens.accent.opacity(0.16) : (active ? LightboxColorTokens.navigationSelection : LightboxColorTokens.primaryText.opacity(hovering ? LightboxSelectionTokens.hoverFillOpacity : 0)))
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: hovering)
        .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: active)
        .onHover { hovering = $0 }
        .help(appState.tabPath(tab))
        .onDrag {
            appState.beginTabDrag(tab.id)
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.utf8PlainText], isTargeted: nil) { _ in
            appState.moveDraggedTab(before: tab.id)
            appState.endTabDrag()
            return true
        }
        .onDrop(of: [UTType(exportedAs: LightboxPasteboardTypes.internalAssetDragIdentifier)], delegate: TabAssetDropDelegate(targetTabID: tab.id, fileDropTargetID: $fileDropTargetID, appState: appState))
    }
}
