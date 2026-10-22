import CoreGraphics
import Testing
@testable import LightboxNative

// Sidebar rows take the place of the row they are dragged onto, both ways.
@Test func sidebarReorderTakesTheTargetsPlace() {
    struct Row: Identifiable, Equatable { let id: String }
    let rows = ["a", "b", "c", "d"].map(Row.init)
    func drag(_ dragged: String, onto target: String) -> [String] {
        let point = SidebarOrder.insertionPoint(dragging: dragged, onto: target, in: rows.map(\.id))
        guard point.moves else { return rows.map(\.id) }
        return SidebarOrder.moving([dragged], before: point.before, in: rows).map(\.id)
    }
    #expect(drag("a", onto: "b") == ["b", "a", "c", "d"])   // right-hand neighbour
    #expect(drag("a", onto: "d") == ["b", "c", "d", "a"])   // to the end
    #expect(drag("d", onto: "a") == ["d", "a", "b", "c"])   // to the front
    #expect(drag("c", onto: "b") == ["a", "c", "b", "d"])   // left-hand neighbour
    #expect(drag("b", onto: "b") == ["a", "b", "c", "d"])   // onto itself
}

// A sidebar drag is over the row its pointer has moved to, clamped to the ends.
@Test func sidebarDragTargetFollowsThePointer() {
    #expect(SidebarOrder.dragTarget(startIndex: 1, translation: 0, pitch: 40, count: 4) == 1)
    #expect(SidebarOrder.dragTarget(startIndex: 1, translation: 25, pitch: 40, count: 4) == 2)
    #expect(SidebarOrder.dragTarget(startIndex: 1, translation: 15, pitch: 40, count: 4) == 1)
    #expect(SidebarOrder.dragTarget(startIndex: 1, translation: 500, pitch: 40, count: 4) == 3)
    #expect(SidebarOrder.dragTarget(startIndex: 1, translation: -500, pitch: 40, count: 4) == 0)
}
