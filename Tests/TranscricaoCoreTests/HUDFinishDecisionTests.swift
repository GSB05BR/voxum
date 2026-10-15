// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class HUDFinishDecisionTests: XCTestCase {
    func testRecordingWinsOverEverything() {
        XCTAssertEqual(HUDFinishDecision.decide(isRecording: true, isProcessing: false, error: nil), .ignore)
        XCTAssertEqual(HUDFinishDecision.decide(isRecording: true, isProcessing: false, error: "x"), .ignore)
    }
    func testProcessingKeepsPill() {
        XCTAssertEqual(HUDFinishDecision.decide(isRecording: false, isProcessing: true, error: nil), .keepProcessing)
        XCTAssertEqual(HUDFinishDecision.decide(isRecording: false, isProcessing: true, error: "x"), .flashError("x"))
    }
    func testIdleHidesOrShowsError() {
        XCTAssertEqual(HUDFinishDecision.decide(isRecording: false, isProcessing: false, error: nil), .hide)
        XCTAssertEqual(HUDFinishDecision.decide(isRecording: false, isProcessing: false, error: "x"), .showError("x"))
    }
}

/// A notice while a file is transcribed must not leave the dictation pill up (review I1).
final class HUDNoticeDecisionTests: XCTestCase {
    func testFileWorkAloneNeverBringsThePillBack() {
        // Status .processing because of the file; no dictation or question in flight.
        XCTAssertFalse(HUDNoticeDecision.thenProcessing(clipsInFlight: 0, answerPanelVisible: false))
        XCTAssertFalse(HUDNoticeDecision.clipProcessing(statusIsProcessing: true, clipsInFlight: 0))
        XCTAssertEqual(HUDFinishDecision.decide(
            isRecording: false,
            isProcessing: HUDNoticeDecision.clipProcessing(statusIsProcessing: true, clipsInFlight: 0),
            error: nil), .hide)
    }
    func testAClipInFlightKeepsItsPill() {
        XCTAssertTrue(HUDNoticeDecision.thenProcessing(clipsInFlight: 1, answerPanelVisible: false))
        XCTAssertFalse(HUDNoticeDecision.thenProcessing(clipsInFlight: 1, answerPanelVisible: true))
        XCTAssertTrue(HUDNoticeDecision.clipProcessing(statusIsProcessing: true, clipsInFlight: 1))
        XCTAssertFalse(HUDNoticeDecision.clipProcessing(statusIsProcessing: false, clipsInFlight: 1))
    }
}
