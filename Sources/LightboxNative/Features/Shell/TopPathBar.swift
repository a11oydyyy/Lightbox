import AppKit
import SwiftUI

struct TopPathBar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchExpanded = false
    @State private var isSortMenuPresented = false
    private static let selectionLeadingInset: CGFloat = 9
    private static let selectionTrailingInset: CGFloat = 13
    private static let collapsedSearchWidth: CGFloat = 36
    private static let expandedSearchWidth: CGFloat = 224
    private static let searchTextFieldWidth: CGFloat = 142

    private var isSelecting: Bool {
        appState.selectedAssetCount > 1
    }

    private var topBarShadowOpacity: Double {
        GlassTokens.floatingCapsuleShadowOpacity(appState.glassOpacity)
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - 56)
            let sidebarWidth: CGFloat = isSelecting ? 0 : 36
            let sidebarGap: CGFloat = isSelecting ? 0 : 8
            let leadingControlsWidth = sidebarWidth + sidebarGap
            let searchWidth: CGFloat = isSearchExpanded ? Self.expandedSearchWidth : Self.collapsedSearchWidth
            let searchGap: CGFloat = 8
            let sortWidth: CGFloat = 36
            let sortGap: CGFloat = 8
            let trailingControlsWidth = searchGap + searchWidth + sortGap + sortWidth
            let pathOffset = (leadingControlsWidth - trailingControlsWidth) / 2
            let maxPathWidth = max(270, availableWidth - leadingControlsWidth - trailingControlsWidth)
            let minPathWidth: CGFloat = appState.isViewingTrash ? idealPathWidth : 270
            let pathWidth = min(max(minPathWidth, idealPathWidth), maxPathWidth)
            let selectionWidth = min(max(360, idealSelectionWidth), availableWidth)
            let primaryWidth = isSelecting ? selectionWidth : pathWidth
            let primaryOffset = isSelecting ? CGFloat.zero : pathOffset
            let sidebarOffset = primaryOffset - pathWidth / 2 - sidebarGap - sidebarWidth / 2
            let searchOffset = pathOffset + pathWidth / 2 + searchGap + searchWidth / 2
            let sortOffset = searchOffset + searchWidth / 2 + sortGap + sortWidth / 2

            GlassGroup(spacing: 8) {
                ZStack {
                    if !isSelecting {
                        sidebarCapsule
                            .offset(x: sidebarOffset)
                    }

                    primaryCapsule(width: primaryWidth, isSelecting: isSelecting)
                        .offset(x: primaryOffset)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if !isSelecting {
                        searchCapsule
                            .offset(x: searchOffset)

                        sortCapsule
                            .offset(x: sortOffset)
                    }
                }
                .frame(width: availableWidth)
            }
            .frame(maxWidth: availableWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 40)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.currentPathTitle)
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.breadcrumbs)
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: isSearchExpanded)
        .onChange(of: appState.searchFocusGeneration) { _ in
            expandSearch()
        }
    }

    private func primaryCapsule(width: CGFloat, isSelecting: Bool) -> some View {
        ZStack {
            morphingContentLayer(isVisible: !isSelecting, alignment: .leading) {
                pathContent
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
            }

            morphingContentLayer(isVisible: isSelecting, alignment: .leading) {
                selectionContent
                    .padding(.leading, Self.selectionLeadingInset)
                    .padding(.trailing, Self.selectionTrailingInset)
            }
        }
            .frame(width: width, height: 36, alignment: .leading)
            .clipped()
            .topBarGlass(Capsule())
            .shadow(color: .black.opacity(topBarShadowOpacity), radius: 8, y: 3)
            .contextMenu {
                if !isSelecting {
                    Button {
                        appState.pinCurrentPath()
                    } label: {
                        Text(appState.localized(.pinCurrentPath))
                    }
                    .disabled(!appState.canPinCurrentPath)

                    Button {
                        appState.copyCurrentPathToClipboard()
                    } label: {
                        Text(appState.localized(.copyPath))
                    }
                }
            }
    }

    private func morphingContentLayer<Content: View>(
        isVisible: Bool,
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 1.5)
            .animation(MotionTokens.ifAllowed(.easeOut(duration: 0.12), reduceMotion: reduceMotion), value: isVisible)
            .allowsHitTesting(isVisible)
    }

    private var pathContent: some View {
        HStack(spacing: 8) {
            if appState.isViewingTrash {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                Text(appState.localized(.trash))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TopPathBarColor.strongText)
                    .lineLimit(1)
            } else {
                Button {
                    appState.openParentFolder()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(appState.canOpenParentFolder ? TopPathBarColor.regularText : TopPathBarColor.disabledText)
                        .frame(width: 24, height: 26)
                        .contentShape(Capsule())
                }
                .disabled(!appState.canOpenParentFolder)
                .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(), hoverScale: 1.025, glowOpacity: 0.12))
                .help(appState.localized(.goToParentFolder))

                Capsule()
                    .fill(TopPathBarColor.divider)
                    .frame(width: 1, height: 17)

                BreadcrumbStrip()
                    .layoutPriority(1)
                    // Fade the breadcrumb content in place on path change so
                    // going up a level doesn't hard-swap the "…"/crumbs while the
                    // capsule width eases independently.
                    .id(appState.currentFolderURL.standardizedFileURL.path)
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var idealPathWidth: CGFloat {
        if appState.isViewingTrash {
            return Self.measuredTrashPathWidth(title: appState.localized(.trash))
        }

        return Self.measuredPathContentWidth(
            breadcrumbs: appState.breadcrumbs
        )
    }

    private var sidebarCapsule: some View {
        Button {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                appState.sidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(TopPathBarColor.regularText)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.035, glowOpacity: 0.16))
        .padding(5)
        .frame(width: 36, height: 36)
        .topBarGlass(Capsule())
        .shadow(color: .black.opacity(topBarShadowOpacity), radius: 8, y: 3)
        .help(appState.localized(appState.sidebarCollapsed ? .openSidebar : .closeSidebar))
    }

    private var idealSelectionWidth: CGFloat {
        Self.measuredSelectionContentWidth(
            countTitle: appState.selectedCountText(appState.selectedAssetCount),
            compareTitle: appState.localized(.compare),
            clearTitle: appState.localized(.clear)
        )
    }

    private static func measuredTrashPathWidth(title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let iconWidth: CGFloat = 14
        let contentSpacing: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        return ceil(iconWidth + contentSpacing + textWidth + horizontalPadding)
    }

    private static func measuredSelectionContentWidth(countTitle: String, compareTitle: String, clearTitle: String) -> CGFloat {
        let countWidth = textWidth(countTitle, font: .systemFont(ofSize: 11, weight: .semibold))
        let compareWidth = selectionActionWidth(compareTitle)
        let clearWidth = selectionActionWidth(clearTitle)
        let tagStripWidth = MacTagDotMetrics.selectionStripWidth
        let dividerWidth: CGFloat = 2
        let hstackSpacing: CGFloat = 5 * 8
        let horizontalPadding: CGFloat = selectionLeadingInset + selectionTrailingInset
        let safetyPadding: CGFloat = 6

        return ceil(countWidth + compareWidth + clearWidth + tagStripWidth + dividerWidth + hstackSpacing + horizontalPadding + safetyPadding)
    }

    private static func selectionActionWidth(_ title: String) -> CGFloat {
        let text = textWidth(title, font: .systemFont(ofSize: 11, weight: .semibold))
        return ceil(min(62, max(38, text + 15)))
    }

    private var searchCapsule: some View {
        HStack(spacing: 7) {
            Button {
                expandSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(appState.searchText.isEmpty ? TopPathBarColor.regularText : TopPathBarColor.strongText)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.035, glowOpacity: 0.14))

            if isSearchExpanded {
                TextField(appState.localized(.search), text: $appState.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TopPathBarColor.strongText)
                    .focused($isSearchFocused)
                    .frame(width: Self.searchTextFieldWidth)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))

                Button {
                    collapseSearch()
                } label: {
                    Image(systemName: appState.searchText.isEmpty ? "xmark" : "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .lightboxSymbolReplaceTransition()
                        .foregroundStyle(TopPathBarColor.regularText)
                        .frame(width: 22, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.035, glowOpacity: 0.12))
                .transition(.opacity)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, isSearchExpanded ? 7 : 5)
        .frame(height: 36)
        .frame(width: isSearchExpanded ? Self.expandedSearchWidth : Self.collapsedSearchWidth)
        .topBarGlass(Capsule())
        .shadow(color: .black.opacity(topBarShadowOpacity), radius: 8, y: 3)
    }

    private var sortCapsule: some View {
        Button {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                isSortMenuPresented.toggle()
            }
        } label: {
            SortOrderIcon(direction: appState.sortDirection)
                .foregroundStyle(TopPathBarColor.regularText)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.035, glowOpacity: 0.14))
        .popover(isPresented: $isSortMenuPresented, arrowEdge: .bottom) {
            SortPopover {
                isSortMenuPresented = false
            }
            .environmentObject(appState)
        }
        .padding(5)
        .frame(width: 36, height: 36)
        .topBarGlass(Capsule())
        .shadow(color: .black.opacity(topBarShadowOpacity), radius: 8, y: 3)
        .help(appState.localized(.sort))
    }

    private func expandSearch() {
        guard !isSearchExpanded else {
            isSearchFocused = true
            return
        }

        isSearchExpanded = true
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func collapseSearch() {
        if appState.searchText.isEmpty {
            isSearchExpanded = false
            isSearchFocused = false
        } else {
            appState.searchText = ""
        }
    }

    private var selectionContent: some View {
        HStack(spacing: 8) {
            Text(appState.selectedCountText(appState.selectedAssetCount))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TopPathBarColor.strongText)
                .monospacedDigit()
                .lightboxNumericTextTransition(value: Double(appState.selectedAssetCount))
                .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.selectedAssetCount)

            Capsule()
                .fill(TopPathBarColor.divider)
                .frame(width: 1, height: 17)

            SelectionTagStrip()

            Capsule()
                .fill(TopPathBarColor.divider)
                .frame(width: 1, height: 17)

            Button {
                appState.showComparisonFromSelection()
            } label: {
                Text(appState.localized(.compare))
                    .selectionActionLabel(width: Self.selectionActionWidth(appState.localized(.compare)))
            }
            .disabled(appState.selectedAssetCount < 2)

            Button {
                appState.clearSelection()
            } label: {
                Text(appState.localized(.clear))
                    .selectionActionLabel(width: Self.selectionActionWidth(appState.localized(.clear)))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(), hoverScale: 1.018, glowOpacity: 0.13))
        .fixedSize(horizontal: true, vertical: false)
    }

    private struct SelectionTagStrip: View {
        @EnvironmentObject private var appState: AppState
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: MacTagDotMetrics.selectionSpacing) {
                ForEach(MacColorTag.all) { tag in
                    SelectionTagButton(
                        tag: tag,
                        coverage: appState.selectedAssetTagCoverage(for: tag.name)
                    ) {
                        withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                            appState.toggleTagForSelection(tag.name)
                        }
                    }
                }
            }
            .frame(height: MacTagDotMetrics.selectionHeight)
        }
    }

    private struct SelectionTagButton: View {
        var tag: MacColorTag
        var coverage: Double
        var action: () -> Void

        private var isFullyApplied: Bool {
            coverage >= 0.999
        }

        private var isPartiallyApplied: Bool {
            coverage > 0 && !isFullyApplied
        }

        var body: some View {
            Button(action: action) {
                ZStack {
                    if isFullyApplied || isPartiallyApplied {
                        Circle()
                            .fill(tag.color.opacity(isFullyApplied ? 0.18 : 0.10))
                            .frame(
                                width: MacTagDotMetrics.selectionHitWidth,
                                height: MacTagDotMetrics.selectionHitWidth
                            )
                    }

                    Circle()
                        .fill(tag.color.opacity(isFullyApplied ? 1 : 0.84))
                        .frame(
                            width: MacTagDotMetrics.selectionDotDiameter,
                            height: MacTagDotMetrics.selectionDotDiameter
                        )
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.58), lineWidth: 0.7)
                        }

                    if isFullyApplied {
                        Circle()
                            .stroke(tag.color.opacity(0.72), lineWidth: 1.4)
                            .frame(
                                width: MacTagDotMetrics.selectionRingDiameter,
                                height: MacTagDotMetrics.selectionRingDiameter
                            )
                    } else if isPartiallyApplied {
                        Circle()
                            .stroke(
                                tag.color.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])
                            )
                            .frame(
                                width: MacTagDotMetrics.selectionRingDiameter,
                                height: MacTagDotMetrics.selectionRingDiameter
                            )
                    }
                }
                .frame(width: MacTagDotMetrics.selectionHitWidth, height: MacTagDotMetrics.selectionHeight)
                .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.06, glowOpacity: 0.16))
            .help(tag.name)
            .animation(MotionTokens.quick, value: coverage)
        }
    }

    private static func measuredPathContentWidth(breadcrumbs: [PathBreadcrumb]) -> CGFloat {
        let visibleBreadcrumbs = breadcrumbs.count > 4 ? Array(breadcrumbs.suffix(4)) : breadcrumbs
        let showsLeadingEllipsis = breadcrumbs.count > 4

        let breadcrumbWidth = measuredBreadcrumbWidth(
            breadcrumbs: visibleBreadcrumbs,
            showsLeadingEllipsis: showsLeadingEllipsis,
            isEmpty: breadcrumbs.isEmpty
        )

        let outerPadding: CGFloat = 16
        let internalGaps: CGFloat = 8 * 2
        let dividerWidth: CGFloat = 1
        let parentButtonWidth: CGFloat = 24
        let safetyPadding: CGFloat = 8

        return ceil(outerPadding + internalGaps + dividerWidth + parentButtonWidth + breadcrumbWidth + safetyPadding)
    }

    private static func measuredBreadcrumbWidth(
        breadcrumbs: [PathBreadcrumb],
        showsLeadingEllipsis: Bool,
        isEmpty: Bool
    ) -> CGFloat {
        if isEmpty {
            return textWidth("Path", font: .systemFont(ofSize: 12, weight: .medium))
        }

        let regularFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let currentFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let separatorWidth: CGFloat = 9
        var childWidths: [CGFloat] = []

        if showsLeadingEllipsis {
            childWidths.append(textWidth("...", font: regularFont))
            childWidths.append(separatorWidth)
        }

        for (index, breadcrumb) in breadcrumbs.enumerated() {
            if index > 0 {
                childWidths.append(separatorWidth)
            }

            let isCurrent = index == breadcrumbs.count - 1
            childWidths.append(textWidth(breadcrumb.title, font: isCurrent ? currentFont : regularFont) + 14)
        }

        let interItemSpacing = CGFloat(max(0, childWidths.count - 1)) * 5
        return ceil(childWidths.reduce(0, +) + interItemSpacing)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

private struct SortOrderIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var direction: GallerySortDirection

    // Three left-aligned bars. Flipping direction smoothly swaps the top and
    // bottom bar lengths (the middle stays put) — the lines grow/shrink instead
    // of the whole glyph snapping 180°, which read as rigid.
    private let longBar: CGFloat = 15
    private let midBar: CGFloat = 10
    private let shortBar: CGFloat = 5.5
    private let barHeight: CGFloat = 2
    private let barSpacing: CGFloat = 2.5

    private var barWidths: [CGFloat] {
        // descending: long → short (top to bottom). ascending: mirror.
        direction == .ascending
            ? [shortBar, midBar, longBar]
            : [longBar, midBar, shortBar]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: barSpacing) {
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .frame(width: barWidths[index], height: barHeight)
            }
        }
        .frame(width: longBar, alignment: .leading)
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: direction)
    }
}

private struct SortPopover: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appState.localized(.sortBy))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 2)

            ForEach(GallerySortField.allCases, id: \.self) { field in
                Button {
                    withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                        appState.setSortField(field)
                    }
                    close()
                } label: {
                    HStack(spacing: 8) {
                        Text(appState.sortFieldTitle(field))
                            .font(.system(size: 13, weight: appState.sortField == field ? .semibold : .medium))
                            .foregroundStyle(.primary.opacity(appState.sortField == field ? 0.92 : 0.76))

                        Spacer(minLength: 12)

                        if appState.sortField == field {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.primary.opacity(0.74))
                                .transition(.scale(scale: 0.75).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 164, height: 30, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
                }
                .buttonStyle(LightboxButtonHoverStyle(
                    shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous),
                    hoverScale: 1.006,
                    glowOpacity: 0.13
                ))
            }

            Divider()
                .padding(.vertical, 2)

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                    appState.toggleSortDirection()
                }
                close()
            } label: {
                HStack(spacing: 8) {
                    SortOrderIcon(direction: appState.sortDirection)
                        .frame(width: 18, height: 22)

                    Text(appState.sortDirectionTitle)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer(minLength: 12)
                }
                .foregroundStyle(.primary.opacity(0.86))
                .padding(.horizontal, 10)
                .frame(width: 164, height: 30, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            }
            .buttonStyle(LightboxButtonHoverStyle(
                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous),
                hoverScale: 1.006,
                glowOpacity: 0.13
            ))
        }
        .padding(8)
        .frame(width: 180)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.sortField)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.sortDirection)
    }
}

private struct SourceMenuButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSourceMenuPresented = false
    @State private var menuSnapshotSources: [LibrarySource] = []
    @State private var menuUnpinnedSourceIDs: Set<LibrarySource.ID> = []

    private var title: String {
        appState.selectedSource?.displayName ?? "Lightbox"
    }

    private var pinnedSources: [LibrarySource] {
        appState.sourceMenuSources
    }

    private var unpinnedSourceIDs: Set<LibrarySource.ID> {
        Set(pinnedSources.filter { !appState.isSourcePinned($0) }.map(\.id))
    }

    var body: some View {
        Button {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                if !isSourceMenuPresented {
                    menuSnapshotSources = pinnedSources
                    menuUnpinnedSourceIDs = unpinnedSourceIDs
                }
                isSourceMenuPresented.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: appState.selectedSource?.isLocalLibrary == true ? "photo.stack" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .lightboxSymbolReplaceTransition()

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TopPathBarColor.regularText)
            }
            .foregroundStyle(TopPathBarColor.strongText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(LightboxButtonHoverStyle(
            shape: Capsule(),
            hoverScale: 1.018,
            pressedScale: 0.975,
            glowOpacity: 0.13
        ))
        .popover(isPresented: $isSourceMenuPresented, arrowEdge: .bottom) {
            SourceMenuPopover(
                pinnedSources: menuSnapshotSources,
                unpinnedSourceIDs: menuUnpinnedSourceIDs,
                selectedSourceID: appState.selectedSourceID,
                pinFolderTitle: appState.localized(.openFolder),
                pinSourceTitle: appState.localized(.pinCurrentPath),
                unpinFolderTitle: appState.localized(.unpinFolder),
                open: { source in
                    appState.openSource(source)
                    isSourceMenuPresented = false
                },
                togglePin: { source in
                    withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                        if menuUnpinnedSourceIDs.contains(source.id) {
                            appState.pinSource(source, selectPinnedFolder: false)
                            menuUnpinnedSourceIDs.remove(source.id)
                        } else {
                            appState.unpinSource(source.id)
                            menuUnpinnedSourceIDs.insert(source.id)
                        }
                    }
                },
                pinNewFolder: {
                    appState.addExternalSource()
                    isSourceMenuPresented = false
                }
            )
            .environmentObject(appState)
        }
        .onChange(of: isSourceMenuPresented) { presented in
            if presented {
                menuSnapshotSources = pinnedSources
                menuUnpinnedSourceIDs = unpinnedSourceIDs
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SourceMenuPopover: View {
    var pinnedSources: [LibrarySource]
    var unpinnedSourceIDs: Set<LibrarySource.ID>
    var selectedSourceID: LibrarySource.ID
    var pinFolderTitle: String
    var pinSourceTitle: String
    var unpinFolderTitle: String
    var open: (LibrarySource) -> Void
    var togglePin: (LibrarySource) -> Void
    var pinNewFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(pinnedSources) { source in
                PinnedSourceRow(
                    source: source,
                    isSelected: source.id == selectedSourceID,
                    isPinned: !unpinnedSourceIDs.contains(source.id),
                    pinTitle: pinSourceTitle,
                    unpinTitle: unpinFolderTitle,
                    open: open,
                    togglePin: togglePin
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !pinnedSources.isEmpty {
                Divider()
                    .padding(.vertical, 3)
            }

            Button(action: pinNewFolder) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)

                    Text(pinFolderTitle)
                        .font(.system(size: 13, weight: .medium))

                    Spacer(minLength: 16)
                }
                .foregroundStyle(.primary.opacity(0.88))
                .padding(.horizontal, 10)
                .frame(width: 258, height: 34, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            }
            .buttonStyle(LightboxButtonHoverStyle(
                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous),
                hoverScale: 1.006,
                glowOpacity: 0.13
            ))
        }
        .padding(8)
        .frame(width: 274)
        .animation(MotionTokens.standard, value: pinnedSources.map(\.id))
    }
}

private struct PinnedSourceRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinIsPressed = false

    var source: LibrarySource
    var isSelected: Bool
    var isPinned: Bool
    var pinTitle: String
    var unpinTitle: String
    var open: (LibrarySource) -> Void
    var togglePin: (LibrarySource) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                open(source)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)

                    Text(source.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)
                }
                .foregroundStyle(rowTextColor)
                .padding(.leading, 10)
                .frame(height: 34)
                .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
            }
            .buttonStyle(LightboxButtonHoverStyle(
                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous),
                hoverScale: 1.006,
                glowOpacity: 0.13
            ))

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                    pinIsPressed.toggle()
                }
                togglePin(source)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPinned ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.58))
                    .frame(width: 28, height: 28)
                    .scaleEffect(pinIsPressed ? 0.82 : 1)
                    .rotationEffect(.degrees(pinIsPressed ? -10 : (isPinned ? 0 : -16)))
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.05, glowOpacity: 0.16))
            .help(isPinned ? unpinTitle : pinTitle)
        }
        .frame(width: 258, height: 34)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
    }

    private var rowTextColor: Color {
        if !isPinned {
            return Color.secondary.opacity(0.72)
        }

        return isSelected ? Color.primary : Color.primary.opacity(0.86)
    }
}

private struct BreadcrumbStrip: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let breadcrumbs = appState.breadcrumbs

        HStack(spacing: 5) {
            if breadcrumbs.isEmpty {
                Text(appState.localized(.path))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TopPathBarColor.mutedText)
                    .frame(height: 28)
            } else {
                let visibleBreadcrumbs = tailBreadcrumbs(from: breadcrumbs, count: 4)

                breadcrumbRow(visibleBreadcrumbs, showsLeadingEllipsis: breadcrumbs.count > 4)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tailBreadcrumbs(from breadcrumbs: [PathBreadcrumb], count: Int) -> [PathBreadcrumb] {
        guard breadcrumbs.count > count else {
            return breadcrumbs
        }

        return Array(breadcrumbs.suffix(count))
    }

    private func breadcrumbRow(_ breadcrumbs: [PathBreadcrumb], showsLeadingEllipsis: Bool = false) -> some View {
        HStack(spacing: 5) {
            if showsLeadingEllipsis {
                Text("...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TopPathBarColor.regularText)
                    .frame(height: 26)

                separator
            }

            ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, breadcrumb in
                if index > 0 {
                    separator
                }

                breadcrumbButton(breadcrumb, isCurrent: index == breadcrumbs.count - 1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(TopPathBarColor.faintText)
    }

    private func breadcrumbButton(_ breadcrumb: PathBreadcrumb, isCurrent: Bool) -> some View {
        Button {
            appState.openBreadcrumb(breadcrumb)
        } label: {
            Text(breadcrumb.title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? TopPathBarColor.strongText : TopPathBarColor.regularText)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(), hoverScale: 1.018, glowOpacity: 0.12))
    }

}

private enum TopPathBarColor {
    static let strongText = Color.primary.opacity(0.98)
    static let regularText = Color.primary.opacity(0.78)
    static let mutedText = Color.primary.opacity(0.68)
    static let faintText = Color.primary.opacity(0.50)
    static let disabledText = Color.primary.opacity(0.40)
    static let divider = Color.primary.opacity(0.16)
}

private extension View {
    func topBarGlass<S: Shape>(_ shape: S) -> some View {
        modifier(TopBarGlassModifier(shape: shape))
    }

    func selectionActionLabel(width: CGFloat) -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.86)
            .frame(width: width, height: 22)
            .contentShape(Capsule())
    }
}

private struct TopBarGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.lightboxGlassOpacity) private var glassOpacity
    @Environment(\.colorScheme) private var colorScheme

    var shape: S

    func body(content: Content) -> some View {
        let materialOpacity = GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity)
        let fillOpacity = GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme)
        let strokeOpacity = GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity)

        if #available(macOS 26.0, *) {
            content
                .background(.ultraThinMaterial.opacity(materialOpacity), in: shape)
                .background {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
                }
                .glassEffect(.clear.interactive(true), in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: 0.7)
                }
        } else {
            content
                .background(.ultraThinMaterial.opacity(materialOpacity), in: shape)
                .background {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
                }
                .overlay {
                    shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: 0.7)
                }
        }
    }
}
