import Foundation
import Testing
@testable import LightboxNative

private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09, a Thursday
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private func file(
    _ name: String, width: CGFloat = 4000, height: CGFloat = 3000, loaded: Bool = true,
    addedDaysAgo: Double? = 0, bytes: Int64? = 5_000_000, tags: [String] = []
) -> LightboxAsset {
    LightboxAsset(originalName: name, width: width, height: height, tags: tags,
        sourceURL: URL(fileURLWithPath: "/shoot/\(name)"),
        addedAt: addedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) } ?? .distantPast,
        fileSize: bytes, palette: MockPalette.imported[0], metadataLoaded: loaded)
}

private func matching(_ filter: GalleryAttributeFilter, _ assets: [LightboxAsset]) -> [String] {
    assets.filter(filter.matcher(now: now, calendar: calendar)).map(\.originalName)
}

@Test func attributeFilterKindSplitsPhotosRawVideosAndDocuments() {
    let assets = [file("a.JPG"), file("b.cr3"), file("c.dng"), file("d.mov"), file("e.pdf"), file("f.heic")]
    var filter = GalleryAttributeFilter()
    #expect(matching(filter, assets).count == 6 && !filter.isActive && filter.activeCount == 0)
    filter.kind = .photos
    #expect(matching(filter, assets) == ["a.JPG", "f.heic"])
    filter.kind = .raw
    #expect(matching(filter, assets) == ["b.cr3", "c.dng"])
    filter.kind = .videos
    #expect(matching(filter, assets) == ["d.mov"])
    filter.kind = .documents
    #expect(matching(filter, assets) == ["e.pdf"])
    #expect(filter.isActive && filter.activeCount == 1 && !filter.needsDimensions)
}

@Test func attributeFilterOrientationAndLongEdgeNeedKnownSizes() {
    let assets = [
        file("wide.jpg", width: 6000, height: 4000), file("tall.jpg", width: 2000, height: 3000),
        file("square.jpg", width: 1000, height: 1005), file("waiting.jpg", loaded: false),
        file("notes.pdf")
    ]
    var filter = GalleryAttributeFilter(orientation: .landscape)
    #expect(filter.needsDimensions)
    #expect(matching(filter, assets) == ["wide.jpg"])
    filter.orientation = .portrait
    #expect(matching(filter, assets) == ["tall.jpg"])
    filter.orientation = .square
    #expect(matching(filter, assets) == ["square.jpg"])
    filter = GalleryAttributeFilter(pixelSize: .atLeast4000)
    #expect(matching(filter, assets) == ["wide.jpg"])
    filter.pixelSize = .atLeast2000
    #expect(matching(filter, assets) == ["wide.jpg", "tall.jpg"])
    filter.pixelSize = .under2000
    #expect(matching(filter, assets) == ["square.jpg"])
    filter.pixelSize = .atLeast6000
    #expect(matching(filter, assets) == ["wide.jpg"])
}

@Test func attributeFilterDateAddedAndFileSizeUseCalendarRangesAndDecimalUnits() {
    let assets = [
        file("today.jpg", addedDaysAgo: 0, bytes: 800_000),
        file("monday.jpg", addedDaysAgo: 3, bytes: 1_000_000),   // Monday of this week
        file("lastweek.jpg", addedDaysAgo: 5, bytes: 12_000_000),
        file("lastyear.jpg", addedDaysAgo: 400, bytes: 60_000_000),
        file("unknown.jpg", addedDaysAgo: nil, bytes: nil)
    ]
    var filter = GalleryAttributeFilter(addedDate: .today)
    #expect(matching(filter, assets) == ["today.jpg"])
    filter.addedDate = .thisWeek
    #expect(matching(filter, assets) == ["today.jpg", "monday.jpg"])
    filter.addedDate = .thisMonth
    #expect(matching(filter, assets) == ["today.jpg", "monday.jpg", "lastweek.jpg"])
    filter.addedDate = .thisYear
    #expect(matching(filter, assets) == ["today.jpg", "monday.jpg", "lastweek.jpg"])
    filter = GalleryAttributeFilter(fileSize: .under1MB)
    #expect(matching(filter, assets) == ["today.jpg"])
    filter.fileSize = .from1To10MB
    #expect(matching(filter, assets) == ["monday.jpg"])
    filter.fileSize = .from10To50MB
    #expect(matching(filter, assets) == ["lastweek.jpg"])
    filter.fileSize = .over50MB
    #expect(matching(filter, assets) == ["lastyear.jpg"])
}

@Test func attributeFiltersCombineWithTagsAndSearchButNotTheTrash() {
    var trashed = file("old.cr3")
    trashed.deletedAt = now
    let source = [file("a.cr3", tags: ["Red"]), file("b.cr3"), file("c.jpg", tags: ["Red"]), file("raw-note.pdf"), trashed]
    let rawOnly = GalleryAttributeFilter(kind: .raw)
    func names(_ filter: LibraryFilter, _ text: String = "") -> [String] {
        GalleryContentFilter.visibleAssets(from: source, filter: filter, attributes: rawOnly,
            query: LightboxSearchQuery.parse(text), field: .fileName, direction: .ascending, reusing: nil)
            .assets.map(\.originalName)
    }
    #expect(names(.all) == ["a.cr3", "b.cr3"])
    #expect(names(.tag("Red")) == ["a.cr3"])
    #expect(names(.all, "b") == ["b.cr3"])
    #expect(names(.trash) == ["old.cr3"])
    let result = GalleryContentFilter.visibleAssets(from: source, filter: .all, attributes: rawOnly,
        query: LightboxSearchQuery.parse(""), field: .fileName, direction: .ascending, reusing: nil)
    #expect(result.sorted == nil)   // a filtered result is not kept as the sorted source
}

@Test @MainActor func attributeFilterIsPerTabAndClearsOnOpeningAnotherFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightboxAttributeFilter-\(UUID())")
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.jpg", "b.cr3"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
    let suite = "LightboxAttributeFilter-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AppState(indexDatabaseURL: root.appendingPathComponent("index.sqlite"), libraryDefaults: defaults,
                         previewDimensionProbe: { _ in CGSize(width: 40, height: 60) },
                         searchDimensionProbe: { _ in CGSize(width: 40, height: 60) })
    let source = LibrarySource.favorites(rootURL: root)
    state.sources = [source]
    state.chooseSource(source.id)
    await waitWhile { state.libraryLoadingStatus != nil || state.activeAssets.count != 2 }
    state.attributeFilter.kind = .raw
    #expect(state.activeAssets.map(\.originalName) == ["b.cr3"])
    #expect(state.tabs.first { $0.id == state.activeTabID }?.attributeFilter.kind == .raw)
    // Another tab starts unfiltered; coming back restores the filter.
    let firstTab = state.activeTabID
    state.newTab()
    #expect(state.attributeFilter == GalleryAttributeFilter())
    state.selectTab(firstTab)
    #expect(state.attributeFilter.kind == .raw)
    await waitWhile { state.libraryLoadingStatus != nil || state.activeAssets.count != 1 }
    #expect(state.activeAssets.map(\.originalName) == ["b.cr3"])
    // Opening a folder clears it, like the name search.
    let folder = try #require(state.folderEntries.first { $0.name == "child" })
    state.openFolder(folder)
    #expect(state.attributeFilter == GalleryAttributeFilter())
}

// Name search ignores case and accents, for plain ASCII names (the fast path)
// and for names that need folding.
@Test func nameSearchIgnoresCaseAndAccents() {
    func matches(_ query: String, _ name: String) -> Bool {
        LightboxSearchQuery.parse(query).mayMatchAssetName(name)
    }
    #expect(matches("img_00", "IMG_00042.JPG"))
    #expect(matches("IMG 42", "img_0042.jpg"))
    #expect(!matches("img_01", "IMG_00042.JPG"))
    #expect(matches("cafe", "Café Résumé.heic"))
    #expect(matches("CAFÉ", "cafe.jpg"))
    #expect(matches("香港", "2024 香港 夜景.jpg"))
    #expect(!matches("東京", "2024 香港 夜景.jpg"))
}

@Test func cameraRawFilterMatchesImagesBySettings() {
    var edited = LightboxAsset(originalName: "a.jpg", width: 10, height: 10, tags: [], addedAt: .distantPast, palette: MockPalette.imported[0])
    edited.hasCameraRawSettings = true
    var plain = LightboxAsset(originalName: "b.CR3", width: 10, height: 10, tags: [], addedAt: .distantPast, palette: MockPalette.imported[0])
    plain.hasCameraRawSettings = false
    // Not checked yet: matches neither part until the metadata pass has read it.
    let unchecked = LightboxAsset(originalName: "u.jpg", width: 10, height: 10, tags: [], addedAt: .distantPast, palette: MockPalette.imported[0])
    let document = LightboxAsset(originalName: "c.pdf", width: 1, height: 1, tags: [],
                                 sourceURL: URL(fileURLWithPath: "/tmp/c.pdf"), addedAt: .distantPast, palette: MockPalette.imported[0])
    var filter = GalleryAttributeFilter()
    filter.cameraRaw = .edited
    #expect(filter.activeCount == 1 && filter.needsMetadataPass)
    #expect([edited, plain, unchecked, document].filter(filter.matcher()).map(\.originalName) == ["a.jpg"])
    filter.cameraRaw = .unedited
    #expect([edited, plain, unchecked, document].filter(filter.matcher()).map(\.originalName) == ["b.CR3"])
}

@Test func savedFiltersFromBeforeCameraRawStillDecode() throws {
    let saved = Data(#"{"kind":"raw","orientation":"any","pixelSize":"any","addedDate":"any","fileSize":"any"}"#.utf8)
    let filter = try JSONDecoder().decode(GalleryAttributeFilter.self, from: saved)
    #expect(filter.kind == .raw && filter.cameraRaw == .any)
    let roundTrip = try JSONDecoder().decode(GalleryAttributeFilter.self, from: JSONEncoder().encode(filter))
    #expect(roundTrip == filter)
}

// The bottom bar's filter droplet names a single filter by its choice, and counts more.
@Test func attributeFilterChipNamesOneFilterAndCountsMore() {
    let text = FilterText(.traditionalChinese)
    #expect(text.chip(GalleryAttributeFilter(kind: .raw)) == "RAW")
    #expect(text.chip(GalleryAttributeFilter(pixelSize: .atLeast4000)) == "長邊 ≥ 4000")
    #expect(text.chip(GalleryAttributeFilter(addedDate: .today)) == "今天加入")
    #expect(text.chip(GalleryAttributeFilter(cameraRaw: .edited)) == "Camera Raw 已調整")
    #expect(text.chip(GalleryAttributeFilter(kind: .raw, cameraRaw: .edited)) == "已篩選 2 項")
    #expect(FilterText(.english).chip(GalleryAttributeFilter(addedDate: .thisWeek)) == "Added This Week")
}
