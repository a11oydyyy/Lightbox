import AppKit
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LightboxViewState private var isResizingSidebar = false
    @LightboxViewState private var isTogglingSidebar = false
    @LightboxViewState private var sidebarToggleTask: Task<Void, Never>?

    // Natural footprint of the sidebar slot: glass (sidebarWidth + 10pt leading
    // pad) + the 8pt resize handle. Used as the expanded width the collapse
    // animates to/from.
    private var sidebarSlotWidth: CGFloat {
        appState.sidebarWidth + SidebarMetrics.panelLeadingInset + SidebarMetrics.resizeHandleWidth
    }

    private var overlayIsPresented: Bool {
        appState.previewAssetID != nil || appState.isComparing
    }

    // Native controls mirror the veil as soon as preview closing begins.
    private var overlayChromeVisible: Bool {
        appState.isOverlayChromeVisible
    }

    private var previewIsPresented: Bool {
        appState.previewAssetID != nil
    }

    private var chromeLeadingInset: CGFloat {
        !appState.sidebarCollapsed ? sidebarSlotWidth : 0
    }

    var body: some View {
        GeometryReader { window in
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
                    ResidentSidebarHost(appState: appState)
                        .frame(width: appState.sidebarWidth + SidebarMetrics.panelLeadingInset)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(appState.hasActiveOverlay || appState.sidebarCollapsed)
                    SidebarResizeHandle(isResizing: $isResizingSidebar)
                }
                .frame(width: !appState.sidebarCollapsed ? sidebarSlotWidth : 0, alignment: .trailing)
                .opacity(appState.sidebarCollapsed ? 0 : 1)
                // The preview's opaque veil reveals the sidebar together with
                // folder cards and directory headings, without a second fade.
                .previewChromePresentation(isVisible: !appState.isComparing, reduceMotion: reduceMotion)
                .allowsHitTesting(!appState.sidebarCollapsed && overlayChromeVisible && !overlayIsPresented)

                ZStack {
                    // Hold the gallery's column count steady while the sidebar slot
                    // animates, so the grid doesn't re-column every frame of the
                    // width change; it re-flows once on settle.
                    if appState.isShowingStartPage {
                        NewTabView()
                            .id(appState.activeTabID)
                            .accessibilityHidden(appState.hasActiveOverlay)
                            .disabled(appState.hasActiveOverlay)
                            .allowsHitTesting(!overlayIsPresented)
                    } else if appState.galleryViewMode == .list {
                        GalleryListView()
                            .accessibilityHidden(appState.hasActiveOverlay)
                            .id("\(appState.activeTabID.uuidString)|\(appState.selectedFilter.identityKey)|list")
                            .allowsHitTesting(!overlayIsPresented)
                    } else {
                    GalleryView(isResizingSidebar: isResizingSidebar || isTogglingSidebar)
                        .accessibilityHidden(appState.hasActiveOverlay)
                        .id("\(appState.activeTabID.uuidString)|\(appState.selectedFilter.identityKey)")
                        .allowsHitTesting(!overlayIsPresented)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.995)),
                                removal: .opacity
                            )
                        )
                    }

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .saturation(appState.isComparing ? 0.82 : 1)

            // Native titlebar controls remain above this opaque, non-interactive
            // surface so scrolling images cannot bleed through the header.
            VStack(spacing: 0) {
                LightboxColorTokens.canvas
                    .frame(height: 52)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(LightboxColorTokens.border.opacity(0.55))
                            .frame(height: 0.7)
                    }
                    .padding(.leading, chromeLeadingInset)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
            .zIndex(1)

            let comparisonAssets = appState.comparisonAssets
            if comparisonAssets.count >= 2 {
                ComparisonOverlay(assets: comparisonAssets)
                    .zIndex(2)
            }

            if !appState.isShowingStartPage {
            VStack {
                Spacer()
                BottomScaleControl(
                    maximumThumbnailWidth: GalleryThumbnailSizing.maximumWidth(
                        viewportWidth: max(1, window.size.width - chromeLeadingInset)
                    )
                )
                    .frame(maxWidth: .infinity)
                    .padding(.leading, chromeLeadingInset)
                    .opacity(appState.isComparing ? 0.42 : 1)
                    .bottomPreviewChromePresentation(isVisible: !appState.isComparing, reduceMotion: reduceMotion)
                    .allowsHitTesting(overlayChromeVisible && !previewIsPresented && !appState.isComparing)
                    .accessibilityHidden(appState.hasActiveOverlay)
                    // During close the veil restores the normal appearance;
                    // hit testing and accessibility remain blocked above.
                    .disabled(appState.hasActiveOverlay && !appState.isPreviewClosing)
                    .padding(.bottom, 18)
            }
            .zIndex(3)
            }

            PreviewOverlayHost(preview: appState.preview)
                .zIndex(4)

            PreviewRootClickCatcherLayer(appState: appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(5)
            }
            .coordinateSpace(name: "PreviewSpace")
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(
            MotionTokens.ifAllowed(MotionTokens.sidebarChrome, reduceMotion: reduceMotion),
            value: appState.sidebarCollapsed
        )
        .animation(MotionTokens.ifAllowed(MotionTokens.preview, reduceMotion: reduceMotion), value: appState.isComparing)
        .onChange(of: appState.sidebarCollapsed) {
            beginSidebarToggleFreeze()
        }
        .onDisappear {
            sidebarToggleTask?.cancel()
        }
        .sheet(item: $appState.renameRequest) { request in
            RenameSheet(appState: appState, request: request)
        }
        .sheet(item: $appState.folderRenameRequest) { request in
            RenameFolderSheet(appState: appState, request: request)
        }
        .sheet(item: $appState.newFolderRequest) { request in
            NewFolderSheet(appState: appState, request: request)
        }
        .alert(appState.fileOperationAlert ?? "", isPresented: Binding(
            get: { appState.fileOperationAlert != nil },
            set: { if !$0 { appState.fileOperationAlert = nil } }
        )) {}
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
    var body: some View {
        LightboxColorTokens.canvas
            .ignoresSafeArea()
    }
}

private struct SidebarResizeHandle: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isResizing: Bool
    @GestureState private var isDragging = false
    @LightboxViewState private var dragStartWidth: CGFloat?

    var body: some View {
        // Invisible hit area — the resize cursor on hover is the only affordance
        // (no visible bar/grabber, which flickered and read as clutter).
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: SidebarMetrics.resizeHandleWidth)
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

/// Shows the open preview. Stepping to another image publishes on
/// `appState.preview` rather than on `AppState`, so this host observes it and
/// the rest of the window stays put.
struct PreviewOverlayHost: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var preview: PreviewPresentationState

    var body: some View {
        if let asset = appState.previewAsset {
            PreviewOverlay(asset: asset, presentation: preview)
                .id(preview.sessionID)
        }
    }
}
