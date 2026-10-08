import SwiftUI

enum SidebarRevealStep: Equatable {
    case waitingForChildren
    case missing
    case scrollTo(SidebarTreeRowID)
}

/// Sidebar-only presentation state does not publish changes through the gallery's AppState.
@MainActor
final class SidebarNavigationState: ObservableObject {
    @Published var expandedPaths: Set<String> = []
    @Published var pendingReveal: SidebarTreeRowID?
    var availableRows: Set<SidebarTreeRowID> = []
    @Published private(set) var childrenRevision = 0
    private var loadedChildren: [SidebarTreeRowID: Set<SidebarTreeRowID>] = [:]
    @Published var recentlyUnpinnedSources: [LibrarySource] = []
    @Published private(set) var pinnedOrder: [String]
    private let defaults: UserDefaults
    private static let orderKey = "Lightbox.sidebarPinnedOrder"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
    }

    func registerChildren(_ children: Set<SidebarTreeRowID>, of parent: SidebarTreeRowID) {
        guard loadedChildren[parent] != children else { return }
        loadedChildren[parent] = children
        childrenRevision += 1
    }

    func forgetChildren(of parent: SidebarTreeRowID) {
        guard loadedChildren.removeValue(forKey: parent) != nil else { return }
        childrenRevision += 1
    }

    func resetReveal() {
        pendingReveal = nil
        loadedChildren.removeAll()
    }

    /// Reveal one loaded ancestor at a time. Its lazy row then loads the next
    /// directory, without guessing an asynchronous directory-read delay.
    func revealStep(for target: SidebarTreeRowID, available: Set<SidebarTreeRowID>) -> SidebarRevealStep {
        // These identities are already canonical. No filesystem path resolution
        // belongs in a repeated UI preference callback.
        let rootParts = (target.root as NSString).pathComponents
        let destinationParts = (target.path as NSString).pathComponents
        guard destinationParts.starts(with: rootParts) else { return .missing }
        var parent = SidebarTreeRowID(root: target.root, path: target.root)
        if parent == target || !available.contains(parent) { return .scrollTo(parent) }
        var parts = rootParts
        for component in destinationParts.dropFirst(rootParts.count) {
            parts.append(component)
            let child = SidebarTreeRowID(root: target.root, path: NSString.path(withComponents: parts))
            guard let siblings = loadedChildren[parent] else { return .waitingForChildren }
            guard siblings.contains(child) else { return .missing }
            if child == target || !available.contains(child) { return .scrollTo(child) }
            parent = child
        }
        return .missing
    }

    func ordered(_ sources: [LibrarySource]) -> [LibrarySource] {
        let ranks = Dictionary(pinnedOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sources.sorted {
            let lhs = ranks[$0.id] ?? Int.max, rhs = ranks[$1.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func reorder(_ ids: [String], before target: String?, sources: [LibrarySource]) {
        pinnedOrder = SidebarOrder.moving(ids, before: target, in: ordered(sources)).map(\.id)
        defaults.set(pinnedOrder, forKey: Self.orderKey)
    }
}

enum SidebarOrder {
    /// Ignore stale drag identities; keep the model's relative order for multi-item moves.
    static func moving<Item: Identifiable>(_ ids: [Item.ID], before target: Item.ID?, in items: [Item]) -> [Item] {
        let selected = Set(ids)
        guard !selected.isEmpty, !selected.contains(where: { $0 == target }) else { return items }
        if let target, !items.contains(where: { $0.id == target }) { return items }
        let moving = items.filter { selected.contains($0.id) }
        guard !moving.isEmpty else { return items }
        var remaining = items.filter { !selected.contains($0.id) }
        let index = target.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.endIndex
        remaining.insert(contentsOf: moving, at: index)
        return remaining
    }
}

struct ReorderableSidebarItems<Item: Identifiable, Row: View>: View where Item.ID: Sendable {
    var items: [Item]
    var move: ([Item.ID], Item.ID?) -> Void
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        if #available(macOS 27, *) {
            VStack(spacing: 4) {
                ForEach(items, content: row).reorderable()
            }
            .reorderContainer(for: Item.self) { difference in
                switch difference.destination.position {
                case .before(let id): move(difference.sources, id)
                case .end: move(difference.sources, nil)
                }
            }
        } else {
            ForEach(items, content: row)
        }
    }
}
