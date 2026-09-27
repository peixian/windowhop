import XCTest
@testable import WindowHopCore

final class WindowListPolicyTests: XCTestCase {
    private func window(_ id: String, visible: Bool? = true, fullScreen: Bool = false,
                        hidden: Bool = false, minimized: Bool = false, pid: Int32? = 1,
                        display: UInt32? = 1, applicationOnly: Bool = false) -> WindowItem {
        WindowItem(id: id, appName: "Editor", title: id, bundleIdentifier: "test.editor",
                   isMinimized: minimized, isHidden: hidden, processIdentifier: pid,
                   isOnVisibleSpace: visible, isFullScreen: fullScreen, displayID: display,
                   isApplicationOnly: applicationOnly)
    }

    func testDefaultKeepsAllWindowsInMRUOrder() {
        let windows = [window("other", visible: false), window("minimized", minimized: true),
                       window("hidden", hidden: true), window("front")]
        XCTAssertEqual(WindowListPolicy().apply(to: windows), windows)
    }

    func testVisibleSpaceScopesDistinguishFullscreenAndUnknownMembership() {
        let windows = [window("visible"), window("other", visible: false),
                       window("full", visible: false, fullScreen: true),
                       window("unknown", visible: nil), window("unknown-hidden", visible: nil, hidden: true)]
        XCTAssertEqual(WindowListPolicy(spaceScope: .visible).apply(to: windows).map(\.id),
                       ["visible", "unknown", "unknown-hidden"])
        XCTAssertEqual(WindowListPolicy(spaceScope: .visibleAndFullScreen).apply(to: windows).map(\.id),
                       ["visible", "full", "unknown", "unknown-hidden"])
    }

    func testHiddenWindowsWithKnownOtherSpaceAreFilteredNormally() {
        let windows = [window("hidden-other", visible: false, hidden: true), window("hidden-here", hidden: true)]
        XCTAssertEqual(WindowListPolicy(spaceScope: .visible).apply(to: windows).map(\.id), ["hidden-here"])
    }

    func testBottomPlacementIsAStablePartition() {
        let windows = [window("hidden-1", hidden: true), window("front-1"),
                       window("minimized", minimized: true), window("front-2"), window("hidden-2", hidden: true)]
        let policy = WindowListPolicy(minimized: .bottom, hidden: .bottom)
        XCTAssertEqual(policy.apply(to: windows).map(\.id), ["front-1", "front-2", "hidden-1", "minimized", "hidden-2"])
    }

    func testExclusionWinsOverBottomPlacementAndOptionsAreIndependent() {
        let windows = [window("both", hidden: true, minimized: true), window("min", minimized: true),
                       window("hidden", hidden: true), window("normal")]
        XCTAssertEqual(WindowListPolicy(minimized: .bottom, hidden: .exclude).apply(to: windows).map(\.id), ["normal", "min"])
        XCTAssertEqual(WindowListPolicy(minimized: .exclude, hidden: .normal).apply(to: windows).map(\.id), ["hidden", "normal"])
    }

    func testCurrentApplicationUsesProcessIdentityAndRequiresContext() {
        let windows = [window("a", pid: 20), window("b", pid: 21), window("unknown", pid: nil), window("c", pid: 20)]
        let policy = WindowListPolicy(currentApplicationOnly: true)
        XCTAssertEqual(policy.apply(to: windows, frontmostProcessIdentifier: 20).map(\.id), ["a", "c"])
        XCTAssertTrue(policy.apply(to: windows).isEmpty)
    }

    func testDisplayFilterIncludesUnknownMetadataWithoutDroppingTargets() {
        let windows = [window("one", display: 1), window("two", display: 2), window("unknown", display: nil),
                       window("app", visible: nil, display: nil, applicationOnly: true)]
        XCTAssertEqual(WindowListPolicy().apply(to: windows, displayID: 2).map(\.id), ["two", "unknown", "app"])
        XCTAssertEqual(WindowListPolicy(includeApplicationsWithoutWindows: false).apply(to: windows, displayID: 2).map(\.id), ["two", "unknown"])
    }

    func testWindowlessApplicationCanBeExcludedAndHonorsHiddenSetting() {
        let windows = [window("normal"), window("app", visible: nil, applicationOnly: true),
                       window("hidden-app", visible: nil, hidden: true, applicationOnly: true)]
        XCTAssertEqual(WindowListPolicy(spaceScope: .visible, hidden: .exclude).apply(to: windows).map(\.id), ["normal", "app"])
        XCTAssertEqual(WindowListPolicy(includeApplicationsWithoutWindows: false).apply(to: windows).map(\.id), ["normal"])
    }

    func testOldWindowFixtureDecodesWithoutNewMetadata() throws {
        let data = Data(#"{"id":"a","appName":"App","title":"Window","bundleIdentifier":"test.app"}"#.utf8)
        let item = try JSONDecoder().decode(WindowItem.self, from: data)
        XCTAssertNil(item.processIdentifier)
        XCTAssertNil(item.isOnVisibleSpace)
        XCTAssertFalse(item.isApplicationOnly)
        XCTAssertFalse(item.isFullScreen)
        XCTAssertTrue(item.spaceIDs.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(WindowItem.self, from: JSONEncoder().encode(item)), item)
    }

    func testPolicyRoundTripKeepsIndependentOptions() throws {
        let policy = WindowListPolicy(spaceScope: .visibleAndFullScreen, minimized: .bottom, hidden: .exclude,
                                      currentApplicationOnly: true, includeApplicationsWithoutWindows: false)
        XCTAssertEqual(try JSONDecoder().decode(WindowListPolicy.self, from: JSONEncoder().encode(policy)), policy)
    }
}
