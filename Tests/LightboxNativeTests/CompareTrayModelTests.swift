import Combine
import Foundation
import Testing
@testable import LightboxNative

private func trayAsset(_ index: Int, folder: String = "/tmp/tray") -> LightboxAsset {
    LightboxAsset(originalName: "\(index).jpg", width: 400, height: 300, tags: [],
                  sourceURL: URL(fileURLWithPath: "\(folder)/\(index).jpg"), addedAt: .distantPast,
                  palette: MockPalette.imported[0], metadataLoaded: true)
}

@Test @MainActor func compareTrayPulsesDuplicatesAndRefusesWhenFull() {
    let tray = CompareTrayModel()
    tray.add(trayAsset(0))
    #expect(tray.pulseID == trayAsset(0).id)
    tray.add(trayAsset(0))
    #expect(tray.items.count == 1)
    for index in 1..<CompareTrayModel.limit { tray.add(trayAsset(index)) }
    #expect(tray.items.count == CompareTrayModel.limit)
    #expect(tray.rejectGeneration == 0)
    tray.add(trayAsset(99))
    #expect(tray.items.count == CompareTrayModel.limit)
    #expect(tray.rejectGeneration == 1)
}

// Dragging onto an item takes its place, in either direction.
@Test @MainActor func compareTrayReordersByDragAndRenumbers() {
    func tray(dragging from: Int, onto to: Int) -> [String] {
        let tray = CompareTrayModel()
        for index in 0..<4 { tray.add(trayAsset(index)) }
        tray.beginDrag(trayAsset(from).id)
        tray.moveDraggedItem(onto: trayAsset(to).id)
        tray.endDrag()
        #expect(tray.dragID == nil)
        #expect(tray.label(for: trayAsset(from).id) == "\(to + 1)")
        return tray.items.map(\.originalName)
    }
    #expect(tray(dragging: 0, onto: 1) == ["1.jpg", "0.jpg", "2.jpg", "3.jpg"])   // right-hand neighbour
    #expect(tray(dragging: 0, onto: 3) == ["1.jpg", "2.jpg", "3.jpg", "0.jpg"])   // to the end
    #expect(tray(dragging: 3, onto: 0) == ["3.jpg", "0.jpg", "1.jpg", "2.jpg"])   // to the front
    #expect(tray(dragging: 2, onto: 1) == ["0.jpg", "2.jpg", "1.jpg", "3.jpg"])   // left-hand neighbour
    #expect(CompareTrayModel().label(for: trayAsset(99).id) == nil)
}

// Two items swap whichever one is dragged.
@Test @MainActor func compareTraySwapsTwoItems() {
    for (from, to) in [(0, 1), (1, 0)] {
        let tray = CompareTrayModel()
        tray.add(trayAsset(0))
        tray.add(trayAsset(1))
        tray.beginDrag(trayAsset(from).id)
        tray.moveDraggedItem(onto: trayAsset(to).id)
        #expect(tray.items.map(\.originalName) == ["1.jpg", "0.jpg"])
    }
}

@Test @MainActor func compareTrayFollowsMovedFiles() {
    let tray = CompareTrayModel()
    tray.add(trayAsset(0))
    tray.add(trayAsset(1))
    let moved = FileTransferSuccess(sourceURL: URL(fileURLWithPath: "/tmp/tray/1.jpg"),
                                    destinationURL: URL(fileURLWithPath: "/tmp/elsewhere/1 copy.jpg"))
    tray.relocate([moved])
    #expect(tray.items[0].sourceURL?.path == "/tmp/tray/0.jpg")
    #expect(tray.items[1].sourceURL?.path == "/tmp/elsewhere/1 copy.jpg")
    #expect(tray.items[1].originalName == "1 copy.jpg")
}

// Views read the tray through `AppState`, so tray changes republish it; and
// removing images from an open comparison closes it below two.
@Test @MainActor func compareTrayChangesRepublishTheAppStateAndUpdateTheComparison() throws {
    let suite = "LightboxTray-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxTray-\(UUID())")
    defer { try? FileManager.default.removeItem(at: work) }
    let state = AppState(indexDatabaseURL: work.appendingPathComponent("index.sqlite"), libraryDefaults: defaults)
    var changes = 0
    let observer = state.objectWillChange.sink { changes += 1 }
    defer { observer.cancel() }

    state.addToCompareTray(trayAsset(0))
    #expect(changes > 0)
    #expect(state.compareTrayAssets.count == 1)
    state.startCompareTrayComparison()
    #expect(!state.isComparing)
    #expect(state.compareTrayRejectGeneration == 1)

    state.addToCompareTray(trayAsset(1))
    state.addToCompareTray(trayAsset(2))
    state.startCompareTrayComparison()
    #expect(state.isComparing)
    #expect(state.selectedAssetID == trayAsset(0).id)
    state.removeFromCompareTray(trayAsset(0).id)
    #expect(state.isComparing)
    state.removeFromCompareTray(trayAsset(1).id)
    #expect(!state.isComparing)
    #expect(state.compareTrayAssets.map(\.id) == [trayAsset(2).id])
}
