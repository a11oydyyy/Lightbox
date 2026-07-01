import SwiftUI

struct GlassSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedPaths: Set<String> = []
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
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 15) {
                    if !visiblePinnedSources.isEmpty {
                        SidebarSection(title: "Pinned") {
                            ForEach(visiblePinnedSources) { source in
                                SidebarPinnedFolderRow(
                                    title: source.displayName,
                                    url: source.rootURL,
                                    systemImage: "folder",
                                    isPinned: appState.isFolderPinned(source.rootURL),
                                    isRecentlyUnpinned: recentlyUnpinnedSources.contains(where: { $0.id == source.id }),
                                    togglePin: {
                                        togglePin(source: source)
                                    }
                                )
                            }
                        }
                    }

                    let locations = appState.sidebarLocations.filter { $0 != .volumes }
                    if !locations.isEmpty {
                        SidebarSection(title: "Locations") {
                            ForEach(locations) { location in
                                if let url = location.defaultURL {
                                    SidebarFolderNode(
                                        title: title(for: location),
                                        url: url,
                                        rootURL: url,
                                        sourceID: "location:\(location.rawValue)",
                                        systemImage: location.systemImage,
                                        depth: 0,
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
                        SidebarSection(title: "Volumes") {
                            ForEach(appState.sidebarVolumes) { volume in
                                SidebarFolderNode(
                                    title: volume.displayName,
                                    url: volume.url,
                                    rootURL: volume.url,
                                    sourceID: "volume:\(volume.id)",
                                    systemImage: "externaldrive",
                                    depth: 0,
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
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }

            Divider()
                .opacity(0.34)
                .padding(.horizontal, 12)

            SidebarTrashRow()
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
        .frame(width: appState.sidebarWidth)
        .frame(maxHeight: .infinity)
        .lightboxGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        .shadow(color: .black.opacity(GlassTokens.floatingCapsuleShadowOpacity(appState.glassOpacity)), radius: 10, y: 6)
        .padding(.leading, 10)
        .padding(.vertical, 14)
        .onAppear {
            expandCurrentPathChain()
        }
        .onChange(of: appState.currentFolderURL) { _ in
            expandCurrentPathChain()
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.currentFolderURL)
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

    private func expandCurrentPathChain() {
        guard !appState.isViewingTrash else { return }
        let path = appState.currentFolderURL.standardizedFileURL.path
        var expanded = expandedPaths
        for location in appState.sidebarLocations.compactMap(\.defaultURL) {
            let rootPath = location.standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                addAncestors(from: location, to: appState.currentFolderURL, into: &expanded)
            }
        }
        for volume in appState.sidebarVolumes {
            let rootPath = volume.url.standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                addAncestors(from: volume.url, to: appState.currentFolderURL, into: &expanded)
            }
        }
        expandedPaths = expanded
    }

    private func addAncestors(from rootURL: URL, to folderURL: URL, into expanded: inout Set<String>) {
        let rootPath = rootURL.standardizedFileURL.path
        var current = folderURL.standardizedFileURL
        while current.standardizedFileURL.path.hasPrefix(rootPath) {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            let parentPath = parent.path
            if parentPath == current.path || !parentPath.hasPrefix(rootPath) {
                break
            }
            expanded.insert(parentPath)
            current = parent
        }
        expanded.insert(rootPath)
    }
}

private struct SidebarSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.50))
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
    var isPinned: Bool
    var isRecentlyUnpinned: Bool
    var togglePin: () -> Void

    @State private var isHovering = false
    @State private var colorTags: [String] = []
    @AppStorage(LightboxGlowColor.modeKey) private var glowModeRaw = LightboxGlowColor.systemMode
    @AppStorage(LightboxGlowColor.hexKey) private var glowHex = ""

    private var path: String {
        url.standardizedFileURL.path
    }

    private var isSelected: Bool {
        !appState.isViewingTrash && appState.currentFolderURL.standardizedFileURL.path == path
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                appState.openSidebarFolder(url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 18)

                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    SidebarTagDots(tags: colorTags)
                }
                .foregroundStyle(rowTextColor)
                .padding(.leading, 8)
                .frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(url.path)

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                    togglePin()
                }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? Color.primary.opacity(0.66) : Color.primary.opacity(0.42))
                    .frame(width: 22, height: 22)
                    .scaleEffect(isHovering ? 1 : 0.96)
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.035, glowOpacity: 0.12))
            .opacity(isPinned || isRecentlyUnpinned || isHovering ? 1 : 0.28)
            .help(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath))
        }
        .padding(.trailing, 6)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                .fill(isSelected ? LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex).opacity(0.18) : LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex).opacity(isHovering ? 0.07 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
        .contextMenu {
            Button("Open") {
                appState.openSidebarFolder(url)
            }
            Button(appState.localized(.showInFinder)) {
                appState.revealSidebarURLInFinder(url)
            }
            Button(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath)) {
                togglePin()
            }
        }
        .onHover { hovering in
            withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
        .task(id: path) {
            await loadColorTags()
        }
    }

    private var rowTextColor: Color {
        if isRecentlyUnpinned {
            return Color.primary.opacity(0.55)
        }
        return isSelected ? Color.primary.opacity(0.96) : Color.primary.opacity(0.72)
    }

    private func loadColorTags() async {
        let taggedURL = url
        let tags = await Task.detached(priority: .utility) {
            FinderTagStore.colorTags(for: taggedURL)
        }.value

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
    @Binding var expandedPaths: Set<String>
    var isPinned: Bool
    var isRecentlyUnpinned: Bool
    var togglePin: () -> Void

    @State private var children: [LibraryFolderEntry] = []
    @State private var hasLoadedChildren = false
    @State private var isHovering = false
    @State private var colorTags: [String] = []
    @AppStorage(LightboxGlowColor.modeKey) private var glowModeRaw = LightboxGlowColor.systemMode
    @AppStorage(LightboxGlowColor.hexKey) private var glowHex = ""

    private var path: String {
        url.standardizedFileURL.path
    }

    private var isExpanded: Bool {
        expandedPaths.contains(path)
    }

    private var isSelected: Bool {
        !appState.isViewingTrash && appState.currentFolderURL.standardizedFileURL.path == path
    }

    private var childIndent: CGFloat {
        CGFloat(depth) * 13
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row

            // Stationary clip box anchored flush under the parent row. The children
            // slide up *inside* this box and get masked at its top edge, so a
            // collapse reads as the rows retracting into the folder — never drawing
            // over the row above. The clip must sit here (not on the moving content)
            // or it travels with the slide and stops masking, which is exactly the
            // ghosting/overlap bug. No opacity/blur: a plain upward slide reads as a
            // physical retract.
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
                    .transition(.move(edge: .top))
                    .task(id: path) {
                        loadChildrenIfNeeded()
                    }
                }
            }
            .clipped()
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.sidebarDisclosure, reduceMotion: reduceMotion), value: isExpanded)
    }

    private var row: some View {
        HStack(spacing: 4) {
            Button {
                toggleExpanded()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.46))
                    .frame(width: 14, height: 26)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasLoadedChildren || isExpanded ? 1 : 0.72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button {
                    appState.openSidebarFolder(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 18)

                        Text(title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 6)

                        SidebarTagDots(tags: colorTags)
                    }
                    .foregroundStyle(rowTextColor)
                    .padding(.leading, 8)
                    .frame(height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
                }
                .buttonStyle(.plain)
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
                        .scaleEffect(isHovering ? 1 : 0.96)
                        .contentShape(Circle())
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.035, glowOpacity: 0.12))
                .opacity(isPinned || isRecentlyUnpinned || isHovering ? 1 : 0.28)
                .help(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath))
            }
            .padding(.trailing, 6)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                    .fill(isSelected ? LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex).opacity(0.18) : LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex).opacity(isHovering ? 0.07 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            .contextMenu {
                Button("Open") {
                    appState.openSidebarFolder(url)
                }
                Button(appState.localized(.showInFinder)) {
                    appState.revealSidebarURLInFinder(url)
                }
                Button(isPinned ? appState.localized(.unpinFolder) : appState.localized(.pinCurrentPath)) {
                    togglePin()
                }
            }
            .onHover { hovering in
                withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
        }
        .padding(.leading, childIndent)
        .task(id: path) {
            await loadColorTags()
        }
    }

    private var rowTextColor: Color {
        if isRecentlyUnpinned {
            return Color.primary.opacity(0.55)
        }
        return isSelected ? Color.primary.opacity(0.96) : Color.primary.opacity(0.72)
    }

    private var pinColor: Color {
        isPinned ? Color.primary.opacity(0.66) : Color.primary.opacity(0.42)
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            loadChildrenIfNeeded()
        }
    }

    private func loadChildrenIfNeeded() {
        guard !hasLoadedChildren else { return }
        children = LocalImageSource.folders(in: url, sourceID: sourceID, rootURL: rootURL)
        hasLoadedChildren = true
    }

    private func loadColorTags() async {
        let taggedURL = url
        let tags = await Task.detached(priority: .utility) {
            FinderTagStore.colorTags(for: taggedURL)
        }.value

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
    @AppStorage(LightboxGlowColor.modeKey) private var glowModeRaw = LightboxGlowColor.systemMode
    @AppStorage(LightboxGlowColor.hexKey) private var glowHex = ""

    private var isSelected: Bool {
        appState.isViewingTrash
    }

    var body: some View {
        Button {
            appState.openTrashFromSidebar()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)

                Text(appState.localized(.trash))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer()
            }
            .foregroundStyle(isSelected ? Color.primary.opacity(0.96) : Color.primary.opacity(0.72))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                    .fill(isSelected ? LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex).opacity(0.18) : LightboxGlowColor.resolved(mode: glowModeRaw, hex: glowHex).opacity(isHovering ? 0.07 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(
            shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous),
            hoverScale: 1.004,
            glowOpacity: 0.10
        ))
        .contextMenu {
            Button("Open") {
                appState.openTrashFromSidebar()
            }
            Button(appState.localized(.showInFinder)) {
                appState.revealSidebarURLInFinder(LightboxLibraryStore.primarySystemTrashFolder)
            }
        }
        .onHover { hovering in
            withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
    }
}
