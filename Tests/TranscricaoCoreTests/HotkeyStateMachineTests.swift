// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class HotkeyStateMachineTests: XCTestCase {
    private var m = HotkeyStateMachine()

    override func setUp() { m = HotkeyStateMachine() }

    func testHoldIsPushToTalk() {
        XCTAssertEqual(m.handle(.keyDown(10.0)), [.startCapture])
        XCTAssertEqual(m.handle(.keyUp(10.8)), [.stopAndProcess])
        XCTAssertEqual(m.state, .idle)
    }

    func testHoldExactlyAtThresholdIsPushToTalk() {
        _ = m.handle(.keyDown(0))
        XCTAssertEqual(m.handle(.keyUp(0.25)), [.stopAndProcess])
    }

    func testSingleShortTapIsCancelledAfterWindow() {
        XCTAssertEqual(m.handle(.keyDown(0)), [.startCapture])
        XCTAssertEqual(m.handle(.keyUp(0.1)), [])
        XCTAssertEqual(m.state, .awaitingSecondTap(releasedAt: 0.1))
        XCTAssertEqual(m.handle(.tick(0.3)), [])          // window still open
        XCTAssertEqual(m.handle(.tick(0.6)), [.cancel])   // window (0.4 s) closed
        XCTAssertEqual(m.state, .idle)
    }

    func testDoubleTapEntersContinuousAndNextTapStops() {
        _ = m.handle(.keyDown(0))
        _ = m.handle(.keyUp(0.1))
        XCTAssertEqual(m.handle(.keyDown(0.3)), [])
        XCTAssertTrue(m.isContinuous)
        XCTAssertEqual(m.handle(.keyUp(0.35)), [])        // release of 2nd tap ignored
        XCTAssertEqual(m.handle(.tick(5)), [])
        XCTAssertEqual(m.handle(.keyDown(12)), [.stopAndProcess])
        XCTAssertEqual(m.handle(.keyUp(12.1)), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testLateSecondPressRestartsCapture() {
        _ = m.handle(.keyDown(0))
        _ = m.handle(.keyUp(0.1))
        // tick was lost; press arrives after the window
        XCTAssertEqual(m.handle(.keyDown(1.0)), [.cancel, .startCapture])
        XCTAssertEqual(m.state, .pressed(at: 1.0))
    }

    func testOptionAsModifierCancelsWhilePressed() {
        _ = m.handle(.keyDown(0))
        XCTAssertEqual(m.handle(.otherKey), [.cancel])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.handle(.keyUp(0.6)), [])         // stray release does nothing
    }

    func testOptionAsModifierCancelsWhileAwaitingSecondTap() {
        _ = m.handle(.keyDown(0))
        _ = m.handle(.keyUp(0.1))
        XCTAssertEqual(m.handle(.otherKey), [.cancel])
        XCTAssertEqual(m.state, .idle)
    }

    func testTypingDuringContinuousIsIgnored() {
        _ = m.handle(.keyDown(0)); _ = m.handle(.keyUp(0.1)); _ = m.handle(.keyDown(0.2))
        XCTAssertEqual(m.handle(.otherKey), [])
        XCTAssertTrue(m.isContinuous)
    }

    func testEscapeCancelsAnyCapture() {
        _ = m.handle(.keyDown(0))
        XCTAssertEqual(m.handle(.escape), [.cancel])
        _ = m.handle(.keyDown(1)); _ = m.handle(.keyUp(1.1)); _ = m.handle(.keyDown(1.2))
        XCTAssertEqual(m.handle(.escape), [.cancel])
        XCTAssertEqual(m.state, .idle)
    }

    func testEscapeWhenIdleDoesNothing() {
        XCTAssertEqual(m.handle(.escape), [])
        XCTAssertEqual(m.handle(.otherKey), [])
        XCTAssertEqual(m.handle(.keyUp(3)), [])
    }

    func testResetLeavesContinuousModeAndStartsFresh() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(0)); _ = m.handle(.keyUp(0.1)); _ = m.handle(.keyDown(0.2))
        XCTAssertTrue(m.isContinuous)
        m.reset()
        XCTAssertFalse(m.isContinuous)
        XCTAssertEqual(m.handle(.keyDown(5)), [.startCapture])
    }
}
