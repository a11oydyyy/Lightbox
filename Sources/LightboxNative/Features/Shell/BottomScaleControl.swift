import SwiftUI
import UniformTypeIdentifiers

struct BottomScaleControl: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tagFilterNamespace
    @Namespace private var glassNamespace
    var maximumThumbnailWidth: CGFloat

    private var bottomShadowOpacity: Double {
        GlassTokens.floatingCapsuleShadowOpacity(appState.glassOpacity)
    }

    private var thumbnailScaleRange: ClosedRange<CGFloat> {
        GalleryThumbnailSizing.minimumWidth...max(
            GalleryThumbnailSizing.minimumWidth,
            min(GalleryThumbnailSizing.maximumStoredWidth, maximumThumbnailWidth)
        )
    }

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                mainControlsRow
                    .frame(height: 34)
                    .padding(.leading, 13)
                    .padding(.trailing, 9)
                    .bottomControlGlass(Capsule(), id: "controls", in: glassNamespace)
                    .shadow(color: .black.opacity(bottomShadowOpacity), radius: 8, y: 3)
                    .overlay(alignment: filterDropletOnLeft ? .leading : .trailing) { filterDroplet }

                if !appState.compareTrayAssets.isEmpty {
                    CompareTrayControl()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.compareTrayAssets.map(\.id))
    }

    /// Beside the compare tray, the droplet hangs off the other end.
    private var filterDropletOnLeft: Bool { !appState.compareTrayAssets.isEmpty }

    /// The filters that are on, in a glass droplet of their own beside the
    /// bar. An overlay, outside the layout: the bar is centred, and a chip
    /// inside it moved every control as it came and went. On macOS 26 the
    /// droplet runs out of the bar's glass and back into it.
    private var filterDroplet: some View {
        let onLeft = filterDropletOnLeft
        return ZStack {
            if !appState.isViewingTrash, appState.attributeFilter.isActive {
                AttributeFilterDroplet()
                    .bottomControlGlass(Capsule(), id: "filters", in: glassNamespace)
                    .shadow(color: .black.opacity(bottomShadowOpacity), radius: 8, y: 3)
                    .transition(Self.dropletTransition(fromTrailing: !onLeft))
            }
        }
        .fixedSize()
        .alignmentGuide(onLeft ? .leading : .trailing) { d in onLeft ? d[.trailing] + 8 : d[.leading] - 8 }
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.attributeFilter)
    }

    private static func dropletTransition(fromTrailing: Bool) -> AnyTransition {
        if #available(macOS 26.0, *) {
            // The glass morph carries the shape; the label only fades.
            return .opacity
        }
        return .opacity.combined(with: .scale(scale: 0.6, anchor: fromTrailing ? .leading : .trailing))
    }

    // Inside the capsule, colors are the hierarchical styles, not the fixed
    // tokens: macOS 26 glass turns dark over dark photos even in light mode,
    // and only these follow it, so icons stay legible on either.
    private var divider: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 1)
    }

    private var mainControlsRow: some View {
        HStack(spacing: 10) {
            ViewModeToggle()

            // Thumbnail size means nothing to the list.
            if appState.galleryViewMode == .grid {
                divider

                // The slider's ends step whole columns: small adds one, large removes one.
                ColumnStepDot(diameter: 5, help: FilterText(appState.appLanguage).moreColumnsHelp) {
                    appState.stepThumbnailColumns(by: 1)
                }

                ThumbnailScaleField(scale: appState.thumbnailScale, range: thumbnailScaleRange)

                ColumnStepDot(diameter: 12, help: FilterText(appState.appLanguage).fewerColumnsHelp) {
                    appState.stepThumbnailColumns(by: -1)
                }
            }

            // What is shown and in what order: subfolders (grid only; the list
            // shows one folder) and the current sort. Nothing here changes
            // width with its state, so the centred bar never moves under the
            // pointer; filters that are on sit outside it (`filterDroplet`).
            divider

            HStack(spacing: 4) {
                if appState.galleryViewMode == .grid, !appState.isViewingTrash {
                    SubfolderScopeButton()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                SortFilterButton()
            }

            if !appState.libraryColorTags.isEmpty {
                BottomTagFilterStrip(selectionNamespace: tagFilterNamespace)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.libraryColorTags.map(\.id))
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.galleryViewMode)
    }

}

/// Gallery or list: two icons, the selected one in primary.
private struct ViewModeToggle: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = FileListText(appState.appLanguage)
        HStack(spacing: 2) {
            modeButton(.grid, symbol: "square.grid.2x2", title: text.asGrid)
            modeButton(.list, symbol: "rectangle.grid.1x2", title: text.asList)
        }
        .frame(height: 26)
    }

    private func modeButton(_ mode: GalleryViewMode, symbol: String, title: String) -> some View {
        let isSelected = appState.galleryViewMode == mode
        return Button {
            guard appState.galleryViewMode != mode else { return }
            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                appState.galleryViewMode = mode
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .frame(width: 30, height: 24)
                .bottomSelection(isSelected)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(style: .continuous)))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Include subfolders, on or off: an icon with the filter button's selected
/// capsule while on.
private struct SubfolderScopeButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOn = appState.galleryLayoutMode == .recursive
        Button {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                appState.galleryLayoutMode = appState.galleryLayoutMode.next
            }
        } label: {
            // The same width on or off: the bar must not move.
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                .frame(width: 30, height: 24)
                .bottomSelection(isOn)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(style: .continuous)))
        .help(appState.localized(.includeSubfoldersHelp))
        .accessibilityLabel(appState.localized(.includeSubfolders))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One end of the size slider as a button: a step of one image per row,
/// growing and darkening under the pointer and dipping when pressed.
private struct ColumnStepDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var diameter: CGFloat
    var help: String
    var action: () -> Bool
    @LightboxViewState private var isHovering = false

    var body: some View {
        Button {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.thumbnailScale, reduceMotion: reduceMotion)) {
                _ = action()
            }
        } label: {
            // A symbol, not a filled Circle: glass draws shapes in primary as a
            // mid grey, while symbols keep the full black (or white).
            Image(systemName: "circle.fill")
                .resizable()
                .foregroundStyle(isHovering ? HierarchicalShapeStyle.primary : .secondary)
                .frame(width: diameter, height: diameter)
                .scaleEffect(isHovering ? 1.3 : 1)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ColumnStepDotStyle())
        .onHover { isHovering = $0 }
        .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ColumnStepDotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The current sort, as Lightroom and Photos name what they show: the field
/// and its direction. Opens Sort & Filter (the sort order, then kind,
/// orientation, long edge, date added, file size and Camera Raw, then Show
/// Other Files) in a popover.
private struct SortFilterButton: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let text = FilterText(appState.appLanguage)
        let field = appState.sortFieldTitle(appState.sortField)
        Button {
            appState.showsAttributeFilterPanel.toggle()
        } label: {
            // As wide as the longest field, so a new sort never moves the bar
            // (or the open popover's arrow).
            ZStack {
                ForEach(GallerySortField.allCases, id: \.self) { option in
                    label(appState.sortFieldTitle(option)).hidden()
                }
                label(field)
            }
            // As dark as the slider's dots: secondary text reads lighter in glass.
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(style: .continuous)))
        .help(text.title)
        .accessibilityLabel(text.title)
        .accessibilityValue("\(field), \(appState.sortDirectionTitle)")
        .popover(isPresented: $appState.showsAttributeFilterPanel, arrowEdge: .top) {
            AttributeFilterPanel()
                .environmentObject(appState)
        }
    }

    private func label(_ field: String) -> some View {
        HStack(spacing: 4) {
            Text(field)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            Image(systemName: appState.sortDirectionIcon)
                .font(.system(size: 9.5, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 1)
        }
    }
}

/// The filters that are on: the choice itself for a single filter, a count
/// for more. Clicking it opens Sort & Filter; its × clears. On its own glass
/// (`BottomScaleControl.filterDroplet`).
private struct AttributeFilterDroplet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let text = FilterText(appState.appLanguage)
        let filter = appState.attributeFilter
        HStack(spacing: 0) {
            Button {
                appState.showsAttributeFilterPanel.toggle()
            } label: {
                Text(text.chip(filter))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
                    .padding(.trailing, 3)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(text.activeCount(filter.activeCount))
            .accessibilityLabel(text.chip(filter))

            Button {
                appState.attributeFilter = GalleryAttributeFilter()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
            .padding(.trailing, 5)
            .help(text.clear)
            .accessibilityLabel(text.clear)
        }
        .foregroundStyle(.primary)
    }
}

struct AttributeFilterPanel: View {
    @EnvironmentObject private var appState: AppState

    private func binding<Value>(_ keyPath: WritableKeyPath<GalleryAttributeFilter, Value>) -> Binding<Value> {
        Binding(
            get: { appState.attributeFilter[keyPath: keyPath] },
            set: { appState.attributeFilter[keyPath: keyPath] = $0 }
        )
    }

    var body: some View {
        let text = FilterText(appState.appLanguage)
        // Videos and documents are listed only with Show Other Files.
        let kinds = GalleryAttributeFilter.Kind.allCases.filter {
            appState.showsOtherFiles || ($0 != .videos && $0 != .documents)
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !appState.isViewingTrash {
                    Button(text.clear) {
                        appState.attributeFilter = GalleryAttributeFilter()
                    }
                    .controlSize(.small)
                    .disabled(!appState.attributeFilter.isActive)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                // How the folder is ordered, then what it shows.
                GridRow {
                    rowTitle(appState.localized(.sortBy))
                    HStack(spacing: 6) {
                        FilterSegmentRow(
                            title: appState.localized(.sortBy),
                            selection: Binding(get: { appState.sortField }, set: { appState.setSortField($0) }),
                            options: GallerySortField.allCases,
                            label: { appState.sortFieldTitle($0) }
                        )
                        SortDirectionButton()
                    }
                }
                // The trash only sorts.
                if !appState.isViewingTrash {
                GridRow {
                    Divider().gridCellColumns(2)
                }
                row(text.kind, selection: binding(\.kind), options: kinds, label: text.label)
                row(text.orientation, selection: binding(\.orientation),
                    options: GalleryAttributeFilter.Orientation.allCases, label: text.label)
                row(text.longEdge, selection: binding(\.pixelSize),
                    options: GalleryAttributeFilter.PixelSize.allCases, label: text.label)
                row(text.dateAdded, selection: binding(\.addedDate),
                    options: GalleryAttributeFilter.AddedDate.allCases, label: text.label)
                row(text.fileSize, selection: binding(\.fileSize),
                    options: GalleryAttributeFilter.FileSize.allCases, label: text.label)
                row(text.cameraRaw, selection: binding(\.cameraRaw),
                    options: GalleryAttributeFilter.CameraRaw.allCases, label: text.label)
                }
            }

            if !appState.isViewingTrash {
                Divider()

                Toggle(appState.localized(.showOtherFiles), isOn: $appState.showsOtherFiles)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
        }
        .padding(16)
        // At least 500pt; wider when a language's labels need it.
        .frame(minWidth: 500)
        .fixedSize()
        .lightboxPopoverSurface()
    }

    private func row<Option: Hashable>(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String
    ) -> some View {
        GridRow {
            rowTitle(title)
            FilterSegmentRow(title: title, selection: selection, options: options, label: label)
        }
    }

    /// One line at its natural width: the segments take the rest.
    private func rowTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LightboxColorTokens.secondaryText)
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
    }
}

/// Ascending or descending, as one arrow beside the sort fields.
private struct SortDirectionButton: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            appState.toggleSortDirection()
        } label: {
            Image(systemName: appState.sortDirection == .ascending ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.primaryText)
                .frame(width: 26, height: 26)
                .background(LightboxColorTokens.primaryText.opacity(0.045), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(style: .continuous)))
        .help(appState.sortDirectionTitle)
        .accessibilityLabel(appState.sortDirectionTitle)
    }
}

/// One filter's choices as equal segments that fill the row, with the scope
/// toggle's selected capsule. Native segmented controls keep their fitted
/// width, which left every row ending somewhere else.
private struct FilterSegmentRow<Option: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    var title: String
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String

    var body: some View {
        FilterSegmentsLayout(spacing: 2, inset: 12) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(Capsule(style: .continuous).fill(LightboxColorTokens.primaryText.opacity(0.045)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                selection = option
            }
        } label: {
            // Sized for the selected (semibold) label either way, so choosing
            // an option never nudges the row.
            ZStack {
                Text(label(option)).font(.system(size: 11, weight: .semibold)).hidden()
                Text(label(option))
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? LightboxColorTokens.primaryText : LightboxColorTokens.secondaryText)
            }
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    if isSelected {
                        LightboxSelectionSurface(shape: Capsule(style: .continuous))
                            .matchedGeometryEffect(id: "filterSegmentSelection", in: selectionNamespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(style: .continuous)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lays segments out in a row with at least `inset` on each side of every
/// label, then shares what is left of the row equally, so long labels such as
/// "Dimensions" keep the same margins as short ones and the row still fills.
private struct FilterSegmentsLayout: Layout {
    var spacing: CGFloat
    var inset: CGFloat

    private func minimumWidths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width + inset * 2 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let needed = minimumWidths(subviews).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        // An unbounded proposal (a container measuring flexibility) gets the needed width.
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? needed
        return CGSize(width: max(needed, proposed), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = minimumWidths(subviews)
        let needed = widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        let extra = max(0, bounds.width - needed) / CGFloat(max(1, subviews.count))
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            let size = CGSize(width: width + extra, height: bounds.height)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

private struct BottomTagFilterStrip: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var selectionNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: MacTagDotMetrics.selectionSpacing) {
            ForEach(appState.libraryColorTags) { tag in
                BottomTagFilterButton(
                    tag: tag,
                    isSelected: appState.selectedFilter == .tag(tag.name),
                    selectionNamespace: selectionNamespace
                ) {
                    withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                        appState.selectedFilter = appState.selectedFilter == .tag(tag.name) ? .all : .tag(tag.name)
                    }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        appState.clearSelection()
                    }
                }
            }
        }
        .frame(height: MacTagDotMetrics.selectionHeight)
    }
}

private struct BottomTagFilterButton: View {
    @EnvironmentObject private var appState: AppState
    var tag: MacColorTag
    var isSelected: Bool
    var selectionNamespace: Namespace.ID
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(tag.color.opacity(0.16))
                        .matchedGeometryEffect(id: "bottomTagFilterSelection", in: selectionNamespace)
                        .frame(
                            width: MacTagDotMetrics.selectionRingDiameter,
                            height: MacTagDotMetrics.selectionRingDiameter
                        )
                        .overlay {
                            Circle()
                                .stroke(tag.color.opacity(0.34), lineWidth: 0.8)
                        }
                }

                Circle()
                    .fill(tag.color.opacity(isSelected ? 1 : 0.84))
                    .frame(
                        width: MacTagDotMetrics.selectionDotDiameter,
                        height: MacTagDotMetrics.selectionDotDiameter
                    )
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.58), lineWidth: 0.7)
                    }
            }
            .frame(width: MacTagDotMetrics.selectionHitWidth, height: MacTagDotMetrics.selectionHeight)
            .contentShape(Circle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
        .help(appState.localizedColorTagFilterTitle(tag.name))
    }
}

/// The size slider observes the thumbnail scale directly: a drag re-renders
/// this field and the gallery, not the rest of the bottom bar.
private struct ThumbnailScaleField: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var scale: ThumbnailScaleState
    var range: ClosedRange<CGFloat>

    private var widthBinding: Binding<CGFloat> {
        Binding(
            get: { min(range.upperBound, max(range.lowerBound, scale.width)) },
            set: { value in
                let width = GalleryThumbnailSizing.clampedStoredWidth(value.rounded())
                guard appState.thumbnailWidth != width else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    appState.thumbnailWidth = width
                }
            }
        )
    }

    var body: some View {
        ThumbnailScaleSlider(value: widthBinding, range: range) { editing in
            // Releasing re-flows the grid to fill the row; let the cards glide there.
            withAnimation(editing ? nil : MotionTokens.ifAllowed(MotionTokens.thumbnailScale, reduceMotion: reduceMotion)) {
                appState.isScalingThumbnails = editing
            }
        }
            .accessibilityLabel(appState.localized(.imageSize))
            .accessibilityValue("\(Int(scale.width)) pt")
    }
}

private struct ThumbnailScaleSlider: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat>
    var onEditingChanged: (Bool) -> Void
    @LightboxViewState private var draftValue: CGFloat = 206
    @LightboxViewState private var isEditing = false
    @LightboxViewState private var updates = ThumbnailScaleUpdates()

    private let width: CGFloat = 86

    // Use the native macOS slider so the knob and its grabbed/pressed feel match
    // the system exactly (the earlier custom-drawn knob didn't).
    var body: some View {
        Slider(
            value: Binding(
                get: { Double(isEditing ? draftValue : value) },
                set: { next in
                    draftValue = CGFloat(next)
                    updates.submit(draftValue) { value = $0 }
                }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound),
            onEditingChanged: { editing in
                if editing { draftValue = value }
                else { updates.flush { value = $0 } }
                isEditing = editing
                onEditingChanged(editing)
            }
        )
        .controlSize(.small)
        .labelsHidden()
        .frame(width: width)
        .onDisappear {
            updates.cancel()
            onEditingChanged(false)
        }
    }
}

/// Keep the native slider tracking every input while the gallery receives only
/// the latest size in each 16 ms interval. Release always commits immediately.
@MainActor
final class ThumbnailScaleUpdates {
    private var pending: CGFloat?
    private var task: Task<Void, Never>?

    func submit(_ width: CGFloat, apply: @escaping @MainActor (CGFloat) -> Void) {
        pending = width
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self?.flush(apply: apply)
        }
    }

    func flush(apply: @MainActor (CGFloat) -> Void) {
        task?.cancel()
        task = nil
        guard let width = pending else { return }
        pending = nil
        apply(width)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}

private extension View {
    /// `id` names the glass so that, on macOS 26, shapes coming and going in
    /// the same `GlassGroup` run out of and back into it.
    func bottomControlGlass<S: Shape>(_ shape: S, id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        modifier(BottomControlGlassModifier(shape: shape, id: id, namespace: namespace))
    }

    /// A selected icon in the bar is filled and drawn in primary (black over
    /// light glass, white over dark); the others are outlines in tertiary. No
    /// capsule behind it: the icon itself says it is on. Its symbol needs a
    /// `.fill` variant, hence the list's `rectangle.grid.1x2`.
    func bottomSelection(_ isSelected: Bool) -> some View {
        symbolVariant(isSelected ? .fill : .none)
            .foregroundStyle(isSelected ? HierarchicalShapeStyle.primary : .tertiary)
    }
}

private struct BottomControlGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.lightboxGlassOpacity) private var glassOpacity
    @Environment(\.colorScheme) private var colorScheme

    var shape: S
    var id: String?
    var namespace: Namespace.ID?

    func body(content: Content) -> some View {
        let materialOpacity = GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity)
        let fillOpacity = GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme)
        let strokeOpacity = GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity)

        if #available(macOS 26.0, *) {
            // System glass tinted with the canvas: it keeps the glass edge and
            // depth, while vivid photos behind the bar only tint it instead of
            // showing through the labels.
            let glass = content.glassEffect(.regular.tint(LightboxColorTokens.canvas.opacity(GlassTokens.floatingCapsuleTintOpacity)), in: shape)
            if let id, let namespace {
                glass.glassEffectID(id, in: namespace)
            } else {
                glass
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

private struct CompareTrayControl: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LightboxViewState private var isDropTargeted = false
    @LightboxViewState private var rejectFlash = false

    private var trayShadowOpacity: Double {
        GlassTokens.floatingCapsuleShadowOpacity(appState.glassOpacity)
    }

    private let dropTypes: [UTType] = [
        .fileURL,
        UTType(exportedAs: LightboxPasteboardTypes.internalAssetDragIdentifier)
    ]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(appState.compareTrayAssets.enumerated()), id: \.element.id) { index, asset in
                    CompareTrayThumbnail(asset: asset, label: label(for: index))
                        .scaleEffect(appState.compareTrayPulseID == asset.id ? 1.025 : 1)
                        .onDrag {
                            appState.beginCompareTrayDrag(asset.id)
                            return NSItemProvider(object: asset.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: CompareTrayReorderDropDelegate(targetID: asset.id, appState: appState)
                        )
                }
            }

            Text("\(appState.compareTrayAssets.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 10)

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                    appState.startCompareTrayComparison()
                }
            } label: {
                Text(appState.localized(.compare))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 24)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Capsule()))
            .disabled(!appState.canStartCompareTrayComparison)

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                    appState.clearCompareTray()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
            .help(appState.localized(.clearCompareTray))
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .frame(height: 34)
        .bottomControlGlass(Capsule())
        .shadow(color: .black.opacity(trayShadowOpacity), radius: 8, y: 3)
        .overlay {
            Capsule()
                .stroke(compareTrayStrokeColor, lineWidth: 1)
        }
        .onDrop(of: dropTypes, isTargeted: $isDropTargeted) { providers in
            appState.handleCompareTrayDrop(providers: providers)
        }
        .onChange(of: appState.compareTrayRejectGeneration) { _ in
            flashRejectFeedback()
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: isDropTargeted)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: rejectFlash)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.compareTrayPulseID)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.compareTrayRejectGeneration)
    }

    private var compareTrayStrokeColor: Color {
        if rejectFlash {
            return .red.opacity(0.42)
        }
        return isDropTargeted ? LightboxColorTokens.accent.opacity(0.42) : .clear
    }

    private func flashRejectFeedback() {
        guard appState.compareTrayRejectGeneration > 0 else { return }
        rejectFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            rejectFlash = false
        }
    }

    private func label(for index: Int) -> String {
        "\(index + 1)"
    }
}

private struct CompareTrayThumbnail: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var asset: LightboxAsset
    var label: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AssetImageView(asset: asset, quality: .thumbnailFast)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                .overlay(alignment: .bottomLeading) {
                    Text(label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LightboxColorTokens.primaryText)
                        .frame(width: 14, height: 14)
                        .background(.ultraThinMaterial.opacity(0.80), in: Circle())
                        .padding(2)
                }

            Button {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                    appState.removeFromCompareTray(asset.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(LightboxColorTokens.secondaryText)
                    .frame(width: 13, height: 13)
                    .background(.ultraThinMaterial.opacity(0.86), in: Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(
                shape: Circle()
            ))
            .offset(x: 4, y: -4)
            .help(appState.localized(.remove))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(asset.originalName)
    }
}

private struct CompareTrayReorderDropDelegate: DropDelegate {
    var targetID: LightboxAsset.ID
    var appState: AppState

    func dropEntered(info: DropInfo) {
        appState.moveCompareTrayDraggedItem(onto: targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        appState.endCompareTrayDrag()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
