// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoEngines

/// The transcriber's pure helpers (no model is loaded).
final class WhisperKitTranscriberTests: XCTestCase {
    func testAutomaticLetsWhisperDetect() {
        XCTAssertTrue(WhisperKitTranscriber.options(language: nil).detectLanguage)
        XCTAssertNil(WhisperKitTranscriber.options(language: nil).language)
        XCTAssertFalse(WhisperKitTranscriber.options(language: "pt").detectLanguage)
        XCTAssertEqual(WhisperKitTranscriber.options(language: "zh").language, "zh")
    }

    func testDetectedLanguageIsTheMajorityOfWindows() {
        XCTAssertEqual(WhisperKitTranscriber.detectedLanguage(["es", "pt", "es"]), "es")
        XCTAssertEqual(WhisperKitTranscriber.detectedLanguage(["pt", "es"]), "pt", "a tie keeps the first")
        XCTAssertNil(WhisperKitTranscriber.detectedLanguage(["", ""]))
    }

    func testLanguageLogProbabilityBecomesAProbability() {
        XCTAssertEqual(WhisperKitTranscriber.probability(logProb: 0), 1)
        XCTAssertEqual(WhisperKitTranscriber.probability(logProb: log(0.55)), 0.55, accuracy: 1e-6)
        XCTAssertEqual(WhisperKitTranscriber.probability(logProb: -.infinity), 0)
    }
}
