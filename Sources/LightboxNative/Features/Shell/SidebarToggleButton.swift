import AppKit
import SwiftUI

struct SidebarToggleButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var filterSelectionNamespace

    private let expandedTrailingInset: CGFloat = 14
    private let folderTitleLimit = 16

    private var isExpanded: Bool {
        !appState.sidebarCollapsed
    }

    private var visibleTags: [MacColorTag] {
        appState.libraryColorTags
    }

    private var expandedWidth: CGFloat {
        min(420, 61 + currentFolderSegmentWidth + trashSegmentWidth + CGFloat(visibleTags.count) * 25)
    }

    private var currentFolderSegmentTitle: String {
        appState.currentFolderSegmentTitle.limitedForFilterSegment(maxCharacters: folderTitleLimit)
    }

    private var currentFolderSegmentWidth: CGFloat {
        measuredSegmentWidth(currentFolderSegmentTitle, minimum: 34, maximum: 132)
    }

    private var trashSegmentWidth: CGFloat {
        measuredSegmentWidth(appState.localized(.trash), minimum: 42, maximum: 78)
    }

    private func measuredSegmentWidth(_ title: String, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let measured = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return min(maximum, max(minimum, measured + 18))
    }

    var body: some View {
        HStack(spacing: isExpanded ? 6 : 0) {
            Button {
                setExpanded(!isExpanded)
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary.opacity(0.86))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(LightboxButtonHoverStyle(shape: Circle(), hoverScale: 1.045, glowOpacity: 0.24))

            if isExpanded {
                Capsule()
                    .fill(.primary.opacity(0.10))
                    .frame(width: 1, height: 16)

                HStack(spacing: 5) {
                    FilterSegmentGroup(
                        currentTitle: currentFolderSegmentTitle,
                        currentWidth: currentFolderSegmentWidth,
                        trashWidth: trashSegmentWidth,
                        selectedFilter: appState.selectedFilter,
                        trashTitle: appState.localized(.trash),
                        selectionNamespace: filterSelectionNamespace,
                        choose: choose
                    )

                    ForEach(visibleTags) { tag in
                        TagFilterSegment(
                            title: tag.name,
                            helpTitle: appState.localizedColorTagFilterTitle(tag.name),
                            tint: tag.color,
                            isSelected: appState.selectedFilter == .tag(tag.name)
                        ) {
                            choose(.tag(tag.name))
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, isExpanded ? expandedTrailingInset : 0)
        .frame(width: isExpanded ? expandedWidth : 34, height: 34, alignment: .leading)
        .clipped()
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: isExpanded)
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.selectedFilter)
        .animation(MotionTokens.ifAllowed(MotionTokens.previewChrome, reduceMotion: reduceMotion), value: currentFolderSegmentTitle)
        .help(isExpanded ? appState.localized(.closeFilters) : appState.localized(.openFilters))
    }

    private func choose(_ filter: LibraryFilter) {
        withAnimation(MotionTokens.ifAllowed(.easeOut(duration: 0.24), reduceMotion: reduceMotion)) {
            appState.selectedFilter = filter
            appState.clearSelection()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
            appState.sidebarCollapsed = !expanded
        }
    }

}

private struct FilterSegmentGroup: View {
    var currentTitle: String
    var currentWidth: CGFloat
    var trashWidth: CGFloat
    var selectedFilter: LibraryFilter
    var trashTitle: String
    var selectionNamespace: Namespace.ID
    var choose: (LibraryFilter) -> Void

    var body: some View {
        HStack(spacing: 2) {
            FilterSegment(
                title: currentTitle,
                width: currentWidth,
                filter: .all,
                selectedFilter: selectedFilter,
                selectionNamespace: selectionNamespace,
                action: choose
            )

            FilterSegment(
                title: trashTitle,
                width: trashWidth,
                filter: .trash,
                selectedFilter: selectedFilter,
                selectionNamespace: selectionNamespace,
                action: choose
            )
        }
    }
}

private struct FilterSegment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var width: CGFloat
    var filter: LibraryFilter
    var selectedFilter: LibraryFilter
    var selectionNamespace: Namespace.ID
    var action: (LibraryFilter) -> Void

    private var isSelected: Bool {
        selectedFilter == filter
    }

    private var textColor: Color {
        Color.primary.opacity(isSelected ? 0.92 : 0.54)
    }

    var body: some View {
        Button {
            action(filter)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.86)
                .id(title)
                .modifier(FilterSegmentTitleTransition(reduceMotion: reduceMotion))
                .frame(width: width, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.white.opacity(0.20))
                            .matchedGeometryEffect(id: "libraryTrashSelection", in: selectionNamespace)
                            .overlay {
                                Capsule()
                                    .stroke(.white.opacity(0.28), lineWidth: 0.7)
                            }
                            .blendMode(.screen)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(), hoverScale: 1.018, glowOpacity: 0.12))
        .animation(MotionTokens.ifAllowed(MotionTokens.previewChrome, reduceMotion: reduceMotion), value: title)
    }
}

private struct FilterSegmentTitleTransition: ViewModifier {
    var reduceMotion: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.transition(.opacity)
        } else {
            content.transition(.opacity.combined(with: .lightboxBlurReplace))
        }
    }
}

private struct TagFilterSegment: View {
    var title: String
    var helpTitle: String
    var tint: Color
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(tint.opacity(isSelected ? 1 : 0.82))
                .frame(width: 10, height: 10)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.42), lineWidth: 0.7)
                }
                .frame(width: 20, height: 26)
            .background {
                if isSelected {
                    Capsule()
                        .fill(tint.opacity(0.16))
                        .overlay {
                            Capsule()
                                .stroke(tint.opacity(0.28), lineWidth: 0.8)
                        }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(), hoverScale: 1.04, glowOpacity: 0.16))
        .help(helpTitle)
    }
}

private extension String {
    func limitedForFilterSegment(maxCharacters: Int) -> String {
        guard count > maxCharacters, maxCharacters > 1 else { return self }
        return String(prefix(maxCharacters - 1)) + "..."
    }
}
