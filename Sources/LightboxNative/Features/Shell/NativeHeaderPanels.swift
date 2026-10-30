import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

private struct FileTransferControl: View {
    @EnvironmentObject private var appState: AppState
    @LightboxViewState private var isPopoverPresented = false

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
            .lightboxPopoverSurface()
        }
    }

    private var transferSymbol: String {
        switch progress.phase {
        case .active:
            switch progress.operation {
            case .copy: "doc.on.doc"
            case .move: "arrow.right"
            case .exportJPEG: "square.and.arrow.up"
            }
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
            progress.operation == .exportJPEG
                ? appState.exportText.exporting
                : appState.localized(progress.operation == .copy ? .copyingFiles : .movingFiles)
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

private extension View {
    func topBarGlass<S: Shape>(_ shape: S, isEnabled: Bool = true) -> some View {
        modifier(TopBarGlassModifier(shape: shape, isEnabled: isEnabled))
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
    enum Kind { case sort, selection, transfer }
    @ObservedObject var appState: AppState
    /// Transfer progress publishes here rather than on `appState`.
    @ObservedObject private var activity: BackgroundActivityState
    var kind: Kind
    var close: () -> Void = {}

    init(appState: AppState, kind: Kind, close: @escaping () -> Void = {}) {
        self.appState = appState
        activity = appState.activity
        self.kind = kind
        self.close = close
    }

    var body: some View {
        Group {
            switch kind {
            case .sort: SortPopover(close: close)
            case .selection: HeaderSelectionBar(selection: appState.selection)
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
