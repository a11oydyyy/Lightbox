import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TopPathBar: View {
    var selectionOnly = false
    var windowLeadingInset: CGFloat = 152
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isPathFocused: Bool
    @FocusState private var focusedUtility: TopBarUtility?
    @State private var isSearchExpanded = false
    @State private var isSortMenuPresented = false
    @State private var isTabSwitcherPresented = false
    @State private var isPathEditing = false
    @State private var pathInput = ""
    @State private var pathInputHasError = false
    private enum TopBarUtility: Hashable {
        case search, sort
    }

    private static let selectionLeadingInset: CGFloat = 9
    private static let selectionTrailingInset: CGFloat = 13
    private static let collapsedSearchWidth: CGFloat = 36
    private static let expandedSearchWidth: CGFloat = 224
    private static let searchTextFieldWidth: CGFloat = 142

    private var isSelecting: Bool {
        selectionOnly || appState.selectedAssetCount > 1
    }

    var body: some View {
        GeometryReader { proxy in
            let galleryInset: CGFloat = appState.sidebarCollapsed ? 0 : appState.sidebarWidth + 18
            let leadingControlsInset = max(0, galleryInset - windowLeadingInset)
            let center = (proxy.size.width + windowLeadingInset + 16 + galleryInset) / 2 - windowLeadingInset
            let trailingWidth = (isSearchExpanded ? Self.expandedSearchWidth : 36) + 60 + (appState.fileTransferProgress == nil ? 0 : 44)
            let titleWidth = max(40, 2 * min(center - leadingControlsInset - 140, proxy.size.width - trailingWidth - center) - 16)
            ZStack {
                if isSelecting {
                    primaryCapsule(width: max(0, proxy.size.width - 32), isSelecting: true)
                } else {
                    pathContent
                        .frame(width: titleWidth)
                        .offset(x: center - proxy.size.width / 2)
                    HStack(spacing: 8) {
                        navigationControls
                            .padding(.leading, leadingControlsInset)
                        NativeToolbarButton(symbol: "rectangle.on.rectangle", title: appState.localized(.tabs)) {
                            isTabSwitcherPresented.toggle()
                        }
                        .frame(width: 32, height: 32)
                        .popover(isPresented: $isTabSwitcherPresented) {
                            TabStrip().frame(width: 380, height: 36).padding(12)
                        }
                        Spacer(minLength: 0)
                        searchCapsule
                        sortCapsule
                        if let progress = appState.fileTransferProgress {
                            FileTransferControl(progress: progress)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 44)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.currentPathTitle)
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.breadcrumbs)
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.tabs.map(\.id))
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.activeTabID)
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: isSearchExpanded)
        .onChange(of: appState.searchFocusGeneration) { _ in
            guard !selectionOnly else { return }
            cancelPathEditing()
            expandSearch()
        }
        .onChange(of: appState.goToFolderFocusGeneration) { _ in
            guard !selectionOnly else { return }
            beginPathEditing()
        }
        .onChange(of: appState.activeTabID) { _ in
            cancelPathEditing()
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

            .contextMenu {
                if !isSelecting {
                    Button {
                        beginPathEditing()
                    } label: {
                        Text(appState.localized(.goToFolder))
                    }

                    Divider()

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
            .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: isVisible)
            .allowsHitTesting(isVisible)
    }

    private var navigationControls: some View {
            HStack(spacing: 2) {
                navigationButton(
                    systemName: "chevron.left",
                    isEnabled: appState.canGoBack,
                    help: appState.localized(.goBack),
                    action: appState.goBack
                )
                navigationButton(
                    systemName: "chevron.right",
                    isEnabled: appState.canGoForward,
                    help: appState.localized(.goForward),
                    action: appState.goForward
                )
                navigationButton(
                    systemName: "chevron.up",
                    isEnabled: appState.canOpenParentFolder,
                    help: appState.localized(.goToParentFolder),
                    action: appState.openParentFolder
                )
            }
            .fixedSize(horizontal: true, vertical: false)

    }

    private var pathContent: some View {
        Group {
            if isPathEditing {
                pathEditor
                    .layoutPriority(2)
            } else if appState.isViewingTrash {
                Text(appState.localized(.trash))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TopPathBarColor.strongText)
                    .lineLimit(1)
            } else {
                BreadcrumbStrip(editPath: beginPathEditing)
                    .layoutPriority(1)
                    // Keep location changes visually stable inside the centered title.
                    .id(appState.currentFolderURL.standardizedFileURL.path)
                    .transition(.opacity)
                    .onTapGesture(count: 2) {
                        beginPathEditing()
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .contextMenu {
            Button(appState.localized(.goToFolder), action: beginPathEditing)
            Button(appState.localized(.copyPath), action: appState.copyCurrentPathToClipboard)
            Button(appState.localized(.pinCurrentPath), action: appState.pinCurrentPath)
                .disabled(!appState.canPinCurrentPath)
        }
    }

    private var pathEditor: some View {
        HStack(spacing: 4) {
            TextField(appState.localized(.folderPathPlaceholder), text: $pathInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TopPathBarColor.strongText)
                .focused($isPathFocused)
                .onSubmit(submitPathInput)
                .onExitCommand(perform: cancelPathEditing)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            pathInputHasError ? Color.red.opacity(0.72) : Color.accentColor.opacity(0.34),
                            lineWidth: 0.8
                        )
                }
                .accessibilityLabel(appState.localized(.folderPathPlaceholder))

            if pathInputHasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .help(appState.localized(.folderUnavailable))
                    .accessibilityLabel(appState.localized(.folderUnavailable))
            }

            Button(action: submitPathInput) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TopPathBarColor.regularText)
                    .frame(width: 24, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
            .help(appState.localized(.goToFolder))
        }
    }

    private func navigationButton(
        systemName: String,
        isEnabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        NativeToolbarButton(symbol: systemName, title: help, isEnabled: isEnabled, action: action)
            .frame(width: 28, height: 32)
    }

    private static func selectionActionWidth(_ title: String) -> CGFloat {
        let text = textWidth(title, font: .systemFont(ofSize: 11, weight: .semibold))
        return ceil(min(62, max(38, text + 15)))
    }

    private var searchCapsule: some View {
        HStack(spacing: 7) {
            NativeToolbarButton(symbol: "magnifyingglass", title: appState.localized(.search), action: expandSearch)
                .frame(width: 26, height: 32)

            if isSearchExpanded {
                TextField(appState.localized(.search), text: $appState.searchText)
                    .textFieldStyle(.roundedBorder)
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
                .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
                .transition(.opacity)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, isSearchExpanded ? 7 : 5)
        .frame(height: 36)
        .frame(width: isSearchExpanded ? Self.expandedSearchWidth : Self.collapsedSearchWidth)
        .topBarUtilitySurface(isActive: isSearchExpanded || focusedUtility == .search)
    }

    private var sortCapsule: some View {
        NativeToolbarButton(symbol: "line.3.horizontal.decrease", title: appState.localized(.sort)) {
            isSortMenuPresented.toggle()
        }
        .popover(isPresented: $isSortMenuPresented, arrowEdge: .bottom) {
            SortPopover {
                isSortMenuPresented = false
            }
            .environmentObject(appState)
        .tint(LightboxColorTokens.accent)
        .accentColor(LightboxColorTokens.accent)
        }
        .frame(width: 36, height: 36)
        .focused($focusedUtility, equals: .sort)
        .topBarUtilitySurface(isActive: isSortMenuPresented || focusedUtility == .sort)
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

    private func beginPathEditing() {
        if isSelecting {
            appState.clearSelection()
        }
        isSearchFocused = false
        pathInput = appState.currentFolderURL.standardizedFileURL.path
        pathInputHasError = false
        isPathEditing = true
        DispatchQueue.main.async {
            isPathFocused = true
        }
    }

    private func cancelPathEditing() {
        guard isPathEditing else { return }
        isPathEditing = false
        isPathFocused = false
        pathInputHasError = false
    }

    private func submitPathInput() {
        guard appState.openFolderPath(pathInput) else {
            pathInputHasError = true
            isPathFocused = true
            return
        }
        cancelPathEditing()
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
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule()))
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
        @EnvironmentObject private var appState: AppState

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
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
            .help(appState.localizedColorTagName(tag.name))
            .accessibilityLabel(appState.localizedColorTagName(tag.name))
            .accessibilityValue("\(Int((coverage * 100).rounded()))%")
            .animation(MotionTokens.quick, value: coverage)
        }
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct LightboxTabStripLayout: Equatable {
    var visibleIndices: [Int]
    var hiddenIndices: [Int]

    static func resolve(tabCount: Int, activeIndex: Int, availableWidth: CGFloat) -> LightboxTabStripLayout {
        guard tabCount > 0 else {
            return LightboxTabStripLayout(visibleIndices: [], hiddenIndices: [])
        }

        let capacityWithoutOverflow = max(1, Int((availableWidth - 45) / 78))
        if tabCount <= capacityWithoutOverflow {
            return LightboxTabStripLayout(
                visibleIndices: Array(0..<tabCount),
                hiddenIndices: []
            )
        }

        let capacity = max(1, Int((availableWidth - 77) / 78))
        let clampedActiveIndex = min(max(0, activeIndex), tabCount - 1)
        let maximumStart = max(0, tabCount - capacity)
        let start = min(max(0, clampedActiveIndex - capacity / 2), maximumStart)
        let visibleIndices = Array(start..<min(tabCount, start + capacity))
        let visibleSet = Set(visibleIndices)
        return LightboxTabStripLayout(
            visibleIndices: visibleIndices,
            hiddenIndices: (0..<tabCount).filter { !visibleSet.contains($0) }
        )
    }
}

private struct TabStrip: View {
    @EnvironmentObject private var appState: AppState
    @State private var fileDropTargetID: UUID?
    @State private var isOverflowPresented = false

    var body: some View {
        GeometryReader { proxy in
            let activeIndex = appState.tabs.firstIndex(where: { $0.id == appState.activeTabID }) ?? 0
            let layout = LightboxTabStripLayout.resolve(
                tabCount: appState.tabs.count,
                activeIndex: activeIndex,
                availableWidth: proxy.size.width
            )
            let controlWidth: CGFloat = layout.hiddenIndices.isEmpty ? 37 : 65
            let gaps = CGFloat(max(0, layout.visibleIndices.count)) * 2
            let availableTabWidth = max(52, proxy.size.width - controlWidth - gaps - 8)
            let tabWidth = min(148, max(52, availableTabWidth / CGFloat(max(1, layout.visibleIndices.count))))

            HStack(spacing: 2) {
                ForEach(layout.visibleIndices, id: \.self) { index in
                    let tab = appState.tabs[index]
                    LightboxTabButton(
                        tab: tab,
                        width: tabWidth,
                        isFileDropTargeted: fileDropTargetID == tab.id
                    )
                        .onDrag {
                            appState.beginTabDrag(tab.id)
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(of: [.utf8PlainText], isTargeted: nil) { _ in
                            appState.moveDraggedTab(before: tab.id)
                            appState.endTabDrag()
                            return true
                        }
                        .onDrop(
                            of: [UTType(exportedAs: LightboxPasteboardTypes.internalAssetDragIdentifier)],
                            delegate: TabAssetDropDelegate(
                                targetTabID: tab.id,
                                fileDropTargetID: $fileDropTargetID,
                                appState: appState
                            )
                        )
                }

                if !layout.hiddenIndices.isEmpty {
                    Button {
                        isOverflowPresented.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TopPathBarColor.regularText)
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
                    .help(appState.localized(.tabs))
                    .popover(isPresented: $isOverflowPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(layout.hiddenIndices, id: \.self) { index in
                                let tab = appState.tabs[index]
                                OverflowTabRow(
                                    tab: tab,
                                    isFileDropTargeted: fileDropTargetID == tab.id
                                ) {
                                    isOverflowPresented = false
                                }
                                .onDrop(
                                    of: [UTType(exportedAs: LightboxPasteboardTypes.internalAssetDragIdentifier)],
                                    delegate: TabAssetDropDelegate(
                                        targetTabID: tab.id,
                                        fileDropTargetID: $fileDropTargetID,
                                        appState: appState,
                                        activatesOnHover: false,
                                        onDropCompleted: { isOverflowPresented = false }
                                    )
                                )
                            }
                        }
                        .padding(6)
                        .frame(minWidth: 220, alignment: .leading)
                    }
                    .onDrop(
                        of: [UTType(exportedAs: LightboxPasteboardTypes.internalAssetDragIdentifier)],
                        delegate: TabOverflowDropDelegate(
                            hiddenTabIDs: layout.hiddenIndices.map { appState.tabs[$0].id },
                            isOverflowPresented: $isOverflowPresented,
                            appState: appState
                        )
                    )
                }

                Capsule()
                    .fill(TopPathBarColor.divider)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                Button {
                    appState.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TopPathBarColor.regularText)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
                .help(appState.localized(.newTab))
            }
            .padding(.horizontal, 4)
            .frame(width: proxy.size.width, height: 36, alignment: .leading)

        }
    }
}

private struct OverflowTabRow: View {
    @EnvironmentObject private var appState: AppState

    var tab: LightboxTab
    var isFileDropTargeted: Bool
    var onSelect: () -> Void

    var body: some View {
        Button {
            appState.selectTab(tab.id)
            onSelect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(appState.tabTitle(tab))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFileDropTargeted ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(appState.tabPath(tab))
    }
}

private struct LightboxTabButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var tab: LightboxTab
    var width: CGFloat
    var isFileDropTargeted: Bool

    private var isActive: Bool {
        tab.id == appState.activeTabID
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                appState.selectTab(tab.id)
            } label: {
                Text(appState.tabTitle(tab))
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? TopPathBarColor.strongText : TopPathBarColor.regularText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive || isHovering {
                Button {
                    appState.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(TopPathBarColor.regularText)
                        .frame(width: 20, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
                .help(appState.localized(.closeTab))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, isActive || isHovering ? 3 : 9)
        .frame(width: width, height: 28)
        .clipped()
        .background {
            if isActive || isHovering || isFileDropTargeted {
                if isFileDropTargeted {
                    LightboxSelectionSurface(
                        shape: Capsule(style: .continuous),
                        fillOpacity: LightboxSelectionTokens.dropFillOpacity,
                        strokeOpacity: LightboxSelectionTokens.emphasisStrokeOpacity,
                        lineWidth: LightboxSelectionTokens.emphasisLineWidth
                    )
                } else if isActive {
                    LightboxSelectionSurface(shape: Capsule(style: .continuous))
                } else {
                    LightboxSelectionSurface(
                        shape: Capsule(style: .continuous),
                        fillOpacity: LightboxSelectionTokens.hoverFillOpacity
                    )
                }
            }
        }
        .overlay {
            TabMiddleClickCatcher {
                appState.closeTab(tab.id)
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
        .help(appState.tabPath(tab))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appState.tabTitle(tab))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct TabAssetDropDelegate: DropDelegate {
    var targetTabID: UUID
    @Binding var fileDropTargetID: UUID?
    var appState: AppState
    var activatesOnHover = true
    var onDropCompleted: () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool {
        LightboxDragState.isDraggingAsset && appState.canReceiveFileDrop(on: targetTabID)
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        fileDropTargetID = targetTabID
        if activatesOnHover {
            appState.scheduleTabActivationForAssetDrag(targetTabID)
        }
    }

    func dropExited(info: DropInfo) {
        if fileDropTargetID == targetTabID {
            fileDropTargetID = nil
        }
        appState.cancelTabActivationForAssetDrag()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: currentOperation == .move ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            fileDropTargetID = nil
            appState.cancelTabActivationForAssetDrag()
            onDropCompleted()
        }
        guard validateDrop(info: info) else { return false }
        return appState.enqueueFileTransfer(
            sourceURLs: LightboxDragState.sourceURLs,
            to: targetTabID,
            operation: currentOperation
        )
    }

    private var currentOperation: FileTransferOperation {
        let eventHasOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let sessionHasOption = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        return eventHasOption || sessionHasOption ? .move : .copy
    }
}

private struct TabOverflowDropDelegate: DropDelegate {
    var hiddenTabIDs: [UUID]
    @Binding var isOverflowPresented: Bool
    var appState: AppState

    func validateDrop(info: DropInfo) -> Bool {
        LightboxDragState.isDraggingAsset
            && hiddenTabIDs.contains(where: appState.canReceiveFileDrop)
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        isOverflowPresented = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        false
    }
}

private struct FileTransferControl: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPopoverPresented = false

    var progress: FileTransferProgress

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 2)

                if progress.phase == .active {
                    Circle()
                        .trim(from: 0, to: max(0.035, progress.fractionCompleted))
                        .stroke(Color.accentColor.opacity(0.88), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: transferSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(transferColor)
            }
            .frame(width: 23, height: 23)
            .contentShape(Circle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
        .padding(5)
        .frame(width: 36, height: 36)
        .topBarGlass(Capsule())
        .shadow(
            color: .black.opacity(GlassTokens.floatingCapsuleShadowOpacity(appState.glassOpacity)),
            radius: 8,
            y: 3
        )
        .help(appState.fileTransferStatusText(progress))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(appState.fileTransferStatusText(progress))
                    .font(.system(size: 12, weight: .semibold))

                if !progress.currentName.isEmpty {
                    Text(progress.currentName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if progress.phase == .active {
                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)

                    Button(appState.localized(.cancel)) {
                        appState.cancelFileTransfer()
                    }
                    .font(.system(size: 11, weight: .semibold))
                } else {
                    Button(appState.localized(.close)) {
                        appState.dismissFileTransferStatus()
                        isPopoverPresented = false
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(14)
            .frame(width: 238, alignment: .leading)
        }
    }

    private var transferSymbol: String {
        switch progress.phase {
        case .active:
            progress.operation == .copy ? "doc.on.doc" : "arrow.right"
        case .completed:
            "checkmark"
        case .failed:
            "exclamationmark"
        case .cancelled:
            "xmark"
        }
    }

    private var transferColor: Color {
        switch progress.phase {
        case .active, .completed:
            Color.accentColor
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }

    private var accessibilityLabel: String {
        switch progress.phase {
        case .active:
            appState.localized(progress.operation == .copy ? .copyingFiles : .movingFiles)
        case .completed, .failed, .cancelled:
            appState.fileTransferStatusText(progress)
        }
    }

    private var accessibilityValue: String {
        var parts = ["\(min(progress.completedCount, progress.totalCount))/\(progress.totalCount)"]
        if progress.phase == .active {
            parts.append("\(Int((progress.fractionCompleted * 100).rounded()))%")
        }
        if !progress.currentName.isEmpty {
            parts.append(progress.currentName)
        }
        return parts.joined(separator: ", ")
    }
}

private struct TabMiddleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickView, context: Context) {
        nsView.action = action
    }
}

private final class MiddleClickView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent ?? NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2
        else {
            return nil
        }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        action?()
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
                    .background {
                        if appState.sortField == field {
                            LightboxSelectionSurface(
                                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                            )
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
                }
                .buttonStyle(LightboxButtonHoverStyle(
                    shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
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
                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
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
            shape: Capsule()
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
        .tint(LightboxColorTokens.accent)
        .accentColor(LightboxColorTokens.accent)
        }
        .onChange(of: isSourceMenuPresented) { presented in
            if presented {
                menuSnapshotSources = pinnedSources
                menuUnpinnedSourceIDs = unpinnedSourceIDs
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
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
                shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
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
                    .scaleEffect(pinIsPressed ? 0.96 : 1)
                    .rotationEffect(.degrees(pinIsPressed ? -10 : (isPinned ? 0 : -16)))
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
            .help(isPinned ? unpinTitle : pinTitle)
        }
        .frame(width: 258, height: 34)
        .background {
            if isSelected {
                LightboxSelectionSurface(
                    shape: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous)
                )
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
    var editPath: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let ancestors = Array(appState.breadcrumbs.dropLast())
        VStack(spacing: 1) {
            Button(action: editPath) {
                Text(appState.breadcrumbs.last?.title ?? appState.currentPathTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LightboxColorTokens.currentLocationText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(appState.currentFolderURL.path)
            if !ancestors.isEmpty {
                ViewThatFits(in: .horizontal) {
                    ancestorRow(ancestors)
                        .fixedSize(horizontal: true, vertical: false)
                    ancestorRow(Array(ancestors.suffix(1)), collapsed: ancestors)
                        .fixedSize(horizontal: true, vertical: false)
                    ancestorMenu(ancestors)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func ancestorMenu(_ ancestors: [PathBreadcrumb]) -> some View {
        Menu {
            ForEach(ancestors) { crumb in
                Button(crumb.title) { appState.openBreadcrumb(crumb) }
                    .help(crumb.url.path)
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(appState.currentFolderURL.path)
        .accessibilityLabel(appState.localized(.path))
    }

    private func ancestorRow(_ ancestors: [PathBreadcrumb], collapsed: [PathBreadcrumb] = []) -> some View {
        HStack(spacing: 3) {
            if !collapsed.isEmpty { ancestorMenu(collapsed) }
            ForEach(ancestors) { crumb in
                Button { appState.openBreadcrumb(crumb) } label: {
                    Text(crumb.title).lineLimit(1).padding(.horizontal, 3).frame(height: 22)
                }
                .buttonStyle(.plain)
                .help(crumb.url.path)
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .medium))
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(LightboxColorTokens.mutedText)
    }
}

private enum TopPathBarColor {
    static let strongText = LightboxColorTokens.primaryText
    static let regularText = LightboxColorTokens.secondaryText
    static let mutedText = LightboxColorTokens.mutedText
    static let faintText = LightboxColorTokens.mutedText
    static let disabledText = LightboxColorTokens.disabledText
    static let divider = LightboxColorTokens.border
}

private extension View {
    func topBarUtilitySurface(isActive: Bool) -> some View {
        modifier(TopBarUtilitySurfaceModifier(isActive: isActive))
    }

    func topBarGlass<S: Shape>(_ shape: S, isEnabled: Bool = true) -> some View {
        modifier(TopBarGlassModifier(shape: shape, isEnabled: isEnabled))
    }

    func selectionActionLabel(width: CGFloat) -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.86)
            .frame(width: width, height: 22)
            .contentShape(Capsule())
    }
}

// Keep utility chrome quiet without fading its symbol or keyboard focus.
private struct TopBarUtilitySurfaceModifier: ViewModifier {
    @Environment(\.lightboxGlassOpacity) private var glassOpacity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    var isActive: Bool

    func body(content: Content) -> some View {
        let showsSurface = isActive || isHovering
        content
            .background(LightboxColorTokens.primaryText.opacity(showsSurface ? 0.06 : 0), in: RoundedRectangle(cornerRadius: RadiusTokens.control))
            .shadow(
                color: .black.opacity(showsSurface ? GlassTokens.floatingCapsuleShadowOpacity(glassOpacity) : 0),
                radius: 8,
                y: 3
            )
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: showsSurface)
            .onHover { isHovering = $0 }
    }
}

private struct TopBarGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.lightboxGlassOpacity) private var glassOpacity
    @Environment(\.colorScheme) private var colorScheme

    var shape: S
    var isEnabled: Bool

    func body(content: Content) -> some View {
        let materialOpacity = isEnabled ? GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity) : 0
        let fillOpacity = isEnabled ? GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme) : 0
        let strokeOpacity = isEnabled ? GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity) : 0

        if #available(macOS 26.0, *) {
            content
                .background {
                    shape.fill(LightboxColorTokens.control.opacity(fillOpacity))
                }
                .background(.ultraThinMaterial.opacity(materialOpacity), in: shape)
                .glassEffect(isEnabled ? .clear.interactive(true) : .identity, in: shape)
                .overlay {
                    shape.stroke(LightboxColorTokens.primaryText.opacity(strokeOpacity), lineWidth: 0.7)
                }
        } else {
            content
                .background {
                    shape.fill(LightboxColorTokens.control.opacity(fillOpacity))
                }
                .background(.ultraThinMaterial.opacity(materialOpacity), in: shape)
                .overlay {
                    shape.stroke(LightboxColorTokens.primaryText.opacity(strokeOpacity), lineWidth: 0.7)
                }
        }
    }
}

/// Existing secondary controls keep their data and behavior while their anchors
/// and main navigation move into AppKit.
struct NativeHeaderPanel: View {
    enum Kind { case tabs, sort, selection, transfer }
    @ObservedObject var appState: AppState
    var kind: Kind
    var close: () -> Void = {}

    var body: some View {
        Group {
            switch kind {
            case .tabs: TabStrip().frame(width: 380, height: 36).padding(12)
            case .sort: SortPopover(close: close)
            case .selection: TopPathBar(selectionOnly: true)
            case .transfer:
                if let progress = appState.fileTransferProgress { FileTransferControl(progress: progress) }
            }
        }
        .environmentObject(appState)
        .tint(LightboxColorTokens.accent)
        .accentColor(LightboxColorTokens.accent)
        .environment(\.lightboxGlassOpacity, appState.glassOpacity)
        .preferredColorScheme(appState.preferredColorScheme)
    }
}
