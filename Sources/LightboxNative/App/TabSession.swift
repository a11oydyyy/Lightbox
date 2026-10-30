import Combine
import Foundation

/// The open tabs: their order, which one is active, each tab's back/forward
/// history, a small cache of recently shown tab contents, and saving them.
/// The sidebar reorders tabs through `reorder(_:before:)`.
///
/// It knows nothing about loading folders. `AppState` puts a tab's state on
/// screen and captures it back; this type only keeps the tabs consistent:
/// pinned tabs stay a leading group, closed tabs drop their cached content,
/// and changes are saved shortly after they happen. `AppState` republishes
/// its changes, so views keep reading tabs through `AppState`.
@MainActor
final class TabSession: ObservableObject {
    /// Cached contents are kept for this many recently shown tabs...
    static let cachedTabLimit = 3
    /// ...and this many images across them.
    static let cachedAssetLimit = 50_000

    @Published private(set) var tabs: [LightboxTab] = []
    @Published private(set) var activeTabID = UUID()
    /// Fills in values `AppState` keeps outside the active tab (its scroll
    /// anchor and sort) before the tabs are saved.
    var activeTabOverlay: (inout LightboxTab) -> Void = { _ in }

    private let defaults: UserDefaults
    private var contentSnapshots: [UUID: TabContentSnapshot] = [:]
    private var contentRecency: [UUID] = []
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    deinit {
        saveTask?.cancel()
    }

    // MARK: Tabs

    var activeTab: LightboxTab? { tabs.first { $0.id == activeTabID } }
    var activeTabIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }
    var canGoBack: Bool { activeTab?.backHistory.isEmpty == false }
    var canGoForward: Bool { activeTab?.forwardHistory.isEmpty == false }

    func tab(_ id: UUID) -> LightboxTab? { tabs.first { $0.id == id } }

    /// Sets the tabs a session starts with.
    func restore(_ tabs: [LightboxTab], activeTabID: UUID) {
        precondition(!tabs.isEmpty, "a session always has a tab")
        self.tabs = tabs
        self.activeTabID = tabs.contains { $0.id == activeTabID } ? activeTabID : tabs[0].id
        forgetContent(except: Set(tabs.map(\.id)))
    }

    /// Replaces every tab without changing which one is active, as when the
    /// last tab closes: `AppState` then activates one of the new tabs.
    func replaceAll(with tabs: [LightboxTab]) {
        precondition(!tabs.isEmpty, "a session always has a tab")
        self.tabs = tabs
        forgetContent(except: Set(tabs.map(\.id)))
    }

    func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Inserts `tab` after `index` (the end when nil).
    func insert(_ tab: LightboxTab, after index: Int?) {
        let position = (index ?? tabs.count - 1) + 1
        tabs.insert(tab, at: min(max(position, 0), tabs.count))
    }

    func update(_ id: UUID, _ body: (inout LightboxTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        body(&tab)
        guard tab != tabs[index] else { return }
        tabs[index] = tab
    }

    func updateActive(_ body: (inout LightboxTab) -> Void) {
        update(activeTabID, body)
    }

    func updateAll(_ body: (inout LightboxTab) -> Void) {
        let updated = tabs.map { tab -> LightboxTab in
            var tab = tab
            body(&tab)
            return tab
        }
        guard updated != tabs else { return }
        tabs = updated
    }

    /// Removes tabs and their cached contents. When the active tab goes,
    /// `AppState` activates another one right after.
    func remove(_ ids: Set<UUID>) {
        tabs.removeAll { ids.contains($0.id) }
        forgetContent(except: Set(tabs.map(\.id)))
    }

    /// Moves `ids` before `target` (to the end when nil). Returns whether
    /// the order changed.
    @discardableResult
    func reorder(_ ids: [UUID], before target: UUID?) -> Bool {
        let next = SidebarOrder.moving(ids, before: target, in: tabs)
        guard next.map(\.id) != tabs.map(\.id) else { return false }
        tabs = next
        return true
    }

    // MARK: History

    /// Records leaving `location` for somewhere new: it becomes the last
    /// place to go back to, and there is nothing to go forward to.
    func recordVisit(leaving location: LightboxTabLocation) {
        updateActive {
            $0.backHistory.append(location)
            $0.forwardHistory = []
        }
    }

    /// The place to go back to, remembering `current` for going forward.
    func stepBack(from current: LightboxTabLocation?) -> LightboxTabLocation? {
        step(from: current, take: \.backHistory, keep: \.forwardHistory)
    }

    /// The place to go forward to, remembering `current` for going back.
    func stepForward(from current: LightboxTabLocation?) -> LightboxTabLocation? {
        step(from: current, take: \.forwardHistory, keep: \.backHistory)
    }

    private func step(
        from current: LightboxTabLocation?,
        take source: WritableKeyPath<LightboxTab, [LightboxTabLocation]>,
        keep destination: WritableKeyPath<LightboxTab, [LightboxTabLocation]>
    ) -> LightboxTabLocation? {
        guard activeTab?[keyPath: source].isEmpty == false else { return nil }
        var target: LightboxTabLocation?
        updateActive { tab in
            target = tab[keyPath: source].popLast()
            if let current { tab[keyPath: destination].append(current) }
        }
        return target
    }

    // MARK: Cached contents

    /// Keeps `snapshot` as `id`'s contents, dropping the least recently shown
    /// beyond `cachedTabLimit` tabs or `cachedAssetLimit` images.
    func cacheContent(_ snapshot: TabContentSnapshot, for id: UUID) {
        guard snapshot.assetCount <= Self.cachedAssetLimit else { return }
        contentSnapshots[id] = snapshot
        contentRecency.removeAll { $0 == id }
        contentRecency.append(id)
        while contentRecency.count > Self.cachedTabLimit
                || contentSnapshots.values.reduce(0, { $0 + $1.assetCount }) > Self.cachedAssetLimit {
            contentSnapshots.removeValue(forKey: contentRecency.removeFirst())
        }
    }

    /// Drops the cached contents of `ids`, as when their files moved.
    func forgetContent(of ids: Set<UUID>) {
        forgetContent(except: Set(tabs.map(\.id)).subtracting(ids))
    }

    func cachedContent(for id: UUID) -> TabContentSnapshot? {
        contentSnapshots[id]
    }

    private func forgetContent(except openIDs: Set<UUID>) {
        contentSnapshots = contentSnapshots.filter { openIDs.contains($0.key) }
        contentRecency.removeAll { !openIDs.contains($0) }
    }

    // MARK: Saving

    /// Saves shortly, folding bursts of changes (scrolling, typing) into one write.
    func scheduleSave() {
        guard !tabs.isEmpty else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard !tabs.isEmpty else { return }
        saveTask?.cancel()
        saveTask = nil
        var snapshot = tabs
        if let index = activeTabIndex { activeTabOverlay(&snapshot[index]) }
        LightboxTabStore.save(tabs: snapshot, activeTabID: activeTabID, defaults: defaults)
    }
}
