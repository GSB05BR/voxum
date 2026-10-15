// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class TimeoutTests: XCTestCase {
    func testReturnsValueWhenOperationWins() async throws {
        let v = try await withTimeout(seconds: 2) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testPropagatesOperationError() async {
        do {
            _ = try await withTimeout(seconds: 2) { () async throws -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom, "got \(error)")
        }
    }

    func testTimerWinsWhenOperationIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await withTimeout(seconds: 0.1) { () async throws -> Int in
                Thread.sleep(forTimeInterval: 1.0) // blocks; ignores cancellation
                return 1
            }
            XCTFail("expected TimeoutError")
        } catch {
            XCTAssertTrue(error is TimeoutError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testNegativeSecondsTimesOutPromptly() async {
        let start = Date()
        do {
            _ = try await withTimeout(seconds: -1) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 500_000_000)
                return 1
            }
            XCTFail("expected TimeoutError")
        } catch {
            XCTAssertTrue(error is TimeoutError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
    }
}
