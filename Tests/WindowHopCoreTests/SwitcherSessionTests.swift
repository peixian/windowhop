import XCTest
@testable import WindowHopCore

final class SwitcherSessionTests: XCTestCase {
    private let windows = (0..<3).map {
        WindowItem(id: "\($0)", appName: "Editor", title: "Document \($0)", bundleIdentifier: "test.editor")
    }

    func testCycleStartsAtPreviousWindowAndWrapsInBothDirections() {
        var session = SwitcherSession()
        session.begin(mode: .cycle, windows: windows)
        XCTAssertEqual(session.selected?.id, "1")
        session.move(2)
        XCTAssertEqual(session.selected?.id, "0")
        session.move(-1)
        XCTAssertEqual(session.selected?.id, "2")
        session.move(Int.min)
        XCTAssertEqual(session.selected?.id, "0")
        session.begin(mode: .cycle, windows: windows, reverse: true)
        XCTAssertEqual(session.selected?.id, "2")
    }

    func testSearchModesStartAtFirstWindowAndQueryResetsSelection() {
        for mode in [SwitcherSession.Mode.search, .fastSearch] {
            var session = SwitcherSession()
            session.begin(mode: mode, windows: windows)
            XCTAssertEqual(session.selected?.id, "0")
            session.move(1)
            session.updateQuery("document")
            XCTAssertEqual(session.selected?.id, "0")
            session.updateQuery("2")
            XCTAssertEqual(session.selected?.id, "2")
            session.updateQuery("not present")
            XCTAssertNil(session.selected)
            session.move(-1)
            XCTAssertEqual(session.selectedIndex, 0)
            session.updateQuery("")
            XCTAssertEqual(session.results, windows)
        }
    }

    func testSessionOwnsAFrozenSnapshotUntilNextInvocation() {
        var updatedMRU = windows
        var session = SwitcherSession()
        session.begin(mode: .cycle, windows: updatedMRU)
        updatedMRU.reverse()
        updatedMRU.append(WindowItem(id: "new", appName: "Mail", title: "Inbox", bundleIdentifier: "test.mail"))
        session.updateQuery("document")
        XCTAssertEqual(session.windows, windows)
        XCTAssertEqual(session.results, windows)
        session.end()
        session.begin(mode: .search, windows: updatedMRU)
        XCTAssertEqual(session.windows, updatedMRU)
    }

    func testClosingWindowsPreservesSelectionOrChoosesAdjacentSurvivor() {
        var session = SwitcherSession()
        session.begin(mode: .cycle, windows: windows)
        session.removeWindow(id: "0")
        XCTAssertEqual(session.selected?.id, "1")
        XCTAssertEqual(session.selectedIndex, 0)
        session.removeWindow(id: "1")
        XCTAssertEqual(session.selected?.id, "2")
        session.removeWindow(id: "2")
        XCTAssertNil(session.selected)
        XCTAssertTrue(session.windows.isEmpty)
        XCTAssertEqual(session.selectedIndex, 0)
    }

    func testClosingLastSelectedRowChoosesPreviousRow() {
        var session = SwitcherSession()
        session.begin(mode: .cycle, windows: windows, reverse: true)
        session.removeWindow(id: "2")
        XCTAssertEqual(session.selected?.id, "1")
    }

    func testClosingWindowExcludedByQueryDoesNotChangeSelection() {
        var session = SwitcherSession()
        session.begin(mode: .search, windows: windows)
        session.updateQuery("2")
        session.removeWindow(id: "0")
        XCTAssertEqual(session.selected?.id, "2")
        XCTAssertEqual(session.windows.map(\.id), ["1", "2"])
        session.updateQuery("")
        XCTAssertEqual(session.results.map(\.id), ["1", "2"])
    }

    func testPreferencesFromBeginningAreUsedForLaterQueries() {
        var session = SwitcherSession()
        session.begin(mode: .search, windows: windows,
                      preferences: ["document": SearchEngine.preferenceKey(for: windows[2])])
        session.updateQuery("Document")
        XCTAssertEqual(session.selected?.id, "2")
        session.updateQuery("document", preferences: ["document": SearchEngine.preferenceKey(for: windows[1])])
        XCTAssertEqual(session.selected?.id, "1")
    }

    func testCancelClearsStateAndLateEventsCannotRestartSession() {
        var session = SwitcherSession()
        session.begin(mode: .fastSearch, windows: windows)
        session.updateQuery("doc")
        session.end()
        session.move(1)
        session.updateQuery("editor")
        XCTAssertNil(session.mode)
        XCTAssertNil(session.selected)
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.windows.isEmpty)
        XCTAssertTrue(session.results.isEmpty)
    }

    func testZeroAndSingleWindowSessionsNeverProduceInvalidSelection() {
        var session = SwitcherSession()
        session.begin(mode: .cycle, windows: [], reverse: true)
        session.move(Int.max)
        XCTAssertNil(session.selected)
        XCTAssertEqual(session.selectedIndex, 0)
        session.begin(mode: .cycle, windows: [windows[0]])
        session.move(Int.min)
        XCTAssertEqual(session.selected, windows[0])
    }

    func testWarmingNewWindowsDoesNotChangeAnOpenSession() {
        var session = SwitcherSession()
        session.prepare(windows: windows)
        session.begin(mode: .search, windows: windows)
        session.updateQuery("document")
        session.move(1)
        let newWindow = WindowItem(id: "new", appName: "Éditeur", title: "Résumé 東京", bundleIdentifier: "test.editor")
        let replacement = [newWindow, windows[2], windows[0]]
        session.prepare(windows: replacement)
        XCTAssertEqual(session.windows, windows)
        XCTAssertEqual(session.results, windows)
        XCTAssertEqual(session.selected?.id, "1")
        session.updateQuery("resume")
        XCTAssertTrue(session.results.isEmpty)
        session.end()
        session.begin(mode: .search, windows: replacement)
        session.updateQuery("resume")
        XCTAssertEqual(session.results, [newWindow])
    }

    func testClosedWindowsStayRemovedWhenSearchingThePreparedSnapshot() {
        var session = SwitcherSession()
        session.prepare(windows: windows)
        session.begin(mode: .search, windows: windows)
        session.removeWindow(id: "1")
        session.updateQuery("document")
        XCTAssertEqual(session.results.map(\.id), ["0", "2"])
        session.updateQuery("")
        XCTAssertEqual(session.results.map(\.id), ["0", "2"])
    }
}
