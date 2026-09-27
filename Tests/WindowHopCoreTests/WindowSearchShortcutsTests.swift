import XCTest
@testable import WindowHopCore

final class WindowSearchShortcutsTests: XCTestCase {
    private func window(_ id: String, _ app: String, _ title: String = "") -> WindowItem {
        WindowItem(id: id, appName: app, title: title, bundleIdentifier: "test.\(app)")
    }

    func testExactAutomaticCodePromotesItsTargetAndPreservesOtherFuzzyMatches() throws {
        let target = window("target", "Alpha", "Document")
        let rival = window("rival", "Zebra", "a")
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [rival, target])
        let code = try XCTUnwrap(session.searchShortcuts[target.id])
        XCTAssertEqual(code, "a")
        XCTAssertEqual(SearchEngine().search(code, in: [rival, target]).first, rival)
        session.updateQuery(code)
        XCTAssertEqual(session.results, [target, rival])
        session.updateQuery("   ")
        XCTAssertEqual(session.results, [rival, target])
    }

    func testMoreThan26IdenticalWindowsHaveUniqueWorkingCodesIncludingAbsentCharacters() throws {
        let windows = (0..<80).map { window(String(format: "%03d", $0), "X") }
        var session = SwitcherSession()
        session.begin(mode: .search, windows: Array(windows.reversed()))
        XCTAssertEqual(session.searchShortcuts.count, windows.count)
        XCTAssertEqual(Set(session.searchShortcuts.values).count, windows.count)
        XCTAssertTrue(session.searchShortcuts.values.allSatisfy { $0.count <= 3 })
        let synthetic = try XCTUnwrap(session.searchShortcuts.first { $0.value.contains("a") })
        XCTAssertTrue(SearchEngine().search(synthetic.value, in: windows).isEmpty)
        for item in windows {
            let code = try XCTUnwrap(session.searchShortcuts[item.id])
            session.updateQuery(code)
            XCTAssertEqual(session.selected?.id, item.id, code)
        }
    }

    func testEveryLearnedShortQueryWorksAndItsShortestCodeIsDisplayed() throws {
        let target = window("target", "Editor", "Document")
        let rival = window("rival", "Quartz", "Notes")
        let preferences = ["qq": SearchEngine.preferenceKey(for: target),
                           "q": SearchEngine.preferenceKey(for: target),
                           "qz": SearchEngine.preferenceKey(for: target)]
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [rival, target], preferences: preferences)
        XCTAssertEqual(session.searchShortcuts[target.id], "q")
        XCTAssertNotEqual(session.searchShortcuts[rival.id], "q")
        for query in preferences.keys {
            session.updateQuery(query)
            XCTAssertEqual(session.selected, target, query)
        }
        session.updateQuery(" QZ \n")
        XCTAssertEqual(session.selected, target)
        let rivalCode = try XCTUnwrap(session.searchShortcuts[rival.id])
        session.updateQuery(rivalCode)
        XCTAssertEqual(session.selected, rival)
    }

    func testLearningWinsAnAutomaticCollisionAndForgettingDropsLearnedCodes() throws {
        let editor = window("editor", "Editor", "Notes")
        let mail = window("mail", "Mail", "Inbox")
        let windows = [mail, editor]
        var session = SwitcherSession()
        session.begin(mode: .search, windows: windows)
        let originalMailCode = try XCTUnwrap(session.searchShortcuts[mail.id])
        XCTAssertEqual(session.searchShortcuts[editor.id], "e")
        session.end()

        let preferences = ["e": SearchEngine.preferenceKey(for: mail),
                           "zz": SearchEngine.preferenceKey(for: mail)]
        session.prepare(windows: windows, preferences: preferences)
        session.begin(mode: .search, windows: windows, preferences: preferences)
        XCTAssertEqual(session.searchShortcuts[mail.id], "e")
        XCTAssertNotEqual(session.searchShortcuts[editor.id], "e")
        session.updateQuery("e")
        XCTAssertEqual(session.selected, mail)
        session.updateQuery(originalMailCode)
        XCTAssertEqual(session.selected, mail)
        session.end()

        session.prepare(windows: windows, preferences: [:])
        session.begin(mode: .search, windows: windows)
        XCTAssertEqual(session.searchShortcuts[mail.id], originalMailCode)
        session.updateQuery("zz")
        XCTAssertTrue(session.results.isEmpty)
    }

    func testLearnedQueryForAbsentWindowIsReservedInsteadOfAssignedToAnotherWindow() throws {
        let absent = window("absent", "Mail", "Inbox")
        let live = window("live", "Window", "Document")
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [live],
                      preferences: ["w": SearchEngine.preferenceKey(for: absent)])
        XCTAssertNotEqual(try XCTUnwrap(session.searchShortcuts[live.id]), "w")
    }

    func testLearnedDuplicateTitleHasStableOwnerAndOtherDuplicateStillGetsDistinctCode() throws {
        let first = window("a", "Editor", "Untitled")
        let second = window("b", "Editor", "Untitled")
        let preferences = ["q": SearchEngine.preferenceKey(for: second)]
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [second, first], preferences: preferences)
        XCTAssertEqual(session.searchShortcuts[first.id], "q")
        let otherCode = try XCTUnwrap(session.searchShortcuts[second.id])
        XCTAssertNotEqual(otherCode, "q")
        session.updateQuery("q")
        XCTAssertEqual(session.selected, first)
        session.updateQuery(otherCode)
        XCTAssertEqual(session.selected, second)
        session.end()
        session.begin(mode: .search, windows: [first, second], preferences: preferences)
        session.updateQuery("q")
        XCTAssertEqual(session.selected, first)
    }

    func testUnicodeAndUntitledEmojiWindowsReceiveUsableNormalizedCodes() throws {
        let windows = [window("accent", "Éditeur", "Résumé"),
                       window("cjk", "東京", "開発"),
                       window("arabic", "محرر", "ملف"),
                       window("emoji", "🐕", "👩🏽‍💻"),
                       window("empty", "", "")]
        var session = SwitcherSession()
        session.begin(mode: .fastSearch, windows: windows)
        XCTAssertEqual(Set(session.searchShortcuts.values).count, windows.count)
        XCTAssertEqual(session.searchShortcuts["accent"], "e")
        XCTAssertEqual(session.searchShortcuts["cjk"], "東")
        for item in windows {
            let code = try XCTUnwrap(session.searchShortcuts[item.id])
            session.updateQuery(code.uppercased())
            XCTAssertEqual(session.selected, item)
        }
    }

    func testAllocationsAreIndependentOfMRUAndRemainStableAcrossTitlesAndNumberedBoundary() throws {
        let windows = (0..<14).map { window(String(format: "%02d", $0), "Editor", "Document \($0)") }
        var first = SwitcherSession()
        first.begin(mode: .search, windows: windows)
        let shortcuts = first.searchShortcuts
        var second = SwitcherSession()
        second.begin(mode: .search, windows: Array(windows.reversed()))
        XCTAssertEqual(second.searchShortcuts, shortcuts)
        XCTAssertEqual(shortcuts.count, 14)
        let formerlyTenth = windows[9]
        let renamed = window(formerlyTenth.id, formerlyTenth.appName, "Entirely new title")
        let reordered = [renamed] + Array(windows.filter { $0.id != formerlyTenth.id }.reversed())
        first.end()
        first.prepare(windows: reordered)
        first.begin(mode: .search, windows: reordered)
        XCTAssertEqual(first.searchShortcuts, shortcuts)
        first.updateQuery(try XCTUnwrap(shortcuts[formerlyTenth.id]))
        XCTAssertEqual(first.selected, renamed)
    }

    func testBackgroundPreparationDoesNotChangeOpenAliasesOrResults() throws {
        let first = window("first", "Editor", "Notes")
        let second = window("second", "Mail", "Inbox")
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [first, second])
        let shortcuts = session.searchShortcuts
        let firstCode = try XCTUnwrap(shortcuts[first.id])
        let newWindow = window("new", "Alpha", "Document")
        let nextPreferences = [firstCode: SearchEngine.preferenceKey(for: second)]
        session.prepare(windows: [newWindow, second], preferences: nextPreferences)
        XCTAssertEqual(session.searchShortcuts, shortcuts)
        session.updateQuery(firstCode)
        XCTAssertEqual(session.selected, first)
        XCTAssertFalse(session.searchShortcuts.keys.contains(newWindow.id))
        session.end()
        XCTAssertTrue(session.searchShortcuts.isEmpty)
        session.begin(mode: .search, windows: [newWindow, second], preferences: nextPreferences)
        session.updateQuery(firstCode)
        XCTAssertEqual(session.selected, second)
        XCTAssertNil(session.searchShortcuts[first.id])
    }

    func testClosedTargetsDisappearWithoutReassigningSurvivorCodes() throws {
        let windows = (0..<6).map { window("\($0)", "X") }
        var session = SwitcherSession()
        session.begin(mode: .search, windows: windows)
        let shortcuts = session.searchShortcuts
        let closing = try XCTUnwrap(shortcuts.first { $0.value == "xa" })
        session.removeWindow(id: closing.key)
        XCTAssertEqual(session.searchShortcuts, shortcuts.filter { $0.key != closing.key })
        session.updateQuery(closing.value)
        XCTAssertTrue(session.results.isEmpty)
        for item in windows where item.id != closing.key {
            session.updateQuery(try XCTUnwrap(session.searchShortcuts[item.id]))
            XCTAssertEqual(session.selected, item)
        }
    }

    func testChangedPreferencesAreRepreparedEvenWhenWindowSnapshotIsAlreadyWarm() {
        let first = window("first", "Editor", "Notes")
        let second = window("second", "Mail", "Inbox")
        var session = SwitcherSession()
        session.prepare(windows: [first, second])
        session.begin(mode: .search, windows: [first, second],
                      preferences: ["q": SearchEngine.preferenceKey(for: second)])
        XCTAssertEqual(session.searchShortcuts[second.id], "q")
        session.updateQuery("q")
        XCTAssertEqual(session.selected, second)
    }

    func testLongLearnedQueriesKeepTheirExistingFuzzyRankingBehavior() {
        let first = window("first", "Editor", "Document")
        let second = window("second", "Mail", "Document attachment")
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [first, second],
                      preferences: ["document": SearchEngine.preferenceKey(for: second)])
        session.updateQuery("document")
        XCTAssertEqual(session.selected, second)
        session.updateQuery("document", preferences: ["document": SearchEngine.preferenceKey(for: first)])
        XCTAssertEqual(session.selected, first)
        XCTAssertFalse(session.searchShortcuts.values.contains("document"))
    }

    func testRecognizesOnlyTheAssignedTargetOfAnExactNormalizedShortcut() throws {
        let first = window("a", "Editor", "Document")
        let second = window("b", "Editor", "Document")
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [first, second])
        let code = try XCTUnwrap(session.searchShortcuts[second.id])
        XCTAssertTrue(session.isSearchShortcut(code, forWindowID: second.id))
        XCTAssertTrue(session.isSearchShortcut(" \(code.uppercased())\n", forWindowID: second.id))
        XCTAssertFalse(session.isSearchShortcut(code, forWindowID: first.id))
        XCTAssertFalse(session.isSearchShortcut("document", forWindowID: second.id))
        XCTAssertFalse(session.isSearchShortcut(code, forWindowID: "absent"))
        session.updateQuery(code)
        session.move(1)
        XCTAssertEqual(session.selected, first)
        XCTAssertFalse(session.isSearchShortcut(code, forWindowID: first.id))
        session.removeWindow(id: second.id)
        XCTAssertFalse(session.isSearchShortcut(code, forWindowID: second.id))
        session.end()
        XCTAssertFalse(session.isSearchShortcut(code, forWindowID: second.id))
    }

    func testCommittingAnAssignedCodeDoesNotCollapseDuplicateWindowsOrLoseCodeAfterRename() throws {
        let first = window("a", "Editor", "Untitled")
        let second = window("b", "Editor", "Untitled")
        var preferences: [String: String] = [:]
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [first, second], preferences: preferences)
        let code = try XCTUnwrap(session.searchShortcuts[second.id])
        session.updateQuery(code)
        let selected = try XCTUnwrap(session.selected)
        XCTAssertEqual(selected, second)
        // Mirrors the commit boundary: record a new preference only when the
        // user selected something other than this query's assigned target.
        if !session.isSearchShortcut(session.query, forWindowID: selected.id) {
            preferences[SearchEngine.normalizedQuery(session.query)] = SearchEngine.preferenceKey(for: selected)
        }
        session.end()
        XCTAssertTrue(preferences.isEmpty)
        session.begin(mode: .search, windows: [second, first], preferences: preferences)
        session.updateQuery(code)
        XCTAssertEqual(session.selected, second)
        session.end()

        let renamed = window(second.id, second.appName, "Saved document")
        session.prepare(windows: [renamed, first], preferences: preferences)
        session.begin(mode: .search, windows: [renamed, first], preferences: preferences)
        XCTAssertEqual(session.searchShortcuts[renamed.id], code)
        session.updateQuery(code)
        XCTAssertEqual(session.selected, renamed)
    }

    func testSelectingAnotherWindowForAnAssignedCodeCanStillTeachANewPreference() throws {
        let editor = window("editor", "Editor", "Notes")
        let mail = window("mail", "Mail", "Editor notes attachment")
        var preferences: [String: String] = [:]
        var session = SwitcherSession()
        session.begin(mode: .search, windows: [editor, mail])
        let code = try XCTUnwrap(session.searchShortcuts[editor.id])
        session.updateQuery(code)
        XCTAssertEqual(session.selected, editor)
        session.move(1)
        let chosen = try XCTUnwrap(session.selected)
        XCTAssertEqual(chosen, mail)
        XCTAssertFalse(session.isSearchShortcut(code, forWindowID: chosen.id))
        if !session.isSearchShortcut(code, forWindowID: chosen.id) {
            preferences[code] = SearchEngine.preferenceKey(for: chosen)
        }
        session.end()
        session.begin(mode: .search, windows: [editor, mail], preferences: preferences)
        session.updateQuery(code)
        XCTAssertEqual(session.selected, mail)
    }

    func testRenamingOrChangingBundleIdentityStopsUsingStaleLearnedTarget() {
        let original = window("same", "Editor", "Notes")
        let replacements = [window(original.id, original.appName, "Renamed"),
                            WindowItem(id: original.id, appName: original.appName,
                                       title: original.title, bundleIdentifier: "different.editor")]
        let preferences = ["q": SearchEngine.preferenceKey(for: original)]
        for replacement in replacements {
            var session = SwitcherSession()
            session.prepare(windows: [original], preferences: preferences)
            session.begin(mode: .search, windows: [original], preferences: preferences)
            XCTAssertTrue(session.isSearchShortcut("q", forWindowID: original.id))
            session.end()
            session.prepare(windows: [replacement], preferences: preferences)
            session.begin(mode: .search, windows: [replacement], preferences: preferences)
            XCTAssertFalse(session.isSearchShortcut("q", forWindowID: replacement.id))
            session.updateQuery("q")
            XCTAssertTrue(session.results.isEmpty)
        }
    }

    func testChangingAppNameReevaluatesAnAmbiguousLearnedOwner() {
        let first = WindowItem(id: "first", appName: "Alpha", title: "Notes", bundleIdentifier: "test.shared")
        let second = WindowItem(id: "second", appName: "Zulu", title: "Notes", bundleIdentifier: "test.shared")
        let preferences = ["q": SearchEngine.preferenceKey(for: first)]
        var session = SwitcherSession()
        session.prepare(windows: [first, second], preferences: preferences)
        session.begin(mode: .search, windows: [first, second], preferences: preferences)
        session.updateQuery("q")
        XCTAssertEqual(session.selected, first)
        session.end()
        let renamed = WindowItem(id: first.id, appName: "ZZZ", title: first.title,
                                 bundleIdentifier: first.bundleIdentifier)
        session.prepare(windows: [renamed, second], preferences: preferences)
        session.begin(mode: .search, windows: [renamed, second], preferences: preferences)
        session.updateQuery("q")
        XCTAssertEqual(session.selected, second)
    }
}
