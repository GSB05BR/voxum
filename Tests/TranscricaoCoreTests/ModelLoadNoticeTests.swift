// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class ModelLoadNoticeTests: XCTestCase {
    func testQuietWhileTheLoadIsShort() {
        XCTAssertNil(ModelLoadNotice.message(elapsed: 0, knownFirstLoad: false))
        XCTAssertNil(ModelLoadNotice.message(elapsed: 14.9, knownFirstLoad: false))
    }

    func testExplainsTheWaitOnceTheLoadIsSlow() {
        XCTAssertEqual(ModelLoadNotice.message(elapsed: 15, knownFirstLoad: false),
                       "Preparing the models for this Mac (usually only the first time; up to 3 minutes)… 0:15")
        XCTAssertEqual(ModelLoadNotice.message(elapsed: 65.7, knownFirstLoad: false),
                       "Preparing the models for this Mac (usually only the first time; up to 3 minutes)… 1:05")
    }

    func testAKnownFirstLoadExplainsTheWaitFromTheStart() {
        XCTAssertEqual(ModelLoadNotice.message(elapsed: 0, knownFirstLoad: true),
                       "Preparing the models for this Mac (usually only the first time; up to 3 minutes)… 0:00")
    }

    func testPastTheEstimateItStopsPromisingATime() {
        XCTAssertEqual(ModelLoadNotice.message(elapsed: 180, knownFirstLoad: false),
                       "Still preparing the models for this Mac… 3:00")
        XCTAssertEqual(ModelLoadNotice.message(elapsed: 601, knownFirstLoad: true),
                       "Still preparing the models for this Mac… 10:01")
    }

    func testClock() {
        XCTAssertEqual(ModelLoadNotice.clock(0), "0:00")
        XCTAssertEqual(ModelLoadNotice.clock(9.99), "0:09")
        XCTAssertEqual(ModelLoadNotice.clock(119), "1:59")
        XCTAssertEqual(ModelLoadNotice.clock(-3), "0:00") // a clock change never shows a negative time
        XCTAssertEqual(ModelLoadNotice.clock(.infinity), "0:00")
    }
}
