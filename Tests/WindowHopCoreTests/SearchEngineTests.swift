import XCTest
@testable import WindowHopCore

final class SearchEngineTests: XCTestCase {
    private let engine = SearchEngine()

    private func window(_ id: String, _ app: String, _ title: String, bundle: String? = nil) -> WindowItem {
        WindowItem(id: id, appName: app, title: title, bundleIdentifier: bundle ?? "test.\(app)")
    }

    func testEmptyQueryPreservesMRUIncludingDistinctWindowsWithIdenticalTitles() {
        let windows = [window("second", "Safari", "Untitled"), window("first", "Safari", "Untitled")]
        XCTAssertEqual(engine.search(" \n\t", in: windows).map(\.id), ["second", "first"])
        XCTAssertEqual(engine.search("untitled", in: windows).map(\.id), ["second", "first"])
    }

    func testExactPrefixAndWordBoundariesBeatScatteredMatches() {
        let windows = [window("scattered", "Editor", "a c a t"),
                       window("boundary", "Editor", "The cat sleeps"),
                       window("prefix", "Editor", "catalog"),
                       window("exact", "Editor", "cat")]
        XCTAssertEqual(engine.search("cat", in: windows).map(\.id),
                       ["exact", "prefix", "boundary", "scattered"])
    }

    func testAcronymsAndCamelCaseRankAboveScatteredLetters() {
        let windows = [window("scattered", "Universal Scanner", "Notes"),
                       window("acronym", "Visual Studio Code", "Notes"),
                       window("camel", "VisualStudioCode", "Notes")]
        XCTAssertEqual(Set(engine.search("vsc", in: windows).prefix(2).map(\.id)),
                       Set(["acronym", "camel"]))
        XCTAssertTrue(engine.search("vcq", in: windows).isEmpty)
    }

    func testTokensCanMatchApplicationAndTitleInEitherOrder() {
        let proposal = window("proposal", "Pages", "Budget proposal")
        let notes = window("notes", "Pages", "Meeting notes")
        XCTAssertEqual(engine.search("pages proposal", in: [notes, proposal]), [proposal])
        XCTAssertEqual(engine.search("proposal pages", in: [notes, proposal]), [proposal])
        XCTAssertTrue(engine.search("pages zzzz", in: [notes, proposal]).isEmpty)
    }

    func testSubsequenceCanSpanApplicationAndTitle() {
        let match = window("match", "Safari", "Budget")
        XCTAssertEqual(engine.search("sbud", in: [match]), [match])
        XCTAssertTrue(engine.search("buds", in: [match]).isEmpty)
    }

    func testUnicodeCaseDiacriticsWidthAndEmoji() {
        let document = window("document", "Éditeur", "Résumé 東京 🐕")
        XCTAssertEqual(engine.search("EDITEUR resume", in: [document]), [document])
        XCTAssertEqual(engine.search("東京 🐕", in: [document]), [document])
        XCTAssertEqual(SearchEngine.normalizedQuery("  ＲÉＳＵＭÉ\n\t東京 "), "resume 東京")
        XCTAssertTrue(engine.search("🐈", in: [document]).isEmpty)
    }

    func testLearnedPreferencePromotesOnlyMatchingWindowsAndSurvivesNewIDs() {
        let exact = window("exact", "Safari", "proposal")
        let learnedOld = window("old", "Pages", "Budget proposal")
        let learnedNew = window("new", "Pages", "Budget proposal")
        let unrelated = window("unrelated", "Mail", "Inbox")
        let preferences = ["proposal": SearchEngine.preferenceKey(for: learnedOld),
                           "zzzz": SearchEngine.preferenceKey(for: unrelated)]
        XCTAssertEqual(engine.search("proposal", in: [exact, learnedNew], preferences: preferences).first?.id, "new")
        XCTAssertTrue(engine.search("zzzz", in: [unrelated], preferences: preferences).isEmpty)
    }

    func testPreferenceKeysUseApplicationIdentityAndUnambiguousSeparators() {
        let first = window("1", "Same", "c:de", bundle: "ab")
        let second = window("2", "Same", "de", bundle: "ab:c")
        let anotherApp = window("3", "Same", "c:de", bundle: "different")
        XCTAssertNotEqual(SearchEngine.preferenceKey(for: first), SearchEngine.preferenceKey(for: second))
        XCTAssertNotEqual(SearchEngine.preferenceKey(for: first), SearchEngine.preferenceKey(for: anotherApp))
    }

    func testPreparedSearchMatchesOneShotForUnicodeQueriesAndLearnedPreferences() {
        let windows = [window("1", "Éditeur", "Résumé 東京 👩🏽‍💻"),
                       window("2", "VisualStudioCode", "SearchEngine.swift"),
                       window("3", "Safari", "Résumé notes"),
                       window("4", "Pages", "Budget proposal"),
                       window("5", "Mail", "Budget\r\nplan")]
        let prepared = engine.prepare(windows)
        let preferences = ["resume": SearchEngine.preferenceKey(for: windows[2])]
        for query in ["", " \t", "ed", "ÉDI", "resume", "東京", "👩🏽‍💻", "👩‍💻", "vsc",
                      "search swift", "proposal pages", "budget plan", "zzzz"] {
            XCTAssertEqual(engine.search(query, in: prepared, preferences: preferences),
                           engine.search(query, in: windows, preferences: preferences), query)
        }
        XCTAssertEqual(engine.search("👩🏽‍💻", in: prepared).map(\.id), ["1"])
        XCTAssertTrue(engine.search("👩‍💻", in: prepared).isEmpty)
        XCTAssertEqual(engine.search("resume", in: prepared, preferences: preferences).map(\.id), ["3", "1"])
    }

    func testPreparationCacheReordersAndRefreshesMetadataWithoutChangingOldSnapshot() {
        var cache = SearchEngine.PreparationCache()
        let old = [window("a", "Éditeur", "Résumé 東京"), window("b", "Safari", "Budget proposal")]
        let first = cache.prepare(old)
        let updated = [WindowItem(id: "b", appName: "Safari", title: "Budget proposal", bundleIdentifier: "test.Safari", isMinimized: true),
                       window("a", "Éditeur", "Notes بغداد 👩🏽‍💻")]
        let second = cache.prepare(updated)
        XCTAssertEqual(engine.search("", in: second), updated)
        XCTAssertTrue(engine.search("budget", in: second)[0].isMinimized)
        XCTAssertEqual(engine.search("بغداد", in: second).map(\.id), ["a"])
        XCTAssertTrue(engine.search("東京", in: second).isEmpty)
        XCTAssertEqual(engine.search("東京", in: first), [old[0]])
        XCTAssertEqual(engine.search("", in: first), old)
    }

    func testPreparationCacheInvalidatesChangedAppAndBundleIdentity() {
        var cache = SearchEngine.PreparationCache()
        _ = cache.prepare([window("same", "Safari", "Budget", bundle: "old.app")])
        let changed = window("same", "Pages", "Budget", bundle: "new.app")
        let rival = window("rival", "Pages", "Budget", bundle: "rival.app")
        let prepared = cache.prepare([rival, changed])
        XCTAssertTrue(engine.search("safari", in: prepared).isEmpty)
        XCTAssertEqual(engine.search("budget", in: prepared,
                                     preferences: ["budget": SearchEngine.preferenceKey(for: changed)]).first, changed)
    }
}
