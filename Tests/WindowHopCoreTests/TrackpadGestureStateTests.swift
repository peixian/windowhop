import XCTest
@testable import WindowHopCore

final class TrackpadGestureStateTests: XCTestCase {
    private func pair(x: Double = 0.1, y: Double = 0.96) -> [TrackpadGestureState.Contact] {
        [.init(id: 1, x: x, y: y), .init(id: 2, x: x + 0.06, y: y - 0.01)]
    }

    func testBothPhysicalTopCornersBeginMoveReverseAndCommitOnFullLift() {
        for x in [0.1, 0.8] {
            var state = TrackpadGestureState()
            XCTAssertEqual(state.update(contacts: pair(x: x), timestamp: 0), [])
            XCTAssertTrue(state.ownsScroll)
            XCTAssertEqual(state.update(contacts: pair(x: x, y: 0.92), timestamp: 0.02), [.begin])
            XCTAssertEqual(state.update(contacts: pair(x: x, y: 0.82), timestamp: 0.04), [.move(2)])
            XCTAssertEqual(state.update(contacts: pair(x: x, y: 0.88), timestamp: 0.05), [.move(-1)])
            XCTAssertEqual(state.update(contacts: [pair(x: x, y: 0.88)[0]], timestamp: 0.06), [])
            XCTAssertTrue(state.isActive)
            XCTAssertEqual(state.update(contacts: [], timestamp: 0.07), [.commit])
            XCTAssertFalse(state.ownsScroll)
        }
    }

    func testOrdinaryScrollAndTopCenterNeverAcquireGesture() {
        for (x, y) in [(0.1, 0.5), (0.4, 0.96), (0.6, 0.7)] {
            var state = TrackpadGestureState()
            XCTAssertEqual(state.update(contacts: pair(x: x, y: y), timestamp: 0), [])
            XCTAssertEqual(state.update(contacts: pair(x: x, y: 0.4), timestamp: 0.02), [])
            XCTAssertFalse(state.ownsScroll)
            XCTAssertFalse(state.isActive)
        }
    }

    func testOriginCannotBeMovedIntoCornerOrJoinedByAnOldRestingFinger() {
        var state = TrackpadGestureState()
        _ = state.update(contacts: [.init(id: 1, x: 0.1, y: 0.6)], timestamp: 0)
        XCTAssertEqual(state.update(contacts: pair(), timestamp: 0.02), [])
        XCTAssertFalse(state.ownsScroll)
        _ = state.update(contacts: [], timestamp: 0.03)
        _ = state.update(contacts: [pair()[0]], timestamp: 0.1)
        _ = state.update(contacts: pair(), timestamp: 0.5)
        XCTAssertFalse(state.ownsScroll)
    }

    func testPassedScrollDoesNotBecomeGestureMidStream() {
        var state = TrackpadGestureState()
        state.unownedScrollDidPass()
        _ = state.update(contacts: pair(), timestamp: 0)
        XCTAssertFalse(state.ownsScroll)
        _ = state.update(contacts: pair(y: 0.8), timestamp: 0.03)
        XCTAssertFalse(state.isActive)
        _ = state.update(contacts: [], timestamp: 0.04)
        _ = state.update(contacts: pair(), timestamp: 1)
        XCTAssertTrue(state.ownsScroll)
    }

    func testAddedFingerOrHorizontalMotionCancelsButKeepsOwnedScrollUntilLift() {
        for extraFinger in [true, false] {
            var state = TrackpadGestureState()
            _ = state.update(contacts: pair(), timestamp: 0)
            _ = state.update(contacts: pair(y: 0.92), timestamp: 0.02)
            let invalid = extraFinger ? pair(y: 0.9) + [.init(id: 3, x: 0.3, y: 0.9)] : pair(x: 0.5, y: 0.9)
            XCTAssertEqual(state.update(contacts: invalid, timestamp: 0.03), [.cancel])
            XCTAssertTrue(state.ownsScroll)
            XCTAssertEqual(state.update(contacts: [], timestamp: 0.04), [])
            XCTAssertFalse(state.ownsScroll)
        }
    }

    func testIdentityReplacementRecontactAndInvalidCoordinatesFailClosed() {
        var state = TrackpadGestureState()
        _ = state.update(contacts: pair(), timestamp: 0)
        _ = state.update(contacts: pair(y: 0.92), timestamp: 0.02)
        XCTAssertEqual(state.update(contacts: [.init(id: 1, x: .nan, y: 0.9)], timestamp: 0.03), [.cancel])
        _ = state.update(contacts: [], timestamp: 0.04)
        _ = state.update(contacts: pair(), timestamp: 1)
        _ = state.update(contacts: pair(y: 0.92), timestamp: 1.02)
        _ = state.update(contacts: [pair(y: 0.92)[0]], timestamp: 1.03)
        XCTAssertEqual(state.update(contacts: pair(y: 0.91), timestamp: 1.04), [.cancel])
        XCTAssertEqual(state.update(contacts: [], timestamp: 1.05), [])
        _ = state.update(contacts: pair(), timestamp: 2)
        _ = state.update(contacts: pair(y: 0.92), timestamp: 2.02)
        XCTAssertEqual(state.update(contacts: [.init(id: 1, x: 0.1, y: 0.9), .init(id: 3, x: 0.16, y: 0.9)], timestamp: 2.03), [.cancel])
    }
    func testCancellingIdleStateDoesNotDiscardTheNextGesture() {
        var state = TrackpadGestureState()
        XCTAssertEqual(state.cancel(), [])
        _ = state.update(contacts: pair(), timestamp: 0)
        XCTAssertEqual(state.update(contacts: pair(y: 0.92), timestamp: 0.02), [.begin])
        XCTAssertEqual(state.update(contacts: [], timestamp: 0.03), [.commit])
        XCTAssertEqual(state.cancel(), [])
        _ = state.update(contacts: pair(), timestamp: 1)
        XCTAssertEqual(state.update(contacts: pair(y: 0.92), timestamp: 1.02), [.begin])
    }

    func testInvalidInitialFramesStayBlockedUntilEveryFingerLifts() {
        let invalidStarts = [
            pair() + [.init(id: 3, x: 0.2, y: 0.95)],
            [TrackpadGestureState.Contact(id: 1, x: .nan, y: 0.95)],
            [TrackpadGestureState.Contact(id: 1, x: 0.1, y: 0.95), .init(id: 1, x: 0.16, y: 0.96)]
        ]
        for contacts in invalidStarts {
            var state = TrackpadGestureState()
            XCTAssertEqual(state.update(contacts: contacts, timestamp: 0), [])
            XCTAssertEqual(state.update(contacts: pair(), timestamp: 0.01), [])
            XCTAssertEqual(state.update(contacts: pair(y: 0.92), timestamp: 0.02), [])
            XCTAssertFalse(state.ownsScroll)
            XCTAssertFalse(state.isActive)
            _ = state.update(contacts: [], timestamp: 0.03)
            _ = state.update(contacts: pair(), timestamp: 1)
            XCTAssertEqual(state.update(contacts: pair(y: 0.92), timestamp: 1.02), [.begin])
        }
    }

}
