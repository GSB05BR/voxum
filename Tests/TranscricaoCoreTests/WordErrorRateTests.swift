// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class WordErrorRateTests: XCTestCase {
    /// Chinese has no spaces: each character is a token (character error rate).
    func testCJKIsScoredPerCharacter() {
        XCTAssertEqual(WordErrorRate.words("我们明天开会。", ignoreAccents: false), ["我", "们", "明", "天", "开", "会"])
        XCTAssertEqual(WordErrorRate.words("用 iPhone 拍照", ignoreAccents: false), ["用", "iphone", "拍", "照"])
        let r = WordErrorRate.compute(reference: "我们明天开会", hypothesis: "我们后天开会")
        XCTAssertEqual(r.edits, 1)
        XCTAssertEqual(r.referenceWords, 6)
        XCTAssertEqual(WordErrorRate.compute(reference: "明天开会", hypothesis: "明天 开会").edits, 0)
    }

    func testIdenticalIsZero() {
        XCTAssertEqual(WordErrorRate.compute(reference: "Oi, tudo bem?", hypothesis: "oi tudo bem").edits, 0)
    }
    func testSubstitutionInsertionDeletion() {
        let r = WordErrorRate.compute(reference: "a b c d", hypothesis: "a x c d e")
        XCTAssertEqual(r.edits, 2) // b→x, +e
        XCTAssertEqual(r.referenceWords, 4)
        XCTAssertEqual(r.rate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(WordErrorRate.compute(reference: "a b c", hypothesis: "a c").edits, 1)
    }
    func testAccentSensitivity() {
        XCTAssertEqual(WordErrorRate.compute(reference: "ação rápida", hypothesis: "acao rapida").edits, 2)
        XCTAssertEqual(WordErrorRate.compute(reference: "ação rápida", hypothesis: "acao rapida", ignoreAccents: true).edits, 0)
    }
    func testPunctuationAndCaseIgnored() {
        XCTAssertEqual(WordErrorRate.compute(reference: "Itaú, São Paulo.", hypothesis: "itaú são paulo").edits, 0)
    }
    func testNumberSeparatorKeepsOneToken() {
        XCTAssertEqual(WordErrorRate.words("R$ 1.250,50", ignoreAccents: false), ["r", "125050"])
    }
    func testBestAlternativeWins() {
        let r = WordErrorRate.compute(references: ["pagar mil reais", "pagar 1000 reais"], hypothesis: "Pagar 1000 reais.")
        XCTAssertEqual(r.edits, 0)
    }
    func testEmptyReference() {
        XCTAssertEqual(WordErrorRate.compute(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(WordErrorRate.compute(reference: "", hypothesis: "x").rate, 1)
    }
    func testAggregateIsWeightedByWords() {
        let a = WordErrorRate.Result(edits: 1, referenceWords: 2)
        let b = WordErrorRate.Result(edits: 1, referenceWords: 8)
        XCTAssertEqual(WordErrorRate.aggregate([a, b]).rate, 0.2, accuracy: 1e-9)
    }
}
