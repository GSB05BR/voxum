// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class TextChunkerTests: XCTestCase {
    private func squeezed(_ s: String) -> String { CJK.removingWhitespace(s) }

    func testSplitsOnSentenceEnds() {
        let text = "One two. Three four. Five six."
        XCTAssertEqual(TextChunker.chunks(text, maxCharacters: 20), ["One two. Three four.", "Five six."])
        XCTAssertEqual(TextChunker.chunks(text, maxCharacters: 12), ["One two.", "Three four.", "Five six."])
        XCTAssertEqual(TextChunker.chunks(text, maxCharacters: 100), [text])
        // ? ! … and a closing quote stay with their sentence; a newline ends a sentence too.
        XCTAssertEqual(TextChunker.chunks("Is it? “Yes!” Fine…\nNext line here", maxCharacters: 14),
                       ["Is it? “Yes!”", "Fine…", "Next line here"])
        // A decimal point or an abbreviation without a following space is not a sentence end.
        XCTAssertEqual(TextChunker.chunks("Version 3.5 is out. Get it", maxCharacters: 20), ["Version 3.5 is out.", "Get it"])
    }

    func testNeverExceedsTheMaximum() {
        let sentence = "Hoje a reunião começou às nove, e a equipe discutiu o orçamento do próximo trimestre. "
        let text = String(repeating: sentence, count: 40) + "Fim."
        for max in [1, 7, 30, 85, 86, 200, 1200] {
            let chunks = TextChunker.chunks(text, maxCharacters: max)
            XCTAssertFalse(chunks.isEmpty)
            for c in chunks {
                XCTAssertLessThanOrEqual(c.count, max, "max \(max)")
                XCTAssertFalse(c.isEmpty)
                XCTAssertEqual(c, c.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            XCTAssertEqual(squeezed(chunks.joined()), squeezed(text), "max \(max)")
        }
        // Whole sentences when they fit: no chunk starts mid-sentence.
        for c in TextChunker.chunks(text, maxCharacters: 200) {
            XCTAssertTrue(c.hasPrefix("Hoje") || c.hasPrefix("Fim"), c)
        }
    }

    func testOneHugeSentenceIsSplitOnSpaces() {
        let words = (1...60).map { "palavra\($0)" }
        let text = words.joined(separator: " ")
        let chunks = TextChunker.chunks(text, maxCharacters: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, 40)
            // Every chunk is made of whole words.
            for w in c.split(separator: " ") { XCTAssertTrue(words.contains(String(w)), String(w)) }
        }
        XCTAssertEqual(chunks.joined(separator: " "), text)
        // A comma is a better place than any space.
        XCTAssertEqual(TextChunker.chunks("aaa bbb ccc, ddd eee fff", maxCharacters: 14), ["aaa bbb ccc,", "ddd eee fff"])
    }

    func testCJKWithoutSpacesIsSplitByCharacters() {
        let text = String(repeating: "我们今天去公园散步然后回家吃饭", count: 10) // no spaces, no punctuation
        let chunks = TextChunker.chunks(text, maxCharacters: 20)
        XCTAssertEqual(chunks.count, 8)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 20) }
        XCTAssertEqual(chunks.joined(), text)
        // CJK sentence and clause marks need no space after them.
        XCTAssertEqual(TextChunker.chunks("今天天气很好。我们去公园吧！好的", maxCharacters: 8),
                       ["今天天气很好。", "我们去公园吧！", "好的"])
        XCTAssertEqual(TextChunker.chunks("我们今天去公园，然后回家吃饭", maxCharacters: 10), ["我们今天去公园，", "然后回家吃饭"])
    }

    func testJoiningGivesBackTheText() {
        let texts = [
            "Primeira frase.  Segunda frase!\n\nTerceira, com vírgula; e mais: fim?",
            "Mixed 中文和English text. 这是第二句。And the third one… done",
            String(repeating: "x", count: 95),
            "  leading and trailing spaces.   ",
            "Emoji 👍🏽 and accents: é, ñ, ç. 👩‍👩‍👧 family.",
        ]
        for text in texts {
            for max in [1, 3, 10, 25, 1000] {
                let chunks = TextChunker.chunks(text, maxCharacters: max)
                XCTAssertEqual(squeezed(chunks.joined()), squeezed(text), "\(text) / \(max)")
                for c in chunks { XCTAssertLessThanOrEqual(c.count, max) }
            }
        }
    }

    func testEmptyText() {
        XCTAssertEqual(TextChunker.chunks("", maxCharacters: 10), [])
        XCTAssertEqual(TextChunker.chunks(" \n\t ", maxCharacters: 10), [])
    }
}
