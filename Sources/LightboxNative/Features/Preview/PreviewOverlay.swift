import AppKit
import OSLog
import SwiftUI

private let previewOverlayLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Preview")

struct PreviewOverlay: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var asset: LightboxAsset
    @State private var isPresented = false
    @State private var isClosing = false
    @State private var lockedPreviewSize: CGSize?
    @State private var lockedSourceFrame: CGRect?
    @State private var didStartPresentation = false
    @State private var presentationTask: Task<Void, Never>?
    @State private var highResolutionTask: Task<Void, Never>?
    @State private var imageQuality: ImageCacheQuality = .thumbnail

    var body: some View {
        GeometryReader { proxy in
            let computedSize = PreviewGeometry.previewSize(
                assetSize: CGSize(width: asset.width, height: asset.height),
                viewport: proxy.size
            )
            let size = lockedPreviewSize ?? computedSize
            let computedSourceFrame = PreviewGeometry.sourceFrame(
                recordedFrame: appState.previewSourceFrame,
                fallbackSize: computedSize,
                viewport: proxy.size
            )
            let sourceFrame = lockedSourceFrame ?? computedSourceFrame
            let visibleFrame = PreviewGeometry.visibleFrame(
                isPresented: isPresented,
                sourceFrame: sourceFrame,
                previewSize: size,
                viewport: proxy.size
            )
            let presentedFrame = PreviewGeometry.visibleFrame(
                isPresented: true,
                sourceFrame: sourceFrame,
                previewSize: size,
                viewport: proxy.size
            )
            let scale = PreviewGeometry.scale(sourceFrame: visibleFrame, previewSize: size)
            let cornerRadius = PreviewGeometry.compensatedCornerRadius(
                displayRadius: RadiusTokens.card,
                scale: scale,
                maxRadius: min(size.width, size.height) / 2
            )
            let controlsY = min(proxy.size.height - 58, presentedFrame.maxY + 86)

            ZStack(alignment: .bottom) {
                PreviewKeyboardLayer(
                    onPrevious: {
                        appState.stepPreview(.previous)
                    },
                    onNext: {
                        appState.stepPreview(.next)
                    },
                    onClose: {
                        closeAnimated()
                    }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                PreviewDismissInteractionLayer(
                    isInteractionEnabled: appState.isPreviewPresented,
                    onReadyChanged: { isReady in
                        appState.markPreviewInteractionLayerReady(isReady)
                    }
                ) { click in
                    handleOverlayClick(click)
                }
                    .ignoresSafeArea()

                PreviewBackgroundVeil(colorScheme: colorScheme)
                    .opacity(isPresented ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                AssetImageView(
                    asset: asset,
                    contentMode: .fit,
                    quality: imageQuality,
                    decodePriority: .high
                )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    // Fade the drop shadow with the open/close geometry so it
                    // doesn't pop when the overlay is removed at the end of close.
                    .shadow(color: .black.opacity(isPresented ? 0.16 : 0), radius: 14, y: 8)
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        AssetInteractionLayer(
                            debugSurface: "preview-image",
                            debugTargetName: asset.originalName,
                            assetTags: asset.tags,
                            assetURL: asset.sourceURL,
                            isDeleted: asset.isDeleted,
                            canRevealInFinder: asset.sourceURL != nil,
                            isInteractionEnabled: appState.isPreviewPresented,
                            compareMenuTitle: compareMenuTitle,
                            menuTitles: AssetContextMenuTitles(appState: appState),
                            showsPressFeedback: false,
                            triggersClickOnMouseDown: true,
                            onPressChanged: { _ in },
                            onClick: { click in
                                handlePreviewImageClick(click)
                            },
                            onRestore: {
                                appState.restore(asset)
                            },
                            onMoveToTrash: {
                                appState.markDeleted(asset)
                            },
                            onToggleTag: { tag in
                                appState.toggleTag(tag, to: asset)
                            },
                            onOpenWith: { applicationURL in
                                appState.openWithApplication(asset, applicationURL: applicationURL)
                            },
                            onRevealInFinder: {
                                appState.revealInFinder(asset)
                            },
                            onCopy: {
                                appState.copyToClipboard(asset)
                            },
                            onShare: { view in
                                appState.share(asset, from: view)
                            },
                            onAddToCompareTray: {
                                appState.addSelectedToCompareTray(fallback: asset)
                            }
                        )
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(x: scale.width, y: scale.height, anchor: .center)
                    .position(x: visibleFrame.midX, y: visibleFrame.midY)
                    // No `.compositingGroup()` here: during the open/close scale it
                    // forced an offscreen re-composite of the image + its radius-14
                    // shadow every frame (a slow path during the zoom). The view
                    // identity is stable while scaling (asset.id unchanged), so there
                    // is no crossfade that would need the group to flatten; the L/R
                    // step crossfade uses only the faint 0.16 shadow, where dropping
                    // the group is visually indistinguishable.
                    .transition(previewStepTransition)
                    .id(asset.id)
                    .animation(MotionTokens.ifAllowed(MotionTokens.preview, reduceMotion: reduceMotion), value: asset.id)

                PreviewControls(asset: asset)
                    .previewChromePresentation(isVisible: isPresented, reduceMotion: reduceMotion)
                    .position(
                        x: proxy.size.width / 2,
                        y: controlsY
                    )
            }
            .onAppear {
                if lockedPreviewSize == nil {
                    lockedPreviewSize = computedSize
                }
                if lockedSourceFrame == nil {
                    lockedSourceFrame = computedSourceFrame
                }
                previewOverlayLogger.info("preview overlay appear asset=\(asset.originalName, privacy: .public) viewport=\(previewSizeDescription(proxy.size), privacy: .public) previewSize=\(previewSizeDescription(size), privacy: .public) recordedFrame=\(previewFrameDescription(appState.previewSourceFrame), privacy: .public) lockedFrame=\(previewFrameDescription(lockedSourceFrame), privacy: .public)")
                if appState.isPreviewClosing {
                    isClosing = true
                    isPresented = false
                    return
                }
                startPresentationAnimation()
            }
            .onDisappear {
                previewOverlayLogger.info("preview overlay disappear asset=\(asset.originalName, privacy: .public) isPresented=\(isPresented, privacy: .public) isClosing=\(isClosing, privacy: .public)")
                appState.markPreviewInteractionLayerReady(false)
                presentationTask?.cancel()
                highResolutionTask?.cancel()
            }
            .onChange(of: asset.id) { _ in
                previewOverlayLogger.info("preview overlay asset-change asset=\(asset.originalName, privacy: .public) direction=\(appState.previewStepDirection?.rawValue ?? "none", privacy: .public)")
                highResolutionTask?.cancel()
                imageQuality = .thumbnail
                withAnimation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion)) {
                    lockedPreviewSize = computedSize
                    lockedSourceFrame = computedSourceFrame
                }
                if isPresented, !isClosing {
                    scheduleHighResolutionUpgrade()
                }
            }
            .onChange(of: appState.isPreviewClosing) { closing in
                if closing {
                    closeFromExternalRoute()
                } else if appState.isPreviewPresented, isClosing {
                    reopenFromExternalRoute()
                }
            }
        }
        .animation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion), value: isPresented)
    }

    // L/R stepping keeps the same overlay (only the image identity changes), so a
    // plain crossfade reads cleanly. A directional slide was tried but the spring
    // deceleration made each step look like hitting the end of an album — dropped.
    private var previewStepTransition: AnyTransition { .opacity }

    private var compareMenuTitle: String {
        if appState.selectedAssetIDs.count > 1, appState.selectedAssetIDs.contains(asset.id) {
            return appState.localized(.addSelectedToCompareTray)
        }

        return appState.localized(.addToCompareTray)
    }

    private func startPresentationAnimation() {
        guard !didStartPresentation else { return }
        didStartPresentation = true
        previewOverlayLogger.info("preview overlay schedule-open asset=\(asset.originalName, privacy: .public) reduceMotion=\(reduceMotion, privacy: .public)")

        guard !reduceMotion else {
            appState.hidePreviewSourceForCurrentPreview(asset.id)
            isPresented = true
            imageQuality = .preview
            previewOverlayLogger.info("preview overlay open instant asset=\(asset.originalName, privacy: .public)")
            return
        }

        presentationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            guard !isClosing else { return }
            previewOverlayLogger.info("preview overlay animate-open asset=\(asset.originalName, privacy: .public)")
            appState.hidePreviewSourceForCurrentPreview(asset.id)
            withAnimation(MotionTokens.previewGeometry) {
                isPresented = true
            }
            scheduleHighResolutionUpgrade()
        }
    }

    private func handleOverlayClick(_ click: LightboxClickContext) {
        routePreviewClick(click, point: click.localTopLeftLocation, surface: "overlay")
    }

    private func handlePreviewImageClick(_ click: LightboxClickContext) {
        routePreviewClick(click, point: click.windowTopLeftLocation, surface: "preview-image")
    }

    private func routePreviewClick(_ click: LightboxClickContext, point: CGPoint, surface: String) {
        let underlying = appState.previewSpaceHitDescription(at: point)
        if appState.isPreviewClosing,
           let hit = appState.previewSwitchTarget(at: point, excluding: asset.id) {
            previewOverlayLogger.info("preview overlay route-click action=switch-during-close surface=\(surface, privacy: .public) current=\(asset.originalName, privacy: .public) target=\(hit.asset.originalName, privacy: .public) \(LightboxClickFormatter.describe(click, previewSpacePoint: point), privacy: .public) underlying=\(underlying, privacy: .public)")
            presentationTask?.cancel()
            highResolutionTask?.cancel()
            isClosing = false
            appState.showPreview(for: hit.asset, sourceFrame: hit.frame)
            return
        }

        previewOverlayLogger.info("preview overlay route-click action=toggle surface=\(surface, privacy: .public) current=\(asset.originalName, privacy: .public) \(LightboxClickFormatter.describe(click, previewSpacePoint: point), privacy: .public) underlying=\(underlying, privacy: .public)")
        closeAnimated()
    }

    private func closeAnimated() {
        let didBeginPresentation = isPresented
        let delay: Duration = reduceMotion || !didBeginPresentation ? .milliseconds(60) : MotionTokens.previewGeometryDuration
        let sourceRevealDelay: Duration = reduceMotion || !didBeginPresentation ? .milliseconds(0) : MotionTokens.previewSourceRevealDelay
        previewOverlayLogger.info("preview overlay close-tap asset=\(asset.originalName, privacy: .public) isPresented=\(didBeginPresentation, privacy: .public) isClosing=\(isClosing, privacy: .public) delay=\(previewDurationDescription(delay), privacy: .public) revealDelay=\(previewDurationDescription(sourceRevealDelay), privacy: .public)")
        guard !isClosing else {
            guard appState.reopenPreviewDuringClose(for: asset.id) else {
                previewOverlayLogger.info("preview overlay stale-close ignored asset=\(asset.originalName, privacy: .public)")
                return
            }
            isClosing = false
            presentationTask?.cancel()
            highResolutionTask?.cancel()
            previewOverlayLogger.info("preview overlay reopen-tap asset=\(asset.originalName, privacy: .public)")
            withAnimation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion)) {
                isPresented = true
            }
            scheduleHighResolutionUpgrade()
            return
        }
        guard appState.beginInteractivePreviewClose(after: delay, revealSourceAfter: sourceRevealDelay) else {
            previewOverlayLogger.info("preview overlay close rejected-by-state asset=\(asset.originalName, privacy: .public)")
            return
        }
        isClosing = true
        presentationTask?.cancel()
        highResolutionTask?.cancel()
        withAnimation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion)) {
            isPresented = false
        }
    }

    private func closeFromExternalRoute() {
        guard !isClosing else { return }
        isClosing = true
        presentationTask?.cancel()
        highResolutionTask?.cancel()
        withAnimation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion)) {
            isPresented = false
        }
    }

    private func reopenFromExternalRoute() {
        isClosing = false
        presentationTask?.cancel()
        highResolutionTask?.cancel()
        withAnimation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion)) {
            isPresented = true
        }
        scheduleHighResolutionUpgrade()
    }

    private func scheduleHighResolutionUpgrade() {
        highResolutionTask?.cancel()
        highResolutionTask = Task { @MainActor in
            try? await Task.sleep(for: MotionTokens.previewHighResolutionDelay)
            guard !Task.isCancelled else { return }
            guard !isClosing, isPresented, appState.previewAssetID == asset.id else { return }
            previewOverlayLogger.info("preview overlay upgrade-image asset=\(asset.originalName, privacy: .public)")
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                imageQuality = .preview
            }
        }
    }
}

private struct PreviewKeyboardLayer: NSViewRepresentable {
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> PreviewKeyboardView {
        let view = PreviewKeyboardView()
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: PreviewKeyboardView, context: Context) {
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
        nsView.onClose = onClose
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class PreviewKeyboardView: NSView {
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onClose: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            onPrevious()
        case 124:
            onNext()
        case 53:
            onClose()
        default:
            super.keyDown(with: event)
        }
    }
}

private struct PreviewDismissInteractionLayer: NSViewRepresentable {
    var isInteractionEnabled: Bool
    var onReadyChanged: (Bool) -> Void
    var onClose: (LightboxClickContext) -> Void

    func makeNSView(context: Context) -> PreviewDismissInteractionView {
        let view = PreviewDismissInteractionView()
        view.isInteractionEnabled = isInteractionEnabled
        view.onReadyChanged = onReadyChanged
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: PreviewDismissInteractionView, context: Context) {
        nsView.isInteractionEnabled = isInteractionEnabled
        nsView.onReadyChanged = onReadyChanged
        nsView.onClose = onClose
        nsView.reportReadyIfNeeded()
    }
}

private final class PreviewDismissInteractionView: NSView {
    var isInteractionEnabled = true
    var onReadyChanged: (Bool) -> Void = { _ in }
    var onClose: (LightboxClickContext) -> Void = { _ in }
    private var lastReportedReady: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled,
              let event = window?.currentEvent ?? NSApp.currentEvent,
              event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control)
        else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportReadyIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        onClose(LightboxClickContext(event: event, in: self, trigger: .mouseDown))
    }

    func reportReadyIfNeeded() {
        let ready = window != nil
        guard lastReportedReady != ready else { return }
        lastReportedReady = ready
        DispatchQueue.main.async { [weak self] in
            self?.onReadyChanged(ready)
        }
    }
}

private func previewFrameDescription(_ frame: CGRect?) -> String {
    guard let frame else { return "nil" }
    return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
}

private func previewSizeDescription(_ size: CGSize) -> String {
    String(format: "w=%.1f h=%.1f", size.width, size.height)
}

private func previewDurationDescription(_ duration: Duration) -> String {
    "\(duration)"
}

private struct PreviewBackgroundVeil: View {
    var colorScheme: ColorScheme

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(colorScheme == .dark ? 0.18 : 0.42)
            }
    }
}
