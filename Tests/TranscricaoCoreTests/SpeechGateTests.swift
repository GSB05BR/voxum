// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class SpeechGateTests: XCTestCase {
    let gate = SpeechGate()

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func testRejectsTooShort() {
        XCTAssertFalse(gate.shouldTranscribe(tone(seconds: 0.3, amplitude: 0.3)))
    }

    func testRejectsSilence() {
        XCTAssertFalse(gate.shouldTranscribe([Float](repeating: 0.001, count: 32_000)))
    }

    func testAcceptsSpeechLikeSignal() {
        XCTAssertTrue(gate.shouldTranscribe(tone(seconds: 1.0, amplitude: 0.1)))
    }

    func testLongClipWithShortSpeechPasses() {
        // 20 s of near-silence with 0.5 s of speech in the middle.
        var s = [Float](repeating: 0.0005, count: 20 * 16_000)
        let speech = tone(seconds: 0.5, amplitude: 0.08)
        s.replaceSubrange(160_000..<(160_000 + speech.count), with: speech)
        XCTAssertTrue(gate.shouldTranscribe(s))
    }

    func testEmptyInput() {
        XCTAssertFalse(gate.shouldTranscribe([]))
        XCTAssertEqual(SpeechGate.peakWindowRMS([], windowSize: 1600), 0)
    }
}
