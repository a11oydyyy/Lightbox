import AppKit
import OSLog
import SwiftUI

private let previewOverlayLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Preview")

struct PreviewOverlay: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var asset: LightboxAsset
    /// Source frame and session publish here rather than on `appState`.
    @ObservedObject var presentation: PreviewPresentationState
    @LightboxViewState private var isPresented = false
    @LightboxViewState private var isClosing = false
    @LightboxViewState private var showsInformation = false
    /// Showing the image at 100% (`PreviewLoupe`).
    @LightboxViewState private var isZoomed = false
    @LightboxViewState private var lockedPreviewSize: CGSize?
    @LightboxViewState private var lockedSourceFrame: CGRect?
    /// The image the locked geometry belongs to. A step to another image
    /// must never reuse the previous image's box (a landscape image squeezed
    /// into a portrait one), so geometry locked for another ID is ignored.
    @LightboxViewState private var lockedAssetID: LightboxAsset.ID?
    @LightboxViewState private var didStartPresentation = false
    @LightboxViewState private var presentationTask: Task<Void, Never>?
    @LightboxViewState private var highResolutionTask: Task<Void, Never>?
    @LightboxViewState private var imageQuality: ImageCacheQuality = .thumbnail
    /// Measured height of the details block below the image.
    @LightboxViewState private var controlsHeight: CGFloat = 64

    var body: some View {
        GeometryReader { proxy in
            let keyboardSessionID = appState.previewSessionID
            let computedSize = PreviewGeometry.previewSize(
                assetSize: CGSize(width: asset.width, height: asset.height),
                viewport: proxy.size
            )
            let locksGeometry = lockedAssetID == asset.id
            let size = (locksGeometry ? lockedPreviewSize : nil) ?? computedSize
            let computedSourceFrame = PreviewGeometry.sourceFrame(
                recordedFrame: appState.previewSourceFrame,
                fallbackSize: computedSize,
                viewport: proxy.size
            )
            let sourceFrame = (locksGeometry ? lockedSourceFrame : nil) ?? computedSourceFrame
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
            // Opened, a card's corners; at the thumbnail, the thumbnail's own
            // (the list's are smaller), so the close lands without a snap.
            let cornerRadius = PreviewGeometry.compensatedCornerRadius(
                displayRadius: isPresented ? RadiusTokens.card : appState.previewSourceCornerRadius,
                scale: scale,
                maxRadius: min(size.width, size.height) / 2
            )
            let controlsTop = PreviewGeometry.controlsTop(
                imageBottom: presentedFrame.maxY,
                controlsHeight: controlsHeight,
                viewportHeight: proxy.size.height
            )

            ZStack(alignment: .bottom) {
                PreviewKeyboardLayer(
                    requestsFocus: !showsInformation,
                    onFocusAcquired: { appState.markPreviewKeyboardFocusAcquired(sessionID: keyboardSessionID) },
                    onKeysActiveChanged: { active in
                        if appState.previewKeysActive != active { appState.previewKeysActive = active }
                    },
                    onInformation: { showsInformation = true },
                    onPrevious: {
                        appState.stepPreview(.previous)
                    },
                    onNext: {
                        appState.stepPreview(.next)
                    },
                    onCull: { mark in
                        appState.markPreviewAsset(mark)
                    },
                    onZoom: { toggleZoom() },
                    onClose: {
                        if showsInformation { showsInformation = false }
                        else if isZoomed { isZoomed = false }
                        else { closeAnimated() }
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

                PreviewBackgroundVeil()
                    .opacity(isPresented ? 1 : 0)
                    .animation(MotionTokens.ifAllowed(isPresented ? MotionTokens.chromeHide : MotionTokens.chromeReveal,
                                                      reduceMotion: reduceMotion), value: isPresented)
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
                            dragSourceURLs: { appState.dragSourceURLs(for: asset) },
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
                    // Clip in viewport coordinates, after scale and position. A
                    // partially hidden source must return beneath the opaque header.
                    .clipShape(PreviewImageViewportClip())
                    .opacity(showsLoupe ? 0 : 1)
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

                if showsLoupe {
                    PreviewLoupe(asset: asset, imageFrame: presentedFrame) { isZoomed = false }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .transition(.opacity)
                }

                PreviewControls(asset: asset, showsInfo: $showsInformation, onZoom: zoomAction)
                    .background {
                        GeometryReader { controls in
                            Color.clear
                                .onAppear { controlsHeight = controls.size.height }
                                .onChange(of: controls.size.height) { controlsHeight = $0 }
                        }
                    }
                    .previewChromePresentation(isVisible: isPresented && !showsLoupe, reduceMotion: reduceMotion)
                    .position(
                        x: proxy.size.width / 2,
                        y: controlsTop + controlsHeight / 2
                    )
            }
            .overlay {
                if appState.activeAssets.count > 1 {
                    HStack {
                        PreviewStepButton(symbol: "chevron.left", label: appState.localized(.previousImage)) {
                            appState.stepPreview(.previous)
                        }
                        Spacer(minLength: 0)
                        PreviewStepButton(symbol: "chevron.right", label: appState.localized(.nextImage)) {
                            appState.stepPreview(.next)
                        }
                    }
                    .padding(.horizontal, 22)
                    .previewChromePresentation(isVisible: isPresented && !showsLoupe, reduceMotion: reduceMotion)
                }
            }
            .overlay(alignment: .top) {
                if showsLoupe, appState.cullFeedback == nil {
                    PreviewZoomBadge()
                        .padding(.top, 58)
                        .transition(.opacity)
                }
            }
            .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: showsLoupe)
            .overlay(alignment: .top) {
                if let feedback = appState.cullFeedback {
                    CullFeedbackBadge(mark: feedback.mark)
                        .id(feedback.id)
                        .padding(.top, 58)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .task(id: feedback.id) {
                            try? await Task.sleep(for: .milliseconds(900))
                            guard !Task.isCancelled, appState.cullFeedback?.id == feedback.id else { return }
                            withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                                appState.cullFeedback = nil
                            }
                        }
                }
            }
            .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.cullFeedback)
            .overlay(alignment: .topTrailing) {
                Button(action: closeAnimated) {
                    Image(systemName: "xmark")
                        .font(.system(size: LightboxControlMetrics.iconSize, weight: .medium))
                        .foregroundStyle(LightboxColorTokens.secondaryText)
                        .frame(width: LightboxControlMetrics.iconButtonSize, height: LightboxControlMetrics.iconButtonSize)
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius)))
                .help(appState.localized(.close))
                .accessibilityLabel(appState.localized(.close))
                .padding(.top, 58)
                .padding(.trailing, 22)
            }
            .onAppear {
                if lockedAssetID != asset.id {
                    lockedAssetID = asset.id
                    lockedPreviewSize = computedSize
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
                appState.previewKeysActive = false
                presentationTask?.cancel()
                highResolutionTask?.cancel()
            }
            .onChange(of: asset.id) { _ in
                // Stepped onto something without pixels to zoom into (a document,
                // a deleted item): back to the fitted view. This closure may carry
                // the previous image's values, so ask the app state.
                if isZoomed, let current = appState.previewAsset,
                   !(current.isImage && current.sourceURL != nil && !current.isDeleted) {
                    isZoomed = false
                }
                previewOverlayLogger.info("preview overlay asset-change asset=\(asset.originalName, privacy: .public) direction=\(appState.previewStepDirection?.rawValue ?? "none", privacy: .public)")
                highResolutionTask?.cancel()
                imageQuality = .thumbnail
                // This closure may carry the previous image's values; read the
                // stepped-to image from the app state instead.
                if let current = appState.previewAsset {
                    lockGeometry(for: current, viewport: proxy.size)
                }
                if isPresented, !isClosing {
                    scheduleHighResolutionUpgrade()
                }
            }
            .onChange(of: CGSize(width: asset.width, height: asset.height)) { _ in
                // Real dimensions can arrive after the preview opened.
                guard let current = appState.previewAsset, current.id == lockedAssetID else { return }
                withAnimation(MotionTokens.ifAllowed(MotionTokens.previewGeometry, reduceMotion: reduceMotion)) {
                    lockGeometry(for: current, viewport: proxy.size)
                }
            }
            .onChange(of: appState.previewZoomRequest) { _ in toggleZoom() }
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

    private func lockGeometry(for current: LightboxAsset, viewport: CGSize) {
        let size = PreviewGeometry.previewSize(
            assetSize: CGSize(width: current.width, height: current.height),
            viewport: viewport
        )
        lockedAssetID = current.id
        lockedPreviewSize = size
        lockedSourceFrame = PreviewGeometry.sourceFrame(
            recordedFrame: appState.previewSourceFrame,
            fallbackSize: size,
            viewport: viewport
        )
    }

    /// Before locking a single value for the shown image, drop geometry that
    /// was locked for another one.
    private func claimLockedGeometry() {
        guard lockedAssetID != asset.id else { return }
        lockedAssetID = asset.id
        lockedPreviewSize = nil
        lockedSourceFrame = nil
    }

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

    private var canZoom: Bool {
        asset.isImage && asset.sourceURL != nil && !asset.isDeleted
    }

    private var showsLoupe: Bool { isZoomed && canZoom }

    private var zoomAction: (() -> Void)? {
        guard canZoom else { return nil }
        return { toggleZoom() }
    }

    private func toggleZoom() {
        guard isZoomed || (canZoom && isPresented && !isClosing) else { return }
        showsInformation = false
        isZoomed.toggle()
    }

    private func closeAnimated() {
        isZoomed = false
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
        if let currentFrame = appState.previewSpaceFrame(for: asset.id) {
            claimLockedGeometry()
            lockedSourceFrame = currentFrame
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
        isZoomed = false
        if let currentFrame = appState.previewSpaceFrame(for: asset.id) {
            claimLockedGeometry()
            lockedSourceFrame = currentFrame
        }
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
    var requestsFocus: Bool
    var onFocusAcquired: () -> Void
    var onKeysActiveChanged: (Bool) -> Void
    var onInformation: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onCull: (CullMark) -> Void
    var onZoom: () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> PreviewKeyboardView {
        let view = PreviewKeyboardView()
        view.onFocusAcquired = onFocusAcquired
        view.onKeysActiveChanged = onKeysActiveChanged
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onCull = onCull
        view.onZoom = onZoom
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: PreviewKeyboardView, context: Context) {
        nsView.onFocusAcquired = onFocusAcquired
        nsView.onKeysActiveChanged = onKeysActiveChanged
        nsView.onInformation = onInformation
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
        nsView.onCull = onCull
        nsView.onZoom = onZoom
        nsView.onClose = onClose
        nsView.requestedFocus = requestsFocus
    }
}

final class PreviewKeyboardView: NSView {
    var requestedFocus = false {
        didSet { if requestedFocus && !oldValue { requestFocusWhenAttached() } }
    }

    nonisolated(unsafe) private var keyWindowObservers: [NSObjectProtocol] = []

    deinit {
        keyWindowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWindowObservers.forEach(NotificationCenter.default.removeObserver)
        keyWindowObservers = []
        if let window {
            // A sheet or another window taking the keys turns the menu's P, X, U, Z off.
            keyWindowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    self?.reportKeysActive()
                }
            }
        }
        requestFocusWhenAttached()
        reportKeysActive()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        reportKeysActive()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        reportKeysActive()
        return resigned
    }

    /// After the responder change settles, and outside SwiftUI's view update.
    private func reportKeysActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = self.window
            self.onKeysActiveChanged(window?.isKeyWindow == true && window?.firstResponder === self)
        }
    }

    private func requestFocusWhenAttached() {
        guard requestedFocus, let window else { return }
        if window.firstResponder === self { onFocusAcquired(); return }
        // Input can arrive in the same event cycle that attaches the overlay.
        // The view has no synchronous state publication, so claim focus now.
        if window.makeFirstResponder(self) { onFocusAcquired(); return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.requestedFocus, self.window === window,
                  window.firstResponder !== self else { return }
            if window.makeFirstResponder(self) { self.onFocusAcquired() }
        }
    }
    var onInformation: () -> Void = {}
    var onFocusAcquired: () -> Void = {}
    var onKeysActiveChanged: (Bool) -> Void = { _ in }
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onCull: (CullMark) -> Void = { _ in }
    var onZoom: () -> Void = {}
    var onClose: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": onInformation(); return
        // Culling, as in Lightroom: pick, reject, unflag.
        case "p": onCull(.keep); return
        case "x": onCull(.reject); return
        case "u": onCull(.clear); return
        // 100% to check focus, as Lightroom's Z.
        case "z": onZoom(); return
        default: break
        }
        switch event.keyCode {
        case 123:
            onPrevious()
        case 124:
            onNext()
        case 53, 49:
            onClose()
        default:
            super.keyDown(with: event)
        }
    }
}

/// Confirms a culling mark: the Finder tag's color and the mark's name.
private struct CullFeedbackBadge: View {
    @EnvironmentObject private var appState: AppState
    var mark: CullMark

    private var symbol: String {
        switch mark {
        case .keep: "checkmark.circle.fill"
        case .reject: "xmark.circle.fill"
        case .clear: "circle.dashed"
        }
    }

    private var tint: Color {
        mark.tag.flatMap { tag in MacColorTag.all.first { $0.name == tag }?.color } ?? LightboxColorTokens.secondaryText
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(CullText(appState.appLanguage).feedback(mark))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.primaryText)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(LightboxColorTokens.control))
        .overlay(Capsule(style: .continuous).stroke(LightboxColorTokens.border.opacity(0.6), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Says the preview is at 100%.
private struct PreviewZoomBadge: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.secondaryText)
            Text(CullText(appState.appLanguage).zoomBadge)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.primaryText)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(LightboxColorTokens.control))
        .overlay(Capsule(style: .continuous).stroke(LightboxColorTokens.border.opacity(0.6), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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

/// Visible step affordance for the arrow keys; quiet at rest, clear on hover.
private struct PreviewStepButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    @LightboxViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
        .opacity(isHovering ? 1 : 0.55)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PreviewBackgroundVeil: View {

    var body: some View {
        // One opaque veil fades all underlying gallery/sidebar content together.
        Rectangle().fill(LightboxColorTokens.inspection)
    }
}

/// The gallery's opaque titlebar occupies the first 52 points of PreviewSpace.
/// Keep this boundary fixed throughout opening, closing, and interrupted transitions.
struct PreviewImageViewportClip: Shape {
    func path(in rect: CGRect) -> Path {
        let top = min(52, rect.height)
        return Path(CGRect(x: rect.minX, y: rect.minY + top,
                           width: rect.width, height: max(0, rect.height - top)))
    }
}
