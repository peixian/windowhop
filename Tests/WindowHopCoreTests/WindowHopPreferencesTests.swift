import XCTest
@testable import WindowHopCore

final class WindowHopPreferencesTests: XCTestCase {
    func testUpgradeKeepsAllDisplaysDefaultWithoutEnablingOptionalInterfaces() throws {
        let saved = try JSONDecoder().decode(WindowHopPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(saved.showsOnAllDisplays)
        XCTAssertFalse(saved.sidebarEnabled)
        XCTAssertFalse(saved.gestureEnabled)
    }

    func testDisplayOptOutAndIndependentFiltersSurviveSaving() throws {
        var saved = WindowHopPreferences()
        saved.showsOnAllDisplays = false
        saved.primaryList.minimized = .bottom
        saved.alternateList.spaceScope = .visible
        saved.alternateList.hidden = .exclude
        saved.sidebarEnabled = true
        saved.sidebarEdge = .left
        saved.sidebarCurrentDisplayOnly = false
        saved.sidebarList.includeApplicationsWithoutWindows = false
        saved.ignoredBundleIdentifiers = ["example.hidden"]
        let decoded = try JSONDecoder().decode(WindowHopPreferences.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
    }

    func testSearchFromCycleKeepsSelectionCodesAndFrozenWindows() {
        let windows = [WindowItem(id: "a", appName: "Editor", title: "One", bundleIdentifier: "editor"),
                       WindowItem(id: "b", appName: "Editor", title: "Two", bundleIdentifier: "editor")]
        var session = SwitcherSession()
        session.begin(mode: .cycle, windows: windows)
        let target = session.selected
        let codes = session.searchShortcuts
        session.enterCycleSearch()
        XCTAssertEqual(session.mode, .fastSearch)
        XCTAssertEqual(session.selected, target)
        XCTAssertEqual(session.searchShortcuts, codes)
        XCTAssertEqual(session.windows, windows)
        session.updateQuery(codes["b"]!)
        XCTAssertEqual(session.selected?.id, "b")
    }
    func testChangingListFiltersDoesNotReassignCodesOrExposeExcludedTargets() {
        let windows = (0..<12).map { WindowItem(id: "\($0)", appName: "Editor", title: "Untitled", bundleIdentifier: "editor") }
        var session = SwitcherSession()
        session.begin(mode: .search, windows: windows, shortcutWindows: windows)
        let original = session.searchShortcuts
        session.end()
        let subset = [windows[10], windows[11]]
        session.begin(mode: .search, windows: subset, shortcutWindows: windows)
        XCTAssertEqual(session.searchShortcuts.count, 2)
        XCTAssertEqual(session.searchShortcuts[windows[10].id], original[windows[10].id])
        session.updateQuery(original[windows[0].id]!)
        XCTAssertFalse(session.results.contains { $0.id == windows[0].id })
        session.end()
        session.begin(mode: .search, windows: Array(windows.reversed()), shortcutWindows: windows)
        XCTAssertEqual(session.searchShortcuts, original)
    }

}
