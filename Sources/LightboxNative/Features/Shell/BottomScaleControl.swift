import SwiftUI
import UniformTypeIdentifiers

struct BottomScaleControl: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var layoutModeNamespace
    @Namespace private var tagFilterNamespace
    var maximumThumbnailWidth: CGFloat

    private var bottomShadowOpacity: Double {
        GlassTokens.floatingCapsuleShadowOpacity(appState.glassOpacity)
    }

    private var thumbnailWidthBinding: Binding<CGFloat> {
        let range = thumbnailScaleRange
        return Binding(
            get: {
                min(range.upperBound, max(range.lowerBound, appState.thumbnailWidth))
            },
            set: { value in
                withAnimation(MotionTokens.ifAllowed(MotionTokens.thumbnailScale, reduceMotion: reduceMotion)) {
                    appState.thumbnailWidth = GalleryThumbnailSizing.clampedStoredWidth(value)
                }
            }
        )
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
                    .bottomControlGlass(Capsule())
                    .shadow(color: .black.opacity(bottomShadowOpacity), radius: 8, y: 3)

                if !appState.compareTrayAssets.isEmpty {
                    CompareTrayControl()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.compareTrayAssets.map(\.id))
    }

    private var mainControlsRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LightboxColorTokens.mutedText)
                .frame(width: 5, height: 5)
                .frame(width: 12)

            ThumbnailScaleSlider(value: thumbnailWidthBinding, range: thumbnailScaleRange)
                .accessibilityLabel(appState.localized(.imageSize))
                .accessibilityValue("\(Int(appState.thumbnailWidth)) pt")

            Circle()
                .fill(LightboxColorTokens.secondaryText)
                .frame(width: 12, height: 12)

            Capsule()
                .fill(LightboxColorTokens.border)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 1)

            LayoutModeTextToggle(selectionNamespace: layoutModeNamespace)

            if !appState.libraryColorTags.isEmpty {
                Capsule()
                    .fill(LightboxColorTokens.border)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 1)

                BottomTagFilterStrip(selectionNamespace: tagFilterNamespace)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion), value: appState.libraryColorTags.map(\.id))
    }

}

private struct LayoutModeTextToggle: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var selectionNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.masonry, title: appState.localized(.currentFolderScope))
            modeButton(.recursive, title: appState.localized(.includeSubfolders))
        }
        .frame(height: 26)
        .disabled(appState.isViewingTrash)
        .help(appState.localized(.includeSubfoldersHelp))
    }

    private func modeButton(_ mode: GalleryLayoutMode, title: String) -> some View {
        let isSelected = appState.galleryLayoutMode == mode

        return Button {
            guard appState.galleryLayoutMode != mode else { return }
            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                appState.galleryLayoutMode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? LightboxColorTokens.primaryText : LightboxColorTokens.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background {
                    if isSelected {
                        LightboxSelectionSurface(shape: Capsule(style: .continuous))
                            .matchedGeometryEffect(id: "layoutModeSelection", in: selectionNamespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule(style: .continuous)))
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

private struct ThumbnailScaleSlider: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat>

    private let width: CGFloat = 86

    // Use the native macOS slider so the knob and its grabbed/pressed feel match
    // the system exactly (the earlier custom-drawn knob didn't).
    var body: some View {
        Slider(
            value: Binding(
                get: { Double(value) },
                set: { value = CGFloat($0) }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound)
        )
        .controlSize(.small)
        .labelsHidden()
        .frame(width: width)
    }
}

private extension View {
    func bottomControlGlass<S: Shape>(_ shape: S) -> some View {
        modifier(BottomControlGlassModifier(shape: shape))
    }
}

private struct BottomControlGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.lightboxGlassOpacity) private var glassOpacity
    @Environment(\.colorScheme) private var colorScheme

    var shape: S

    func body(content: Content) -> some View {
        let materialOpacity = GlassTokens.floatingCapsuleMaterialOpacity(glassOpacity)
        let fillOpacity = GlassTokens.floatingCapsuleFillOpacity(glassOpacity, colorScheme: colorScheme)
        let strokeOpacity = GlassTokens.floatingCapsuleStrokeOpacity(glassOpacity)

        if #available(macOS 26.0, *) {
            content
                .background {
                    shape.fill(LightboxColorTokens.control.opacity(fillOpacity))
                }
                .background(.ultraThinMaterial.opacity(materialOpacity), in: shape)
                .glassEffect(.clear, in: shape)
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

private struct CompareTrayControl: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var rejectFlash = false

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
                .foregroundStyle(LightboxColorTokens.secondaryText)
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
            .opacity(appState.canStartCompareTrayComparison ? 1 : 0.48)

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
                withAnimation(MotionTokens.quick) {
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
        appState.moveCompareTrayDraggedItem(before: targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        appState.endCompareTrayDrag()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
