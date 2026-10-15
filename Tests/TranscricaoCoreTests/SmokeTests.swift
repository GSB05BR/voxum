// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(TranscricaoCore.version, "0.1.0")
    }
}
