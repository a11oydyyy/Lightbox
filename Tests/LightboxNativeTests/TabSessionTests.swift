import Foundation
import Testing
@testable import LightboxNative

@MainActor
private func makeSession(_ names: [String], pinned: Int = 0) throws -> (TabSession, [LightboxTab], UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "LightboxTabSession-\(UUID())"))
    let source = LibrarySource.favorites(rootURL: URL(fileURLWithPath: "/tmp/tabs"))
    let tabs = names.enumerated().map { index, name in
        LightboxTab(source: source, folderURL: URL(fileURLWithPath: "/tmp/tabs/\(name)"), isPinned: index < pinned)
    }
    let session = TabSession(defaults: defaults)
    session.restore(tabs, activeTabID: tabs[0].id)
    return (session, tabs, defaults)
}

@MainActor
private func names(_ session: TabSession) -> [String] {
    session.tabs.map(\.folderURL.lastPathComponent)
}

@Test @MainActor func tabSessionKeepsPinnedTabsAsALeadingGroup() throws {
    let (session, tabs, _) = try makeSession(["p1", "p2", "a", "b"], pinned: 2)
    let source = tabs[0].source
    session.insert(LightboxTab(source: source, folderURL: URL(fileURLWithPath: "/tmp/tabs/new")), after: 0)
    #expect(names(session) == ["p1", "p2", "new", "a", "b"])
    session.togglePinned(tabs[3].id)   // pin "b"
    #expect(names(session) == ["p1", "p2", "b", "new", "a"])
    session.togglePinned(tabs[0].id)   // unpin "p1"
    #expect(names(session) == ["p2", "b", "p1", "new", "a"])
}

@Test @MainActor func tabSessionStepsThroughHistory() throws {
    let (session, tabs, _) = try makeSession(["a"])
    func location(_ name: String) -> LightboxTabLocation {
        LightboxTabLocation(source: tabs[0].source, folderURL: URL(fileURLWithPath: "/tmp/\(name)"),
                            filter: .all, isStartPage: false)
    }
    session.recordVisit(leaving: location("one"))
    session.recordVisit(leaving: location("two"))
    #expect(session.canGoBack && !session.canGoForward)
    #expect(session.stepBack(from: location("three")) == location("two"))
    #expect(session.canGoForward)
    #expect(session.stepForward(from: location("two")) == location("three"))
    session.recordVisit(leaving: location("three"))
    #expect(!session.canGoForward)
    #expect(session.activeTab?.backHistory.map(\.folderURL.lastPathComponent) == ["one", "two", "three"])
}

@Test @MainActor func tabSessionBoundsCachedContentsAndForgetsClosedTabs() throws {
    let (session, tabs, _) = try makeSession(["a", "b", "c", "d"])
    func snapshot(_ tab: LightboxTab, assets: Int) -> TabContentSnapshot {
        TabContentSnapshot(tab: tab, showsHiddenItems: false,
            assets: (0..<assets).map { LightboxAsset(id: "\(tab.id)-\($0)", originalName: "\($0).jpg", width: 1, height: 1,
                                                    tags: [], addedAt: .distantPast, palette: MockPalette.imported[0]) },
            folders: [], searchAssets: nil, searchFolders: nil, searchStatus: nil, activeAssets: [],
            activeIDs: [], activeIDList: [], groups: [], activeFolders: [], colorTags: [])
    }
    for tab in tabs { session.cacheContent(snapshot(tab, assets: 1), for: tab.id) }
    // Only the three most recently shown tabs stay cached.
    #expect(session.cachedContent(for: tabs[0].id) == nil)
    #expect(tabs.dropFirst().allSatisfy { session.cachedContent(for: $0.id) != nil })
    // A library over the limit is not cached at all.
    session.cacheContent(snapshot(tabs[0], assets: TabSession.cachedAssetLimit + 1), for: tabs[0].id)
    #expect(session.cachedContent(for: tabs[0].id) == nil)
    // Closing a tab drops its contents.
    session.remove([tabs[3].id])
    #expect(session.cachedContent(for: tabs[3].id) == nil)
    #expect(names(session) == ["a", "b", "c"])
}

// Replacing every tab keeps the active ID, so activating a new tab afterwards
// still switches to it.
@Test @MainActor func tabSessionReplaceAllKeepsTheActiveTabUntilActivated() throws {
    let (session, tabs, _) = try makeSession(["a", "b"])
    let reset = LightboxTab(source: tabs[0].source, folderURL: URL(fileURLWithPath: "/tmp/tabs/reset"), isStartPage: true)
    session.replaceAll(with: [reset])
    #expect(session.activeTabID == tabs[0].id)
    #expect(session.activeTab == nil)
    session.activate(reset.id)
    #expect(session.activeTab?.id == reset.id)
}

// Saving applies what the app keeps outside the active tab.
@Test @MainActor func tabSessionSavesTheActiveTabsLiveValues() throws {
    let (session, tabs, defaults) = try makeSession(["a", "b"])
    session.activeTabOverlay = { $0.scrollAnchorAssetID = "anchor"; $0.sortField = .size }
    session.saveNow()
    let saved = try #require(LightboxTabStore.load(sources: [], defaults: defaults))
    #expect(saved.activeTabID == tabs[0].id)
    #expect(saved.tabs[0].scrollAnchorAssetID == "anchor")
    #expect(saved.tabs[0].sortField == .size)
    #expect(saved.tabs[1].sortField == tabs[1].sortField)
}
