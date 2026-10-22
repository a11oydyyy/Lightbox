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
    /// The row a drag that started at `startIndex` is over after moving
    /// `translation` points, with rows `pitch` points apart.
    static func dragTarget(startIndex: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0 else { return startIndex }
        let steps = Int((translation / pitch).rounded())
        return min(max(startIndex + steps, 0), count - 1)
    }

    /// Where to insert `dragged` so it takes `target`'s place: after it when
    /// moving down, before it when moving up. Nil means the end.
    static func insertionPoint<ID: Equatable>(dragging dragged: ID, onto target: ID, in ids: [ID]) -> (before: ID?, moves: Bool) {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target)
        else { return (nil, false) }
        return (from < to ? (to + 1 < ids.count ? ids[to + 1] : nil) : target, true)
    }

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

/// Rows that can be dragged into a new order within their section.
///
/// The drag is handled inside the section rather than through the system's
/// drag and drop: rows are buttons, which on macOS keep a drag source from
/// ever starting, and the system reorder container (`reorderable()` /
/// `reorderContainer`) crashed when a row was lifted on macOS 27, in 2.0.11
/// as well. Moving the pointer 6pt takes over from the button; a plain click
/// still reaches it. The dragged row follows the pointer and takes the place
/// of each row it passes.
struct ReorderableSidebarItems<Item: Identifiable, Row: View>: View where Item.ID: Sendable {
    var items: [Item]
    var move: ([Item.ID], Item.ID?) -> Void
    @ViewBuilder var row: (Item) -> Row
    @State private var drag: SidebarRowDrag<Item.ID>?
    @State private var rowHeight: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var spacing: CGFloat { 4 }
    private static var coordinateSpace: String { "SidebarReorder" }
    private var pitch: CGFloat { rowHeight + Self.spacing }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(items) { item in
                let isDragged = drag?.id == item.id
                row(item)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onAppear { rowHeight = proxy.size.height }
                        }
                    }
                    .offset(y: isDragged ? draggedRowOffset : 0)
                    // The dragged row tracks the pointer exactly; only the rows
                    // making room for it animate.
                    .transaction { if isDragged { $0.animation = nil } }
                    .zIndex(isDragged ? 1 : 0)
                    .shadow(color: .black.opacity(isDragged ? 0.12 : 0), radius: 6, y: 2)
                    .highPriorityGesture(
                        // Measured in the section, not the row: the row moves
                        // while dragged, which made a row-relative translation jump.
                        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.coordinateSpace))
                            .onChanged { value in dragChanged(item.id, translation: value.translation.height) }
                            .onEnded { _ in
                                withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
                                    drag = nil
                                }
                            }
                    )
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
    }

    /// Keeps the dragged row under the pointer after the rows have reordered.
    private var draggedRowOffset: CGFloat {
        guard let drag, let index = items.firstIndex(where: { $0.id == drag.id }) else { return 0 }
        return drag.translation - CGFloat(index - drag.startIndex) * pitch
    }

    private func dragChanged(_ id: Item.ID, translation: CGFloat) {
        let ids = items.map(\.id)
        if drag?.id != id {
            guard let start = ids.firstIndex(of: id) else { return }
            drag = SidebarRowDrag(id: id, startIndex: start, translation: 0)
        }
        guard var current = drag else { return }
        current.translation = translation
        drag = current
        let target = SidebarOrder.dragTarget(startIndex: current.startIndex, translation: translation, pitch: pitch, count: ids.count)
        let point = SidebarOrder.insertionPoint(dragging: id, onto: ids[target], in: ids)
        guard point.moves else { return }
        withAnimation(MotionTokens.ifAllowed(MotionTokens.standard, reduceMotion: reduceMotion)) {
            move([id], point.before)
        }
    }
}

private struct SidebarRowDrag<ID: Hashable> {
    var id: ID
    var startIndex: Int
    var translation: CGFloat
}
