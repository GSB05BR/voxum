// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class DictationStatusLogicTests: XCTestCase {
    typealias L = DictationStatusLogic

    // MARK: start

    func testStartAllowedOnlyWhenReadyOrProcessing() {
        XCTAssertTrue(L.canStartCapture(.ready))
        XCTAssertTrue(L.canStartCapture(.processing))
        XCTAssertFalse(L.canStartCapture(.recording(continuous: false)))
        XCTAssertFalse(L.canStartCapture(.preparing("x")))
        XCTAssertFalse(L.canStartCapture(.error("x")))
    }

    func testRefusedStartLeavesStatusAlone() {
        // A refused start never reaches afterStart; a continuous double-tap on top of it must not
        // invent a recording.
        XCTAssertEqual(L.afterContinuousChange(.ready, continuous: true), .ready)
        XCTAssertEqual(L.afterContinuousChange(.preparing("p"), continuous: true), .preparing("p"))
        XCTAssertEqual(L.afterContinuousChange(.error("e"), continuous: true), .error("e"))
        XCTAssertEqual(L.afterContinuousChange(.processing, continuous: true), .processing)
    }

    func testContinuousUpgradesAnActiveRecording() {
        XCTAssertEqual(L.afterContinuousChange(.recording(continuous: false), continuous: true),
                       .recording(continuous: true))
        // Leaving continuous mode is handled by stop/cancel, not here.
        XCTAssertEqual(L.afterContinuousChange(.recording(continuous: true), continuous: false),
                       .recording(continuous: true))
    }

    func testMicFailureKeepsStatus() {
        XCTAssertEqual(L.afterMicFailure(.ready), .ready)
        XCTAssertEqual(L.afterMicFailure(.processing), .processing)
    }

    // MARK: cancel

    func testCancelAloneReturnsToReady() {
        XCTAssertEqual(L.afterCancel(.recording(continuous: false), inFlight: 0), .ready)
        XCTAssertEqual(L.afterCancel(.recording(continuous: true), inFlight: 0), .ready)
    }

    func testCancelWithClipInFlightShowsProcessing() {
        XCTAssertEqual(L.afterCancel(.recording(continuous: false), inFlight: 1), .processing)
    }

    func testCancelOutsideRecordingIsNoOp() {
        XCTAssertEqual(L.afterCancel(.processing, inFlight: 1), .processing)
        XCTAssertEqual(L.afterCancel(.preparing("p"), inFlight: 0), .preparing("p"))
        XCTAssertEqual(L.afterCancel(.error("e"), inFlight: 0), .error("e"))
    }

    // MARK: clip finished

    func testFinishWithoutNewerRecording() {
        XCTAssertEqual(L.afterClipFinished(.processing, inFlight: 0, modelsLost: false), .ready)
        XCTAssertEqual(L.afterClipFinished(.processing, inFlight: 1, modelsLost: false), .processing)
    }

    func testFinishKeepsNewerRecording() {
        XCTAssertEqual(L.afterClipFinished(.recording(continuous: false), inFlight: 0, modelsLost: false),
                       .recording(continuous: false))
        // Even a lost-models failure must not clobber the active recording; its own clip will fail.
        XCTAssertEqual(L.afterClipFinished(.recording(continuous: true), inFlight: 0, modelsLost: true),
                       .recording(continuous: true))
    }

    func testFinishWithModelsLostShowsRetryableError() {
        XCTAssertEqual(L.afterClipFinished(.processing, inFlight: 0, modelsLost: true),
                       .error(L.prepareFailedMessage))
        XCTAssertEqual(L.afterClipFinished(.ready, inFlight: 0, modelsLost: true),
                       .error(L.prepareFailedMessage))
    }

    func testFinishLeavesPreparingAndErrorAlone() {
        XCTAssertEqual(L.afterClipFinished(.preparing("p"), inFlight: 0, modelsLost: false), .preparing("p"))
        XCTAssertEqual(L.afterClipFinished(.error("e"), inFlight: 0, modelsLost: false), .error("e"))
    }

    // MARK: preparation

    func testPreparationSuccessRespectsInFlight() {
        XCTAssertEqual(L.afterPreparation(succeeded: true, inFlight: 0), .ready)
        XCTAssertEqual(L.afterPreparation(succeeded: true, inFlight: 2), .processing)
    }

    func testPreparationFailureIsRetryableError() {
        XCTAssertEqual(L.afterPreparation(succeeded: false, inFlight: 0), .error(L.prepareFailedMessage))
    }

    // MARK: residency (reload after idle unload)

    func testReloadIsShownOnlyWhileIdle() {
        XCTAssertTrue(L.showsReloading(.ready, modelsLoading: true))
        XCTAssertFalse(L.showsReloading(.ready, modelsLoading: false))
        XCTAssertFalse(L.showsReloading(.recording(continuous: false), modelsLoading: true))
        XCTAssertFalse(L.showsReloading(.processing, modelsLoading: true))
    }

    func testFailedReloadWhileIdleBecomesError() {
        XCTAssertEqual(L.afterResidencyEvent(.ready, .failed), .error(L.prepareFailedMessage))
        // Recording/processing: the clip's own prepare() fails and reports through afterClipFinished.
        XCTAssertEqual(L.afterResidencyEvent(.recording(continuous: false), .failed), .recording(continuous: false))
        XCTAssertEqual(L.afterResidencyEvent(.processing, .failed), .processing)
        // prepareModels owns .preparing and reports its own failure.
        XCTAssertEqual(L.afterResidencyEvent(.preparing("p"), .failed), .preparing("p"))
    }

    func testOtherResidencyEventsNeverChangeStatus() {
        for event in [ResidencyEvent.loading, .loaded, .unloaded] {
            for status in [DictationStatus.ready, .processing, .recording(continuous: false), .preparing("p"), .error("e")] {
                XCTAssertEqual(L.afterResidencyEvent(status, event), status)
            }
        }
    }

    // MARK: delayed start feedback

    func testStartFeedbackOnlyForTheSameLiveRecording() {
        XCTAssertTrue(L.shouldAnnounceStart(recording: 3, current: 3, status: .recording(continuous: false)))
        XCTAssertTrue(L.shouldAnnounceStart(recording: 3, current: 3, status: .recording(continuous: true)))
        // Cancelled (⌥ used as a modifier) within the delay.
        XCTAssertFalse(L.shouldAnnounceStart(recording: 3, current: 3, status: .ready))
        XCTAssertFalse(L.shouldAnnounceStart(recording: 3, current: 3, status: .processing))
        // A newer recording replaced it.
        XCTAssertFalse(L.shouldAnnounceStart(recording: 3, current: 4, status: .recording(continuous: false)))
    }
}
