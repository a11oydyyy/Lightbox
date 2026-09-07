import AppKit
import QuartzCore
import SwiftUI

/// All primary header hit targets live in the same AppKit titlebar accessory view.
@MainActor
final class NativeNavigationBar: NSView, NSSearchFieldDelegate, NSMenuItemValidation {
    private let appState: AppState
    private let back = KeyboardAwareHeaderButton()
    private let forward = KeyboardAwareHeaderButton()
    private let up = KeyboardAwareHeaderButton()
    private let search = KeyboardAwareHeaderButton()
    private let sort = KeyboardAwareHeaderButton()
    private let titleButton = KeyboardAwareHeaderButton()
    private let ancestors = NSPathControl()
    private let editor = NSTextField()
    private let searchField = NSSearchField()
    private let selectionHost: NSHostingView<NativeHeaderPanel>
    private let transferHost: NSHostingView<NativeHeaderPanel>
    private var popover: NSPopover?
    // Mutated only on the main actor; deinit only releases the opaque event token.
    nonisolated(unsafe) private var outsideClickMonitor: Any?
    private var editingPath = false
    private var searching = false
    private var lastSearchGeneration: Int
    private var lastPathGeneration: Int
    private var lastPath: String = ""
    private var lastViewingTrash = false
    private var lastSidebarCollapsed: Bool?
    private var layoutTargets: [ObjectIdentifier: NSRect] = [:]

    init(appState: AppState) {
        self.appState = appState
        lastSearchGeneration = appState.searchFocusGeneration
        searching = !appState.searchText.isEmpty
        lastPathGeneration = appState.goToFolderFocusGeneration
        selectionHost = NSHostingView(rootView: NativeHeaderPanel(appState: appState, kind: .selection))
        transferHost = NSHostingView(rootView: NativeHeaderPanel(appState: appState, kind: .transfer))
        super.init(frame: .zero)
        for (button, symbol, action) in [
            (back, "chevron.left", #selector(goBack)),
            (forward, "chevron.right", #selector(goForward)),
            (up, "chevron.up", #selector(goUp)),
            (search, "magnifyingglass", #selector(showSearch)),
            (sort, "line.3.horizontal.decrease", #selector(showSort))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: LightboxControlMetrics.iconSize, weight: .regular))
            button.focusRingType = .none
            button.isBordered = false
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            addSubview(button)
        }
        titleButton.focusRingType = .none
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 14, weight: .semibold)
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.target = self
        titleButton.action = #selector(beginPathEditing)
        addSubview(titleButton)
        ancestors.focusRingType = .none
        ancestors.pathStyle = .standard
        ancestors.backgroundColor = .clear
        ancestors.font = .systemFont(ofSize: 11)
        ancestors.target = self
        ancestors.action = #selector(openAncestor)
        addSubview(ancestors)
        editor.focusRingType = .none
        editor.delegate = self
        editor.font = .systemFont(ofSize: 12)
        editor.isHidden = true
        addSubview(editor)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 12)
        searchField.sendsSearchStringImmediately = true
        searchField.isHidden = true
        addSubview(searchField)
        selectionHost.sizingOptions = []
        transferHost.sizingOptions = []
        addSubview(selectionHost)
        addSubview(transferHost)
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(closeHeaderEditors), name: NSWindow.didResignKeyNotification, object: window)
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.editingPath && (event.window !== self.window || !self.editor.bounds.contains(self.editor.convert(event.locationInWindow, from: nil))) {
                self.cancelPathEditing()
            }
            if self.searching && (event.window !== self.window || !self.searchField.bounds.contains(self.searchField.convert(event.locationInWindow, from: nil))) {
                self.closeSearch()
            }
            if self.showHeaderContextMenu(for: event) { return nil }
            return event
        }
    }

    // The opaque SwiftUI header is intentionally non-interactive. Route context
    // clicks before they fall through its empty areas into the gallery below.
    private func showHeaderContextMenu(for event: NSEvent) -> Bool {
        guard !isHidden, let window, event.window === window,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        else { return false }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let topInset = window.frame.maxY - screenPoint.y
        // Leave the native window controls and sidebar toggle to AppKit.
        guard topInset >= 0, topInset < 52, screenPoint.x - window.frame.minX >= 152 else { return false }
        if editingPath && editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) { return false }
        if searching && searchField.bounds.contains(searchField.convert(event.locationInWindow, from: nil)) { return false }
        guard let menu = titleButton.menu else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }

    deinit {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func cancelPathEditing() {
        guard editingPath else { return }
        editingPath = false
        if editor.currentEditor() != nil { window?.makeFirstResponder(nil) }
        needsLayout = true
    }

    private func closeSearch() {
        guard searching else { return }
        searching = false
        if searchField.currentEditor() != nil { window?.makeFirstResponder(nil) }
        needsLayout = true
    }

    @objc private func closeHeaderEditors() {
        cancelPathEditing()
        closeSearch()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(pinPath) { return appState.canPinCurrentPath }
        return true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    private func label(_ button: NSButton, _ text: String) {
        button.toolTip = text
        button.setAccessibilityLabel(text)
    }

    func refresh() {
        let enabled = appState.previewAssetID == nil && !appState.isComparing
        isHidden = !enabled
        label(back, appState.localized(.goBack))
        label(forward, appState.localized(.goForward))
        label(up, appState.localized(.goToParentFolder))
        label(search, appState.localized(.search))
        label(sort, appState.localized(.sort))
        back.isEnabled = appState.canGoBack
        forward.isEnabled = appState.canGoForward
        up.isEnabled = appState.canOpenParentFolder
        let startPage = appState.isShowingStartPage
        let path = startPage ? "" : appState.currentFolderURL.path
        let pathChanged = path != lastPath
        if pathChanged {
            lastPath = path
            editingPath = false
        }
        titleButton.title = startPage ? appState.localized(.newTab) : appState.isViewingTrash ? appState.localized(.trash) : (appState.breadcrumbs.last?.title ?? appState.currentPathTitle)
        titleButton.contentTintColor = .labelColor
        titleButton.toolTip = path
        titleButton.setAccessibilityLabel(titleButton.title)
        if pathChanged || lastViewingTrash != appState.isViewingTrash {
            lastViewingTrash = appState.isViewingTrash
            ancestors.pathItems = (startPage || appState.isViewingTrash) ? [] : appState.breadcrumbs.dropLast().compactMap { crumb in
                let pathControl = NSPathControl()
                pathControl.url = crumb.url
                guard let item = pathControl.pathItems.last else { return nil }
                item.attributedTitle = NSAttributedString(string: crumb.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                item.image = nil
                return item
            }
            let menu = NSMenu()
            for crumb in (appState.isViewingTrash ? [] : Array(appState.breadcrumbs.dropLast())) {
                let item = NSMenuItem(title: crumb.title, action: #selector(openPathMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = crumb.url
                menu.addItem(item)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for (title, action) in [(appState.localized(.copyPath), #selector(copyPath)), (appState.localized(.showInFinder), #selector(revealCurrentFolder)), (appState.localized(.pinCurrentPath), #selector(pinPath))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            titleButton.menu = menu
        }
        if startPage {
            titleButton.menu = nil
            closeSearch()
            popover?.close()
        }
        titleButton.isEnabled = !startPage
        ancestors.toolTip = path
        ancestors.setAccessibilityLabel(appState.localized(.path))
        editor.placeholderString = appState.localized(.folderPathPlaceholder)
        editor.setAccessibilityLabel(appState.localized(.folderPathPlaceholder))
        searchField.placeholderString = appState.localized(.search)
        searchField.setAccessibilityLabel(appState.localized(.search))
        if searchField.stringValue != appState.searchText { searchField.stringValue = appState.searchText }
        search.contentTintColor = appState.searchText.isEmpty ? .secondaryLabelColor : NSColor(LightboxColorTokens.accent)
        search.toolTip = appState.searchText.isEmpty ? appState.localized(.search) : "\(appState.localized(.search)): \(appState.searchText)"
        if lastSearchGeneration != appState.searchFocusGeneration {
            lastSearchGeneration = appState.searchFocusGeneration
            showSearch()
        }
        if lastPathGeneration != appState.goToFolderFocusGeneration {
            lastPathGeneration = appState.goToFolderFocusGeneration
            beginPathEditing()
        }
        if !enabled { popover?.close() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let collapsed = appState.sidebarCollapsed
        let animated = lastSidebarCollapsed != nil && lastSidebarCollapsed != collapsed
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastSidebarCollapsed = collapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? MotionTokens.sidebarChromeDurationSeconds : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 1)
            layoutControls(animated: animated)
        }
    }

    private func place(_ view: NSView, at frame: NSRect, animated: Bool) {
        let target = frame.offsetBy(dx: 0, dy: 4)
        let id = ObjectIdentifier(view)
        // Repeated SwiftUI refreshes must not snap an in-flight native animation.
        guard layoutTargets[id] != target else { return }
        layoutTargets[id] = target
        if animated { view.animator().frame = target }
        else { view.frame = target }
    }

    private func layoutControls(animated: Bool) {
        let windowWidth = window?.frame.width ?? (bounds.width + 152)
        let origin = convert(.zero, to: nil).x
        let galleryInset: CGFloat = appState.sidebarCollapsed ? 0 : appState.sidebarWidth + 18
        let leading = max(0, galleryInset - origin)
        let selecting = appState.selectedAssetCount > 1
        let hasTransfer = appState.fileTransferProgress != nil
        for (index, button) in [back, forward, up].enumerated() {
            place(button, at: NSRect(x: leading + CGFloat(index) * 32, y: 6, width: LightboxControlMetrics.iconButtonSize, height: LightboxControlMetrics.iconButtonSize), animated: animated)
            button.isHidden = selecting
        }
        // Match the trailing icon center to the 26-point top inset.
        let right = bounds.width - 8 - (hasTransfer ? 44 : 0)
        place(sort, at: NSRect(x: right - 34, y: 6, width: 32, height: 32), animated: animated)
        place(search, at: NSRect(x: right - 70, y: 6, width: 32, height: 32), animated: animated)
        sort.isHidden = selecting || appState.isShowingStartPage
        search.isHidden = selecting || searching || appState.isShowingStartPage
        searchField.isHidden = selecting || !searching
        let center = (windowWidth + galleryInset) / 2 - origin
        let searchWidth = min(200, max(120, right - center - 80))
        place(searchField, at: NSRect(x: right - searchWidth - 40, y: 8, width: searchWidth, height: 28), animated: animated)
        let leftEdge = leading + 108
        let rightEdge = right - (searching ? searchWidth + 52 : 82)
        let halfWidth = max(20, min(center - leftEdge, rightEdge - center))
        let location = NSRect(x: center - halfWidth, y: 0, width: halfWidth * 2, height: 44)
        let titleWidth = min(location.width, ceil((titleButton.title as NSString).size(withAttributes: [
            .font: titleButton.font ?? NSFont.systemFont(ofSize: 14, weight: .semibold)
        ]).width) + 20)
        place(titleButton, at: NSRect(x: center - titleWidth / 2, y: ancestors.pathItems.isEmpty ? 10 : 0, width: titleWidth, height: 23), animated: animated)
        let ancestorWidth = min(location.width, ancestors.pathItems.reduce(CGFloat(0)) { width, item in
            width + (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 20
        })
        place(ancestors, at: NSRect(x: center - ancestorWidth / 2, y: 23, width: ancestorWidth, height: 19), animated: animated)
        place(editor, at: NSRect(x: location.minX, y: 8, width: location.width, height: 28), animated: animated)
        titleButton.isHidden = selecting || editingPath
        ancestors.isHidden = selecting || editingPath || ancestors.pathItems.isEmpty
        editor.isHidden = selecting || !editingPath
        selectionHost.isHidden = !selecting
        place(selectionHost, at: NSRect(x: leading, y: 0, width: max(0, right - leading), height: 44), animated: animated)
        transferHost.isHidden = !hasTransfer
        place(transferHost, at: NSRect(x: bounds.width - 42, y: 4, width: 40, height: 36), animated: animated)
    }

    @objc private func openPathMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        appState.openSidebarFolder(url)
    }
    @objc private func revealCurrentFolder() { appState.revealCurrentFolderInFinder() }
    @objc private func copyPath() { appState.copyCurrentPathToClipboard() }
    @objc private func pinPath() { if appState.canPinCurrentPath { appState.pinCurrentPath() } }
    @objc private func goBack() { appState.goBack() }
    @objc private func goForward() { appState.goForward() }
    @objc private func goUp() { appState.openParentFolder() }
    @objc private func openAncestor() {
        guard let url = ancestors.clickedPathItem?.url else { return }
        appState.openSidebarFolder(url)
    }
    @objc private func beginPathEditing() {
        appState.galleryKeyboardFocusID = nil
        if appState.selectedAssetCount > 1 { appState.clearSelection() }
        editingPath = true
        editor.stringValue = appState.currentFolderURL.path
        editor.textColor = .labelColor
        editor.toolTip = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(editor)
        editor.selectText(nil)
    }
    @objc private func showSearch() {
        appState.galleryKeyboardFocusID = nil
        if appState.selectedAssetCount > 1 { appState.clearSelection() }
        searching = true
        editingPath = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)
    }
    @objc private func showSort() {
        popover?.close()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: appState.localized(.sortBy), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for (index, field) in GallerySortField.allCases.enumerated() {
            let item = NSMenuItem(title: appState.sortFieldTitle(field), action: #selector(selectSortField(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = appState.sortField == field ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let direction = NSMenuItem(title: appState.sortDirectionTitle, action: #selector(toggleSortDirection), keyEquivalent: "")
        direction.target = self
        direction.image = NSImage(systemSymbolName: appState.sortDirection == .ascending ? "arrow.up" : "arrow.down", accessibilityDescription: nil)
        menu.addItem(direction)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sort.bounds.maxY + 4), in: sort)
    }
    @objc private func selectSortField(_ sender: NSMenuItem) {
        guard GallerySortField.allCases.indices.contains(sender.tag) else { return }
        let field = GallerySortField.allCases[sender.tag]
        guard field != appState.sortField else { return }
        appState.setSortField(field)
    }
    @objc private func toggleSortDirection() { appState.toggleSortDirection() }
    private func showPanel(_ kind: NativeHeaderPanel.Kind, from button: NSButton) {
        popover?.close()
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = NSHostingController(rootView: NativeHeaderPanel(appState: appState, kind: kind, close: { [weak panel] in panel?.close() }))
        popover = panel
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === searchField { appState.searchText = searchField.stringValue }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if control === editor { editingPath = false }
            else if control === searchField {
                searching = false
                searchField.stringValue = ""
                appState.searchText = ""
            }
            window?.makeFirstResponder(nil)
            needsLayout = true
            return true
        }
        if control === editor && commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if appState.openFolderPath(editor.stringValue) {
                editingPath = false
                window?.makeFirstResponder(nil)
            } else {
                editor.textColor = .systemRed
                editor.toolTip = appState.localized(.folderUnavailable)
                NSSound.beep()
            }
            needsLayout = true
            return true
        }
        return false
    }
}

/// Keyboard navigation gets a quiet marker; mouse clicks retain the borderless style.
private final class KeyboardAwareHeaderButton: NSButton {
    private var showsKeyboardFocus = false
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = LightboxControlMetrics.cornerRadius
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateFeedback() {
        guard let layer else { return }
        let opacity = !isEnabled || window?.isKeyWindow != true ? 0
            : isHighlighted ? LightboxControlMetrics.pressedOpacity
            : isHovered ? LightboxControlMetrics.hoverOpacity : 0
        let target = NSColor(LightboxColorTokens.primaryText).withAlphaComponent(opacity).cgColor
        guard layer.backgroundColor != target else { return }
        let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "feedback")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = previous ?? NSColor.clear.cgColor
        fade.toValue = target
        fade.duration = MotionTokens.feedbackDurationSeconds
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "feedback")
    }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        showsKeyboardFocus = false
        needsDisplay = true
        return super.resignFirstResponder()
    }
    override func draw(_ dirtyRect: NSRect) {
        updateFeedback()
        super.draw(dirtyRect)
        guard showsKeyboardFocus, window?.firstResponder === self else { return }
        NSColor(LightboxColorTokens.secondaryText).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 5, y: 2))
        line.line(to: NSPoint(x: bounds.width - 5, y: 2))
        line.lineWidth = LightboxControlMetrics.focusLineWidth
        line.stroke()
    }
}
