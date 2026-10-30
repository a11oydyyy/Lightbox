import AppKit
import OSLog
import SwiftUI

private let assetInteractionLogger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Preview")

struct AssetContextMenuTitles: Equatable {
    var copy: String
    var restore: String
    var moveToTrash: String
    var openWith: String
    var other: String
    var defaultApp: String
    var share: String
    var showInFinder: String
    var rename = "Rename…"
    var quickLook = "Quick Look"
    var openInPhotoshop = "Open in Photoshop"
    var exportJPEG = "Export as JPEG…"

    static let english = AssetContextMenuTitles(
        copy: "Copy",
        restore: "Restore",
        moveToTrash: "Move to Trash",
        openWith: "Open With",
        other: "Other...",
        defaultApp: "Default",
        share: "Share...",
        showInFinder: "Show in Finder"
    )

    init(
        copy: String,
        restore: String,
        moveToTrash: String,
        openWith: String,
        other: String,
        defaultApp: String,
        share: String,
        showInFinder: String
    ) {
        self.copy = copy
        self.restore = restore
        self.moveToTrash = moveToTrash
        self.openWith = openWith
        self.other = other
        self.defaultApp = defaultApp
        self.share = share
        self.showInFinder = showInFinder
    }

    @MainActor
    init(appState: AppState) {
        self.init(
            copy: appState.localized(.copy),
            restore: appState.localized(.restore),
            moveToTrash: appState.localized(.moveToTrash),
            openWith: appState.localized(.openWith),
            other: appState.localized(.other),
            defaultApp: appState.localized(.defaultApp),
            share: appState.localized(.share),
            showInFinder: appState.localized(.showInFinder)
        )
        rename = appState.renameText.menuItem
        quickLook = appState.localized(.quickLook)
        openInPhotoshop = appState.exportText.openInPhotoshop
        exportJPEG = appState.exportText.exportMenuItem
    }
}

struct AssetCardView: View, Equatable {
    var asset: LightboxAsset
    var keyboardFocusRequested = false
    var onKeyboard: (UInt16, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onPreviewArrow: (UInt16) -> Bool = { _ in false }
    var onActivate: (() -> Void)? = nil
    var isSelected: Bool
    var isExplicitlySelected: Bool
    var showsSelectionControl: Bool
    var imagePriority: ImageDecodePriority = .normal
    var imageQuality: ImageCacheQuality = .thumbnail
    var loadsImage = true
    var imageLoadingState: GalleryImageLoadingState?
    var compareTrayLabel: String?
    var isPreviewSourceHidden = false
    var isInteractionEnabled = true
    var compareMenuTitle: String
    var menuTitles: AssetContextMenuTitles
    var usesReducedHover = false
    var isComparePulse = false
    var showsPressFeedback = true
    var dragSourceURLs: () -> [URL] = { [] }
    var onClick: (LightboxClickContext) -> Void
    var onRestore: () -> Void
    var onMoveToTrash: () -> Void
    var onApplyTag: (String) -> Void
    var onOpenWith: (URL?) -> Void
    var onRevealInFinder: () -> Void
    var onCopy: () -> Void
    var onShare: (NSView) -> Void
    var onAddToCompareTray: () -> Void
    /// Nil leaves Rename out of the menu.
    var onRename: (() -> Void)?
    /// Nil leaves Export as JPEG out of the menu (it also needs Photoshop).
    var onExportJPEG: (() -> Void)?
    /// Space, when it does something other than `onActivate`; nil leaves
    /// Quick Look out of the menu.
    var onQuickLook: (() -> Void)?
    var onSpace: (() -> Void)?

    nonisolated static func == (lhs: AssetCardView, rhs: AssetCardView) -> Bool {
        lhs.keyboardFocusRequested == rhs.keyboardFocusRequested &&
        lhs.asset.id == rhs.asset.id &&
        lhs.asset.sourceURL == rhs.asset.sourceURL &&
        lhs.asset.originalName == rhs.asset.originalName &&
        lhs.asset.width == rhs.asset.width &&
        lhs.asset.height == rhs.asset.height &&
        lhs.asset.contentModifiedAt == rhs.asset.contentModifiedAt &&
        lhs.asset.fileSize == rhs.asset.fileSize &&
        lhs.asset.deletedAt == rhs.asset.deletedAt &&
        lhs.asset.tags == rhs.asset.tags &&
        lhs.asset.hasCameraRawSettings == rhs.asset.hasCameraRawSettings &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isExplicitlySelected == rhs.isExplicitlySelected &&
            lhs.showsSelectionControl == rhs.showsSelectionControl &&
            lhs.imagePriority == rhs.imagePriority &&
            lhs.imageQuality == rhs.imageQuality &&
            lhs.loadsImage == rhs.loadsImage &&
            lhs.imageLoadingState === rhs.imageLoadingState &&
            lhs.compareTrayLabel == rhs.compareTrayLabel &&
            lhs.isPreviewSourceHidden == rhs.isPreviewSourceHidden &&
            lhs.isInteractionEnabled == rhs.isInteractionEnabled &&
            lhs.compareMenuTitle == rhs.compareMenuTitle &&
            lhs.menuTitles == rhs.menuTitles &&
            lhs.usesReducedHover == rhs.usesReducedHover &&
            lhs.isComparePulse == rhs.isComparePulse &&
            lhs.showsPressFeedback == rhs.showsPressFeedback
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LightboxViewState private var isPressed = false
    @LightboxViewState private var showsKeyboardFocus = false

    var body: some View {
        Group {
            if !asset.isImage {
                FileTileView(asset: asset)
            } else if let imageLoadingState {
                GalleryAssetImageView(asset: asset, loadingState: imageLoadingState)
            } else {
                AssetImageView(asset: asset, quality: imageQuality, loadsImage: loadsImage)
                    .imageDecodePriority(imagePriority)
            }
        }
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous))
            .overlay {
                // strokeBorder draws inside the rounded clip (centered .stroke
                // bled half-outside, showing a corner box under scale effects,
                // most visibly in dark mode). primary adapts to color scheme.
                RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            }
            .overlay {
                if isComparePulse {
                    ComparePulseGlow(cornerRadius: RadiusTokens.card)
                        .transition(.opacity)
                }
            }
            .overlay {
                if isPressed {
                    PressFeedback(cornerRadius: RadiusTokens.card)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let compareTrayLabel {
                    CompareTrayMembershipBadge(label: compareTrayLabel)
                        .padding(8)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.hasCameraRawSettings == true {
                    CameraRawSettingsBadge()
                        .padding(.leading, 8)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                AssetColorTagStrip(tags: asset.tags)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .bottomTrailing)))
            }
            .opacity(isPreviewSourceHidden ? 0 : 1)
            // Flatten the clipped card + overlays before transforms so the
            // rounded corners can't overhang under scaleEffect.
            .compositingGroup()
            .contentShape(RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous))
            // Return the outline only after preview teardown restores gallery focus.
            .modifier(CardHoverChrome(
                isEnabled: isInteractionEnabled && !isPreviewSourceHidden,
                isFocused: showsKeyboardFocus,
                isHighlighted: isSelected,
                isExplicitlySelected: isExplicitlySelected,
                isSelecting: showsSelectionControl,
                reduceMotion: reduceMotion
            ))
            .overlay {
                AssetInteractionLayer(
                    keyboardFocusRequested: keyboardFocusRequested,
                    accessibilitySelected: isExplicitlySelected,
                    onKeyboard: onKeyboard,
                    onPreviewArrow: onPreviewArrow,
                    onActivate: onActivate,
                    onFocusChanged: { showsKeyboardFocus = $0 },
                    debugSurface: "gallery-card",
                    debugTargetName: asset.originalName,
                    assetTags: asset.tags,
                    assetURL: asset.sourceURL,
                    isDeleted: asset.isDeleted,
                    canRevealInFinder: asset.sourceURL != nil,
                    isInteractionEnabled: isInteractionEnabled,
                    compareMenuTitle: compareMenuTitle,
                    menuTitles: menuTitles,
                    showsPressFeedback: showsPressFeedback,
                    dragSourceURLs: dragSourceURLs,
                    onPressChanged: { isPressed in
                        self.isPressed = isPressed
                    },
                    onClick: onClick,
                    onRestore: onRestore,
                    onMoveToTrash: onMoveToTrash,
                    onToggleTag: onApplyTag,
                    onOpenWith: onOpenWith,
                    onRevealInFinder: onRevealInFinder,
                    onCopy: onCopy,
                    onShare: onShare,
                    onAddToCompareTray: onAddToCompareTray,
                    onRename: onRename,
                    onExportJPEG: onExportJPEG,
                    onQuickLook: onQuickLook,
                    onSpace: onSpace
                )
            }
            .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: isComparePulse)
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isPressed)
            .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isSelected)
    }
}

struct AssetInteractionLayer: NSViewRepresentable {
    var keyboardFocusRequested = false
    var accessibilitySelected = false
    var onKeyboard: (UInt16, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onPreviewArrow: (UInt16) -> Bool = { _ in false }
    var onActivate: (() -> Void)? = nil
    var onFocusChanged: (Bool) -> Void = { _ in }
    var debugSurface = "asset"
    var debugTargetName = "unknown"
    var assetTags: [String]
    var assetURL: URL?
    var isDeleted: Bool
    var canRevealInFinder: Bool
    var isInteractionEnabled: Bool
    var compareMenuTitle: String
    var menuTitles: AssetContextMenuTitles
    var showsPressFeedback: Bool
    var dragSourceURLs: () -> [URL]
    var triggersClickOnMouseDown = false
    var onPressChanged: (Bool) -> Void
    var onClick: (LightboxClickContext) -> Void
    var onRestore: () -> Void
    var onMoveToTrash: () -> Void
    var onToggleTag: (String) -> Void
    var onOpenWith: (URL?) -> Void
    var onRevealInFinder: () -> Void
    var onCopy: () -> Void
    var onShare: (NSView) -> Void
    var onAddToCompareTray: () -> Void
    var onRename: (() -> Void)? = nil
    var onExportJPEG: (() -> Void)? = nil
    var onQuickLook: (() -> Void)? = nil
    var onSpace: (() -> Void)? = nil

    func makeNSView(context: Context) -> AssetInteractionView {
        AssetInteractionView()
    }

    func updateNSView(_ nsView: AssetInteractionView, context: Context) {
        nsView.assetTags = assetTags
        nsView.debugSurface = debugSurface
        nsView.debugTargetName = debugTargetName
        nsView.assetURL = assetURL
        nsView.isDeleted = isDeleted
        nsView.canRevealInFinder = canRevealInFinder
        nsView.isInteractionEnabled = isInteractionEnabled
        nsView.compareMenuTitle = compareMenuTitle
        nsView.menuTitles = menuTitles
        nsView.showsPressFeedback = showsPressFeedback
        nsView.dragSourceURLs = dragSourceURLs
        nsView.triggersClickOnMouseDown = triggersClickOnMouseDown
        nsView.onPressChanged = onPressChanged
        nsView.onClick = onClick
        nsView.onRestore = onRestore
        nsView.onMoveToTrash = onMoveToTrash
        nsView.onToggleTag = onToggleTag
        nsView.onOpenWith = onOpenWith
        nsView.onRevealInFinder = onRevealInFinder
        nsView.onCopy = onCopy
        nsView.onShare = onShare
        nsView.onAddToCompareTray = onAddToCompareTray
        nsView.onRename = onRename
        nsView.onExportJPEG = onExportJPEG
        nsView.onQuickLook = onQuickLook
        nsView.onSpace = onSpace
        nsView.onKeyboard = onKeyboard
        nsView.onPreviewArrow = onPreviewArrow
        nsView.onActivate = onActivate
        nsView.onFocusChanged = onFocusChanged
        nsView.configureAccessibility(selected: accessibilitySelected)
        let requestsFocus = keyboardFocusRequested && isInteractionEnabled
        nsView.requestedKeyboardFocus = requestsFocus
    }
}

final class AssetInteractionView: NSView, NSDraggingSource {
    private struct AccessibilityConfiguration: Equatable {
        var name: String
        var tags: [String]
        var selected: Bool
        var enabled: Bool
        var hasActivation: Bool
        var copyTitle: String
        var compareTitle: String
    }

    private var accessibilityConfiguration: AccessibilityConfiguration?

    func configureAccessibility(selected: Bool) {
        let configuration = AccessibilityConfiguration(
            name: debugTargetName,
            tags: assetTags,
            selected: selected,
            enabled: isInteractionEnabled,
            hasActivation: onActivate != nil,
            copyTitle: menuTitles.copy,
            compareTitle: compareMenuTitle
        )
        let previous = accessibilityConfiguration
        guard previous != configuration else { return }
        if previous?.enabled != configuration.enabled {
            setAccessibilityElement(configuration.enabled)
            setAccessibilityEnabled(configuration.enabled)
        }
        if previous?.hasActivation != configuration.hasActivation {
            setAccessibilityRole(configuration.hasActivation ? .button : .image)
        }
        if previous?.name != configuration.name || previous?.tags != configuration.tags {
            setAccessibilityLabel(([configuration.name] + configuration.tags).joined(separator: ", "))
        }
        if previous?.selected != configuration.selected {
            setAccessibilitySelected(configuration.selected)
        }
        if previous?.name != configuration.name {
            toolTip = configuration.name
        }
        if previous?.copyTitle != configuration.copyTitle || previous?.compareTitle != configuration.compareTitle {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: configuration.copyTitle, target: self, selector: #selector(accessibilityCopy)),
                NSAccessibilityCustomAction(name: configuration.compareTitle, target: self, selector: #selector(accessibilityCompare))
            ])
        }
        accessibilityConfiguration = configuration
    }

    static func canRestoreGalleryFocus(over responder: NSResponder?) -> Bool {
        !(responder is NSTextView) && !(responder is NSControl)
    }
    private var showsKeyboardFocus = false
    var onFocusChanged: (Bool) -> Void = { _ in }

    private func publishFocusAppearance() {
        // AppKit can move focus while SwiftUI is updating; publish after the
        // responder transition, using its final state rather than a stale event.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFocusChanged(self.isInteractionEnabled && self.showsKeyboardFocus && self.window?.firstResponder === self)
        }
    }
    var requestedKeyboardFocus = false {
        didSet { if requestedKeyboardFocus && !oldValue { restoreFocusWhenAttached() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreFocusWhenAttached()
        publishFocusAppearance()
    }

    private func restoreFocusWhenAttached() {
        guard requestedKeyboardFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedKeyboardFocus, self.isInteractionEnabled,
                  Self.canRestoreGalleryFocus(over: self.window?.firstResponder)
            else { return }
            self.window?.makeFirstResponder(self)
        }
    }
    var onKeyboard: (UInt16, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onPreviewArrow: (UInt16) -> Bool = { _ in false }
    var onActivate: (() -> Void)?
    override var acceptsFirstResponder: Bool { isInteractionEnabled && debugSurface == "gallery-card" }

    override func becomeFirstResponder() -> Bool {
        showsKeyboardFocus = requestedKeyboardFocus || NSApp.currentEvent?.type == .keyDown
        publishFocusAppearance()
        return true
    }

    override func resignFirstResponder() -> Bool {
        publishFocusAppearance()
        return true
    }

    @objc func copy(_ sender: Any?) { guard isInteractionEnabled else { return }; onCopy() }
    override func selectAll(_ sender: Any?) { guard isInteractionEnabled else { return }; onKeyboard(0, .command) }
    @objc func accessibilityCopy() -> Bool { guard isInteractionEnabled else { return false }; onCopy(); return true }
    @objc func accessibilityCompare() -> Bool { guard isInteractionEnabled else { return false }; onAddToCompareTray(); return true }

    override func accessibilityPerformShowMenu() -> Bool {
        guard isInteractionEnabled, let window,
              let event = NSEvent.mouseEvent(with: .rightMouseDown,
                  location: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil),
                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { return false }
        showMenu(with: event)
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        guard isInteractionEnabled, let onActivate else { return false }
        onActivate()
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Keep arrows received by the old responder during initial overlay attachment.
        if debugSurface == "gallery-card", window?.firstResponder === self,
           [123, 124].contains(event.keyCode),
           modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
           onPreviewArrow(event.keyCode) { return }
        guard isInteractionEnabled else { return }
        showsKeyboardFocus = true
        publishFocusAppearance()
        // Leave system shortcuts, VoiceOver chords, and text handling to AppKit.
        guard !modifiers.contains(.control), !modifiers.contains(.option) else {
            super.keyDown(with: event); return
        }
        if event.keyCode == 109, modifiers.contains(.shift) {
            _ = accessibilityPerformShowMenu(); return
        }
        if !modifiers.contains(.command), event.keyCode == 49, let onSpace {
            onSpace(); return
        }
        if !modifiers.contains(.command), [36, 49, 76].contains(event.keyCode), let onActivate {
            onActivate(); return
        }
        if [123, 124, 125, 126, 53].contains(event.keyCode), !modifiers.contains(.command) {
            onKeyboard(event.keyCode, modifiers); return
        }
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            onKeyboard(0, modifiers); return
        }
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopy(); return
        }
        super.keyDown(with: event)
    }

    var debugSurface = "asset"
    var debugTargetName = "unknown"
    var assetTags: [String] = []
    var assetURL: URL?
    var isDeleted = false
    var canRevealInFinder = false
    // hitTest and accessibility reject disabled interaction. Hiding this transparent
    // view would also discard its existing keyboard focus before the overlay attaches.
    var isInteractionEnabled = true {
        didSet { if isInteractionEnabled != oldValue { publishFocusAppearance() } }
    }
    var compareMenuTitle = "Add to Compare Tray"
    var menuTitles = AssetContextMenuTitles.english
    var showsPressFeedback = true
    var dragSourceURLs: () -> [URL] = { [] }
    var triggersClickOnMouseDown = false
    var onPressChanged: (Bool) -> Void = { _ in }
    var onClick: (LightboxClickContext) -> Void = { _ in }
    var onRestore: () -> Void = {}
    var onMoveToTrash: () -> Void = {}
    var onToggleTag: (String) -> Void = { _ in }
    var onOpenWith: (URL?) -> Void = { _ in }
    var onRevealInFinder: () -> Void = {}
    var onCopy: () -> Void = {}
    var onShare: (NSView) -> Void = { _ in }
    var onAddToCompareTray: () -> Void = {}
    var onRename: (() -> Void)?
    var onExportJPEG: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onSpace: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled else {
            return nil
        }

        guard let event = window?.currentEvent ?? NSApp.currentEvent else {
            return nil
        }

        if event.type == .leftMouseDown ||
            event.type == .rightMouseDown ||
            event.type == .otherMouseDown {
            return self
        }

        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
            return
        }

        if event.clickCount >= 2, event.modifierFlags.intersection([.command, .shift]).isEmpty,
           let onActivate {
            onActivate()
            return
        }
        if debugSurface == "gallery-card",
           !showsPressFeedback || !event.modifierFlags.intersection([.command, .shift]).isEmpty {
            window?.makeFirstResponder(self)
        }
        trackClickOrDrag(from: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func trackClickOrDrag(from event: NSEvent) {
        guard let window else { return }

        let startPoint = convert(event.locationInWindow, from: nil)
        let clickModifiers = event.modifierFlags
        let shouldShowPress = showsPressFeedback &&
            !clickModifiers.contains(.command) &&
            !clickModifiers.contains(.shift)

        if triggersClickOnMouseDown {
            let click = LightboxClickContext(event: event, in: self, trigger: .mouseDown)
            logClick(click)
            onClick(click)
            return
        }

        if shouldShowPress {
            onPressChanged(true)
        }

        while true {
            guard let nextEvent = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                return
            }
            guard isInteractionEnabled else { onPressChanged(false); return }

            switch nextEvent.type {
            case .leftMouseDragged:
                let currentPoint = convert(nextEvent.locationInWindow, from: nil)
                let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)
                if distance > 4 {
                    if shouldShowPress {
                        onPressChanged(false)
                    }
                    beginExternalDrag(with: nextEvent)
                    return
                }
            case .leftMouseUp:
                guard bounds.contains(convert(nextEvent.locationInWindow, from: nil)) else {
                    onPressChanged(false)
                    return
                }
                let click = LightboxClickContext(event: nextEvent, in: self, trigger: .mouseUp)
                if shouldShowPress {
                    logClick(click)
                    onClick(click)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
                        self?.onPressChanged(false)
                    }
                } else {
                    logClick(click)
                    onClick(click)
                }
                return
            default:
                break
            }
        }
    }

    private func logClick(_ click: LightboxClickContext) {
        assetInteractionLogger.info("interaction click surface=\(self.debugSurface, privacy: .public) target=\(self.debugTargetName, privacy: .public) \(LightboxClickFormatter.describe(click), privacy: .public)")
    }

    private func beginExternalDrag(with event: NSEvent) {
        guard isInteractionEnabled, let assetURL else { return }
        let resolvedDragURLs = dragSourceURLs()
        let urls = resolvedDragURLs.isEmpty ? [assetURL] : resolvedDragURLs
        let draggingItems = urls.map { url in
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
            pasteboardItem.setString(url.absoluteString, forType: .URL)
            pasteboardItem.setString("1", forType: LightboxPasteboardTypes.internalAssetDrag)

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            draggingItem.setDraggingFrame(
                NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1),
                contents: NSImage(size: NSSize(width: 1, height: 1))
            )
            return draggingItem
        }
        LightboxDragState.beginAssetDrag(sourceURLs: urls)
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        LightboxDragState.endAssetDrag()
    }

    private func showMenu(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copyItem = actionItem(title: menuTitles.copy, action: #selector(copyAsset))
        copyItem.isEnabled = assetURL != nil
        menu.addItem(copyItem)

        let shareItem = actionItem(title: menuTitles.share, action: #selector(shareAsset))
        shareItem.isEnabled = assetURL != nil
        menu.addItem(shareItem)

        let openWithItem = NSMenuItem(title: menuTitles.openWith, action: nil, keyEquivalent: "")
        openWithItem.isEnabled = assetURL != nil
        if let assetURL {
            openWithItem.submenu = openWithMenu(for: assetURL)
        }
        menu.addItem(openWithItem)

        // Photoshop by name, as Bridge offers it: it is where Camera Raw
        // edits are finished, and it renders them for Export as JPEG.
        if !isDeleted, let assetURL, LightboxAsset.isImageName(assetURL.lastPathComponent),
           let photoshopURL = PhotoshopJPEGExport.applicationURL {
            let photoshopItem = actionItem(title: menuTitles.openInPhotoshop, action: #selector(openWithSelectedApplication(_:)))
            photoshopItem.representedObject = photoshopURL
            let icon = NSWorkspace.shared.icon(forFile: photoshopURL.path)
            icon.size = NSSize(width: 16, height: 16)
            photoshopItem.image = icon
            menu.addItem(photoshopItem)
            if onExportJPEG != nil {
                menu.addItem(actionItem(title: menuTitles.exportJPEG, action: #selector(exportJPEG)))
            }
        }

        if onQuickLook != nil {
            let quickLookItem = actionItem(title: menuTitles.quickLook, action: #selector(quickLookAsset))
            quickLookItem.isEnabled = assetURL != nil
            menu.addItem(quickLookItem)
        }

        if !isDeleted, onRename != nil {
            let renameItem = actionItem(title: menuTitles.rename, action: #selector(renameAsset))
            renameItem.isEnabled = assetURL != nil
            menu.addItem(renameItem)
        }

        menu.addItem(.separator())
        if isDeleted {
            menu.addItem(actionItem(title: menuTitles.restore, action: #selector(restore)))
        } else {
            let compareItem = actionItem(title: compareMenuTitle, action: #selector(addToCompareTray))
            // Only images compare.
            compareItem.isEnabled = assetURL.map { LightboxAsset.isImageName($0.lastPathComponent) } ?? false
            menu.addItem(compareItem)

        }

        let revealItem = actionItem(title: menuTitles.showInFinder, action: #selector(revealInFinder))
        revealItem.isEnabled = canRevealInFinder
        menu.addItem(revealItem)

        if !isDeleted {
            menu.addItem(.separator())

            let tagItem = NSMenuItem()
            let tagView = ColorTagMenuView(
                selectedTags: Set(assetTags),
                onToggleTag: { [weak self] tag in
                    guard let self, self.isInteractionEnabled else { return }
                    self.onToggleTag(tag)
                }
            )
            tagView.frame = NSRect(origin: .zero, size: tagView.intrinsicContentSize)
            tagItem.view = tagView
            menu.addItem(tagItem)
        }

        if !isDeleted {
            menu.addItem(.separator())
            menu.addItem(actionItem(title: menuTitles.moveToTrash, action: #selector(moveToTrash)))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let defaultApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        if let defaultApplicationURL {
            submenu.addItem(applicationMenuItem(defaultApplicationURL, isDefault: true))
            submenu.addItem(.separator())
        }

        let applications = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { applicationURL in
                guard let defaultApplicationURL else { return true }
                return applicationURL.standardizedFileURL.path != defaultApplicationURL.standardizedFileURL.path
            }
            .sorted { lhs, rhs in
                applicationName(for: lhs).localizedStandardCompare(applicationName(for: rhs)) == .orderedAscending
            }

        for applicationURL in applications {
            submenu.addItem(applicationMenuItem(applicationURL, isDefault: false))
        }

        if !applications.isEmpty {
            submenu.addItem(.separator())
        }

        submenu.addItem(actionItem(title: menuTitles.other, action: #selector(openWithOtherApplication)))
        return submenu
    }

    private func applicationMenuItem(_ applicationURL: URL, isDefault: Bool) -> NSMenuItem {
        let title = isDefault
            ? "\(applicationName(for: applicationURL)) (\(menuTitles.defaultApp))"
            : applicationName(for: applicationURL)
        let item = actionItem(title: title, action: #selector(openWithSelectedApplication(_:)))
        item.representedObject = applicationURL
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 18, height: 18)
        item.image = icon
        return item
    }

    private func applicationName(for applicationURL: URL) -> String {
        let displayName = FileManager.default.displayName(atPath: applicationURL.path)
        if displayName.hasSuffix(".app") {
            return String(displayName.dropLast(4))
        }
        return displayName
    }

    @objc private func restore() {
        guard isInteractionEnabled else { return }
        onRestore()
    }

    @objc private func moveToTrash() {
        guard isInteractionEnabled else { return }
        onMoveToTrash()
    }

    @objc private func revealInFinder() {
        guard isInteractionEnabled else { return }
        onRevealInFinder()
    }

    @objc private func renameAsset() {
        guard isInteractionEnabled else { return }
        onRename?()
    }

    @objc private func exportJPEG() {
        guard isInteractionEnabled else { return }
        onExportJPEG?()
    }

    @objc private func quickLookAsset() {
        guard isInteractionEnabled else { return }
        onQuickLook?()
    }

    @objc private func openWithSelectedApplication(_ item: NSMenuItem) {
        guard isInteractionEnabled else { return }
        onOpenWith(item.representedObject as? URL)
    }

    @objc private func openWithOtherApplication() {
        guard isInteractionEnabled else { return }
        onOpenWith(nil)
    }

    @objc private func copyAsset() {
        guard isInteractionEnabled else { return }
        onCopy()
    }

    @objc private func shareAsset() {
        guard isInteractionEnabled else { return }
        onShare(self)
    }

    @objc private func addToCompareTray() {
        guard isInteractionEnabled else { return }
        onAddToCompareTray()
    }
}

private struct CompareTrayMembershipBadge: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.primary.opacity(0.82))
            .frame(width: 22, height: 22)
            .background(.ultraThinMaterial.opacity(0.72), in: Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            .allowsHitTesting(false)
    }
}

/// Camera Raw has develop settings for the image (Bridge marks the same).
/// The thumbnail itself still shows the unedited original.
private struct CameraRawSettingsBadge: View {
    var body: some View {
        Image(systemName: "slider.horizontal.3")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.94))
            .frame(width: 18, height: 18)
            .background(.black.opacity(0.34), in: Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.42), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AssetColorTagStrip: View {
    var tags: [String]

    private var visibleTags: [MacColorTag] {
        let sortedNames = MacColorTag.sort(tags.filter(MacColorTag.isColorTag))
        let sortedTags = sortedNames.compactMap { name in
            MacColorTag.all.first { $0.name == name }
        }
        return Array(sortedTags.reversed())
    }

    var body: some View {
        if !visibleTags.isEmpty {
            HStack(spacing: MacTagDotMetrics.assetOverlaySpacing) {
                ForEach(visibleTags) { tag in
                    Circle()
                        .fill(tag.color)
                        .frame(
                            width: MacTagDotMetrics.assetOverlayDotDiameter,
                            height: MacTagDotMetrics.assetOverlayDotDiameter
                        )
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.78), lineWidth: MacTagDotMetrics.assetOverlayStrokeWidth)
                        }
                        .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private final class ColorTagMenuView: NSView {
    private let selectedTags: Set<String>
    private let onToggleTag: (String) -> Void
    private var trackingArea: NSTrackingArea?
    private var hoveredTagName: String? {
        didSet {
            guard hoveredTagName != oldValue else { return }
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: MacTagDotMetrics.menuIntrinsicWidth, height: MacTagDotMetrics.menuHeight)
    }

    init(selectedTags: Set<String>, onToggleTag: @escaping (String) -> Void) {
        self.selectedTags = selectedTags
        self.onToggleTag = onToggleTag
        super.init(frame: NSRect(
            origin: .zero,
            size: NSSize(width: MacTagDotMetrics.menuIntrinsicWidth, height: MacTagDotMetrics.menuHeight)
        ))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for tag in MacColorTag.all {
            let rect = dotRect(for: tag)
            let isSelected = selectedTags.contains(tag.name)
            let isHovered = hoveredTagName == tag.name

            if isSelected {
                let ringRect = rect.insetBy(dx: -3, dy: -3)
                NSColor.labelColor.withAlphaComponent(0.30).setStroke()
                let ringPath = NSBezierPath(ovalIn: ringRect)
                ringPath.lineWidth = 1.4
                ringPath.stroke()
            }

            if isHovered {
                let hoverRect = rect.insetBy(dx: -4, dy: -4)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 5
                shadow.shadowOffset = .zero
                shadow.shadowColor = NSColor.white.withAlphaComponent(0.48)
                shadow.set()

                NSColor.white.withAlphaComponent(0.82).setStroke()
                let hoverPath = NSBezierPath(ovalIn: hoverRect)
                hoverPath.lineWidth = 1.7
                hoverPath.stroke()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.labelColor.withAlphaComponent(0.24).setStroke()
                let edgePath = NSBezierPath(ovalIn: hoverRect.insetBy(dx: 0.5, dy: 0.5))
                edgePath.lineWidth = 0.8
                edgePath.stroke()
            }

            tag.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()

            NSColor.white.withAlphaComponent(0.45).setStroke()
            let edgePath = NSBezierPath(ovalIn: rect)
            edgePath.lineWidth = MacTagDotMetrics.menuStrokeWidth
            edgePath.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredTagName = MacColorTag.all.first(where: { hitRect(for: $0).contains(point) })?.name
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTagName = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tag = MacColorTag.all.first(where: { hitRect(for: $0).contains(point) }) else {
            return
        }

        onToggleTag(tag.name)
        enclosingMenuItem?.menu?.cancelTracking()
    }

    private func dotRect(for tag: MacColorTag) -> NSRect {
        let index = MacColorTag.all.firstIndex(of: tag) ?? 0
        let x = MacTagDotMetrics.menuHorizontalInset
            + CGFloat(index) * MacTagDotMetrics.menuHitDiameter
            + (MacTagDotMetrics.menuHitDiameter - MacTagDotMetrics.menuDotDiameter) / 2
        let y = (bounds.height - MacTagDotMetrics.menuDotDiameter) / 2
        return NSRect(
            x: x,
            y: y,
            width: MacTagDotMetrics.menuDotDiameter,
            height: MacTagDotMetrics.menuDotDiameter
        )
    }

    private func hitRect(for tag: MacColorTag) -> NSRect {
        let index = MacColorTag.all.firstIndex(of: tag) ?? 0
        let x = MacTagDotMetrics.menuHorizontalInset + CGFloat(index) * MacTagDotMetrics.menuHitDiameter
        return NSRect(x: x, y: 0, width: MacTagDotMetrics.menuHitDiameter, height: bounds.height)
    }
}

/// The card's hover-driven chrome under one pointer tracker: the outline
/// (hover, keyboard focus, selection) and the selection checkbox. Selected
/// cards always show their checkbox; while a selection is active, others show
/// an empty one only under the pointer or keyboard focus, so the grid stays
/// quiet. The checkbox is built only while shown: most cards never show one,
/// and every mounted card pays for what it builds. Hover lives here so it
/// re-renders only this chrome, not the card.
private struct CardHoverChrome: ViewModifier {
    var isEnabled: Bool
    var isFocused: Bool
    /// Selected or otherwise highlighted (the accent outline).
    var isHighlighted: Bool
    var isExplicitlySelected: Bool
    var isSelecting: Bool
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme
    @LightboxViewState private var isHovering = false

    private var showsOutline: Bool {
        isEnabled && (isFocused || isHighlighted || isHovering)
    }

    private var showsCheckbox: Bool {
        isExplicitlySelected || (isSelecting && (isHovering || isFocused))
    }

    private var outlineAnimation: Animation {
        isFocused ? MotionTokens.chromeReveal : MotionTokens.feedback
    }

    /// Focus without selection sits further out, so a gap separates it from the
    /// graphite selection ring that hugs the card at the same tone.
    private var outlineOffset: CGFloat {
        isFocused && !isHighlighted ? 4 : 2
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                ZStack {
                    if showsCheckbox {
                        SelectionCheckbox(isSelected: isExplicitlySelected)
                            .accessibilityHidden(true)
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: showsCheckbox)
                .animation(MotionTokens.ifAllowed(MotionTokens.feedback, reduceMotion: reduceMotion), value: isExplicitlySelected)
            }
            .overlay {
                RoundedRectangle(cornerRadius: RadiusTokens.card + outlineOffset, style: .continuous)
                    .stroke(isHighlighted ? LightboxColorTokens.accent : LightboxColorTokens.secondaryText.opacity(isFocused ? 1 : (colorScheme == .light ? 0.42 : 0.35)), lineWidth: isFocused ? 2 : (isHighlighted ? LightboxControlMetrics.focusLineWidth : 1))
                    .padding(-outlineOffset)
                    .opacity(showsOutline ? 1 : 0)
                    // Keep one resident outline through selection and focus handoff.
                    // Scope feedback to the outline so the returning image stays solid.
                    .animation(MotionTokens.ifAllowed(outlineAnimation, reduceMotion: reduceMotion), value: showsOutline)
                    .animation(MotionTokens.ifAllowed(outlineAnimation, reduceMotion: reduceMotion), value: isFocused)
                    .animation(MotionTokens.ifAllowed(outlineAnimation, reduceMotion: reduceMotion), value: isHighlighted)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .onChange(of: isEnabled) { if !$0 { isHovering = false } }
    }
}

private struct SelectionCheckbox: View {
    var isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: RadiusTokens.small, style: .continuous)
                .fill(.gray.opacity(isSelected ? 0.42 : 0.24))
                .overlay {
                    RoundedRectangle(cornerRadius: RadiusTokens.small, style: .continuous)
                        .stroke(.white.opacity(0.56), lineWidth: 0.8)
                }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

private struct ComparePulseGlow: View {
    var cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
            .stroke(LightboxColorTokens.accent, lineWidth: LightboxControlMetrics.focusLineWidth)
            .padding(-2)
            .allowsHitTesting(false)
    }
}

private struct PressFeedback: View {
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.black.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 0.8)
            }
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }
}

struct AssetImageDisplayState {
    private(set) var assetID: LightboxAsset.ID
    private(set) var image: NSImage?

    mutating func prepare(for assetID: LightboxAsset.ID, seed: NSImage?) {
        if self.assetID != assetID {
            self.assetID = assetID
            image = seed
        } else if let seed {
            image = seed
        }
    }

    mutating func applyDecoded(_ image: NSImage?, for assetID: LightboxAsset.ID) {
        guard self.assetID == assetID, let image else { return }
        self.image = image
    }

    mutating func clear() {
        image = nil
    }
}

struct AssetImageView: View {
    var asset: LightboxAsset
    var contentMode: ContentMode = .fill
    var quality: ImageCacheQuality = .thumbnail
    var decodePriority: ImageDecodePriority = .normal
    var loadsImage = true
    @LightboxViewState private var displayState: AssetImageDisplayState
    @LightboxViewState private var requestID = UUID()
    @LightboxViewState private var imageRequest: ImageCacheRequest?

    init(
        asset: LightboxAsset,
        contentMode: ContentMode = .fill,
        quality: ImageCacheQuality = .thumbnail,
        decodePriority: ImageDecodePriority = .normal,
        loadsImage: Bool = true
    ) {
        self.asset = asset
        self.contentMode = contentMode
        self.quality = quality
        self.decodePriority = decodePriority
        self.loadsImage = loadsImage
        _displayState = State(initialValue: AssetImageDisplayState(
            assetID: asset.id,
            image: Self.seedImage(for: asset, quality: quality, loadsImage: loadsImage)
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            imageContent
                .frame(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                .clipped()
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        Group {
            if let image = displayState.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(interpolationQuality)
                    .antialiased(true)
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: Self.imageRequestIdentity(for: asset, quality: quality, loadsImage: loadsImage)) {
            imageRequest?.cancel()
            imageRequest = nil
            guard loadsImage else {
                displayState.clear()
                requestID = UUID()
                return
            }

            guard let url = asset.sourceURL else {
                displayState.clear()
                return
            }
            let knownFileSignature = Self.knownFileSignature(for: asset)
            let seed = Self.seedImage(
                for: asset,
                quality: quality,
                loadsImage: loadsImage,
                knownFileSignature: knownFileSignature
            )
            displayState.prepare(for: asset.id, seed: seed)

            let currentRequestID = UUID()
            requestID = currentRequestID
            imageRequest = ImageCache.shared.image(
                for: url,
                quality: quality,
                knownFileSignature: knownFileSignature,
                priority: decodePriority
            ) { image in
                guard requestID == currentRequestID else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    displayState.applyDecoded(image, for: asset.id)
                }
                imageRequest = nil
            }
        }
        .onChange(of: decodePriority) { priority in
            imageRequest?.updatePriority(priority)
        }
        .onDisappear {
            imageRequest?.cancel()
            imageRequest = nil
            displayState.clear()
            requestID = UUID()
        }
    }

    private var interpolationQuality: Image.Interpolation {
        switch quality {
        case .preview, .comparison:
            return .high
        case .thumbnail, .thumbnailBalanced, .thumbnailFast, .thumbnailEmbedded:
            return .medium
        }
    }

    private var placeholder: some View {
        Color.clear
    }

    private static func seedImage(
        for asset: LightboxAsset,
        quality: ImageCacheQuality,
        loadsImage: Bool,
        knownFileSignature: FileContentSignature? = nil
    ) -> NSImage? {
        guard loadsImage, let url = asset.sourceURL else { return nil }
        return ImageCache.shared.bestCachedImage(
            for: url,
            quality: quality,
            knownFileSignature: knownFileSignature ?? Self.knownFileSignature(for: asset)
        )
    }

    static func imageRequestIdentity(
        for asset: LightboxAsset,
        quality: ImageCacheQuality,
        loadsImage: Bool
    ) -> String {
        let signature = asset.fileContentSignature?.cacheKeyComponent ?? "missing"
        return "\(asset.sourceURL?.path ?? ""):\(signature):\(quality.rawValue):\(loadsImage)"
    }

    static func knownFileSignature(for asset: LightboxAsset) -> FileContentSignature? {
        asset.fileContentSignature
    }
}

extension AssetImageView {
    func imageDecodePriority(_ priority: ImageDecodePriority) -> AssetImageView {
        var view = self
        view.decodePriority = priority
        return view
    }
}
