import AppKit
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overlayChromeVisible = true
    @State private var overlayChromeRevealTask: Task<Void, Never>?
    @State private var isResizingSidebar = false
    @State private var isTogglingSidebar = false
    @State private var sidebarToggleTask: Task<Void, Never>?
    @State private var sidebarSlotExpanded: Bool
    @State private var sidebarContentVisible: Bool
    @State private var sidebarVisibilityTask: Task<Void, Never>?

    init() {
        let isExpanded = !LightboxSettingsStore.loadSidebarCollapsed()
        _sidebarSlotExpanded = State(initialValue: isExpanded)
        _sidebarContentVisible = State(initialValue: isExpanded)
    }

    // Natural footprint of the sidebar slot: glass (sidebarWidth + 10pt leading
    // pad) + the 8pt resize handle. Used as the expanded width the collapse
    // animates to/from.
    private var sidebarSlotWidth: CGFloat {
        appState.sidebarWidth + 18
    }

    private var overlayIsPresented: Bool {
        appState.previewAssetID != nil || appState.isComparing
    }

    private var previewIsPresented: Bool {
        appState.previewAssetID != nil
    }

    private var usesCompatibilitySidebarMotion: Bool {
        LightboxRuntime.usesCompatibilityPerformanceMode
    }

    private var effectiveSidebarSlotExpanded: Bool {
        usesCompatibilitySidebarMotion ? sidebarSlotExpanded : !appState.sidebarCollapsed
    }

    private var effectiveSidebarContentVisible: Bool {
        usesCompatibilitySidebarMotion ? sidebarContentVisible : !appState.sidebarCollapsed
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            HStack(spacing: 0) {
                // Resident sidebar: collapse by animating the slot width + opacity
                // instead of inserting/removing the view. Tearing the whole tree
                // down/up on every ⌘B was the main-thread hang (full SidebarFolderNode
                // tree + per-row contextMenu + synchronous Finder-tag reads rebuilt
                // each toggle). Trailing alignment makes the resident content slide
                // left as the slot narrows; the window content edge masks the part
                // that runs off-screen and opacity finishes the hide. No SwiftUI
                // `.clipped()` here — it cut the glass capsule's drop shadow at the
                // slot edges (the visible seam), and the window edge already masks
                // the slide, so clipping bought nothing but the artifact.
                HStack(spacing: 0) {
                    GlassSidebar()
                    SidebarResizeHandle(isResizing: $isResizingSidebar)
                }
                .frame(width: effectiveSidebarSlotExpanded ? sidebarSlotWidth : 0, alignment: .trailing)
                .offset(x: usesCompatibilitySidebarMotion && !effectiveSidebarContentVisible ? -sidebarSlotWidth : 0)
                .opacity(effectiveSidebarContentVisible ? 1 : 0)
                .allowsHitTesting(effectiveSidebarContentVisible)
                .animation(
                    usesCompatibilitySidebarMotion
                        ? MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)
                        : nil,
                    value: sidebarContentVisible
                )

                ZStack {
                    // Hold the gallery's column count steady while the sidebar slot
                    // animates, so the grid doesn't re-column every frame of the
                    // width change; it re-flows once on settle.
                    GalleryView(isResizingSidebar: isResizingSidebar || isTogglingSidebar)
                        .id(appState.selectedFilter)
                        .allowsHitTesting(!overlayIsPresented)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.995)),
                                removal: .opacity
                            )
                        )

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .saturation(appState.isComparing ? 0.82 : 1)

            // Explicit z-order (back→front): top chrome (1) < comparison (2) <
            // bottom chrome (3) < preview (4). Two reasons the preview must sit on
            // top of both chrome bars:
            //   1. As the image scales back to its card it can pass under a capsule;
            //      if the capsule were on top it would clip/occlude the shrinking
            //      photo. Topmost preview is never occluded.
            //   2. The capsules' live `ultraThinMaterial` samples whatever renders
            //      below them. With the preview above, the bars blur the static
            //      gallery — not the moving preview image — which removes the frame
            //      drop when chrome returns during a close.
            // Bottom chrome stays above comparison (3 > 2) so its intentional faint
            // (0.42) state still shows over the opaque comparison backdrop.
            VStack {
                TopPathBar()
                    .previewChromePresentation(isVisible: overlayChromeVisible, reduceMotion: reduceMotion)
                    .allowsHitTesting(overlayChromeVisible && !overlayIsPresented)
                    .padding(.top, 17)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)

            let comparisonAssets = appState.comparisonAssets
            if comparisonAssets.count >= 2 {
                ComparisonOverlay(assets: comparisonAssets)
                    .zIndex(2)
            }

            VStack {
                Spacer()
                BottomScaleControl()
                    .opacity(appState.isComparing ? 0.42 : 1)
                    .bottomPreviewChromePresentation(isVisible: overlayChromeVisible, reduceMotion: reduceMotion)
                    .allowsHitTesting(overlayChromeVisible && !previewIsPresented && !appState.isComparing)
                    .padding(.bottom, 18)
            }
            .zIndex(3)

            if let asset = appState.previewAsset {
                PreviewOverlay(asset: asset)
                    .id(appState.previewSessionID)
                    .zIndex(4)
            }

            PreviewRootClickCatcherLayer(appState: appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(5)
        }
        .coordinateSpace(name: "PreviewSpace")
        .animation(
            usesCompatibilitySidebarMotion
                ? nil
                : MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion),
            value: appState.sidebarCollapsed
        )
        .animation(MotionTokens.ifAllowed(MotionTokens.preview, reduceMotion: reduceMotion), value: appState.isComparing)
        .onAppear {
            overlayChromeVisible = !overlayIsPresented
            synchronizeCompatibilitySidebarMotion(animated: false)
        }
        .onChange(of: overlayIsPresented) { isPresented in
            updateOverlayChromeVisibility(isOverlayPresented: isPresented)
        }
        .onChange(of: appState.sidebarCollapsed) { _ in
            beginSidebarToggleFreeze()
            synchronizeCompatibilitySidebarMotion(animated: true)
        }
        .onDisappear {
            overlayChromeRevealTask?.cancel()
            sidebarToggleTask?.cancel()
            sidebarVisibilityTask?.cancel()
        }
    }

    // The chrome bars (top path bar + bottom scale control) stay hidden for the
    // entire preview close and only fade back in *after* the overlay is removed
    // (previewAssetID cleared → overlayIsPresented false). Revealing them mid-close
    // made the floating pill fight the image as it zoomed back to a card sitting
    // under the pill — no z-order looked right, and a tail dissolve of the image
    // killed the satisfying "snap back home". Hiding chrome through the whole close
    // lets the image land solidly with nothing overlapping it; the pill then settles
    // back over the static grid. A short delay gives a clean "land, then chrome
    // returns" beat.
    private func updateOverlayChromeVisibility(isOverlayPresented: Bool) {
        overlayChromeRevealTask?.cancel()

        if isOverlayPresented {
            // Hide on open is instantaneous (the previewChromePresentation modifier
            // only animates the *show*, not the hide). If the pill faded out over
            // ~0.4s, the image zooming up from a card under the floating pill would
            // briefly draw on top of the still-visible pill — the "going out"
            // occlusion. Killing the pill on the frame the zoom begins fixes it.
            overlayChromeVisible = false
            return
        }

        guard !reduceMotion else {
            overlayChromeVisible = true
            return
        }

        overlayChromeRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            overlayChromeVisible = true
        }
    }

    // Freeze the gallery's column count for the duration of the ⌘B slot animation,
    // then release it so the grid re-columns once on settle instead of every frame.
    // Window matches MotionTokens.standard (response 0.28 spring) plus settle slack.
    private func beginSidebarToggleFreeze() {
        sidebarToggleTask?.cancel()

        guard !reduceMotion else {
            isTogglingSidebar = false
            return
        }

        isTogglingSidebar = true
        sidebarToggleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            isTogglingSidebar = false
        }
    }

    private func synchronizeCompatibilitySidebarMotion(animated: Bool) {
        guard usesCompatibilitySidebarMotion else { return }

        sidebarVisibilityTask?.cancel()
        let isExpanded = !appState.sidebarCollapsed
        let sidebarAnimation = MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)

        guard animated, !reduceMotion else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                sidebarSlotExpanded = isExpanded
                sidebarContentVisible = isExpanded
            }
            return
        }

        if isExpanded {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                sidebarSlotExpanded = true
            }

            sidebarVisibilityTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(sidebarAnimation) {
                    sidebarContentVisible = true
                }
            }
        } else {
            withAnimation(sidebarAnimation) {
                sidebarContentVisible = false
            }

            sidebarVisibilityTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }

                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    sidebarSlotExpanded = false
                }
            }
        }
    }
}

private struct PreviewRootClickCatcherLayer: NSViewRepresentable {
    var appState: AppState

    func makeNSView(context: Context) -> PreviewRootClickCatcherView {
        let view = PreviewRootClickCatcherView()
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: PreviewRootClickCatcherView, context: Context) {
        nsView.appState = appState
    }
}

private final class PreviewRootClickCatcherView: NSView {
    weak var appState: AppState?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let appState,
              appState.needsPreviewRootClickCatcher,
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

    override func mouseDown(with event: NSEvent) {
        appState?.handlePreviewRootClick(LightboxClickContext(event: event, in: self, trigger: .mouseDown))
    }
}

private struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    var body: some View {
        ZStack {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color(red: 0.96, green: 0.98, blue: 1.0).opacity(0.42),
                        .clear,
                        .black.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .opacity(isDarkMode ? 0 : 1)

            Color(red: 0.11, green: 0.11, blue: 0.12)
                .opacity(isDarkMode ? 1 : 0)
        }
        .ignoresSafeArea()
        .animation(MotionTokens.ifAllowed(.easeInOut(duration: 0.24), reduceMotion: reduceMotion), value: isDarkMode)
    }
}

private struct SidebarResizeHandle: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isResizing: Bool
    @GestureState private var isDragging = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        // Invisible hit area — the resize cursor on hover is the only affordance
        // (no visible bar/grabber, which flickered and read as clutter).
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else if !isDragging {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // Global coordinate space: the handle moves as the sidebar grows,
                // so a local-space translation feeds back and judders. Global is stable.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        if dragStartWidth == nil {
                            dragStartWidth = appState.sidebarWidth
                        }
                        if !isResizing {
                            isResizing = true
                        }
                        let startWidth = dragStartWidth ?? appState.sidebarWidth
                        appState.sidebarWidth = LightboxSettingsStore.clampSidebarWidth(
                            startWidth + gesture.translation.width
                        )
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        isResizing = false
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                    appState.sidebarWidth = LightboxSettingsStore.defaultSidebarWidth
                }
            }
    }
}
