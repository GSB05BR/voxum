// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

/// The text model's token cap: Latin-script text keeps exactly the old budget, CJK weighs more.
final class TokenBudgetTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    func testLatinScriptTextKeepsTheOldBudget() {
        let texts = ["manda o arquivo pro Rafael hoje à tarde, ação, coração",
                     "Send the file to Rafael today.",
                     "¿Cuál es la capital? Mañana, señor.",
                     "Est-ce que tu peux m'envoyer « le rapport » avant vendredi ?",
                     "café 😀 — “aspas” e números 1.234,5", ""]
        for text in texts {
            XCTAssertEqual(PromptBuilder.budgetCharacters(text), text.count, text)
            XCTAssertEqual(PromptBuilder.maxTokens(transcript: text, selection: nil),
                           PromptBuilder.maxTokens(forInputCharacters: text.count), text)
            XCTAssertEqual(PromptBuilder.maxTokens(transcript: text, selection: text + text),
                           PromptBuilder.maxTokens(transcriptCharacters: text.count,
                                                   selectionCharacters: (text + text).count), text)
        }
    }

    /// Every Portuguese eval input gets the very same cap as before the CJK weighting.
    func testPortugueseEvalCasesKeepTheirBudget() throws {
        for file in ["cases.json", "holdout.json"] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(file))
            for c in try JSONDecoder().decode([EvalCase].self, from: data) {
                XCTAssertEqual(PromptBuilder.maxTokens(transcript: c.entrada, selection: c.selecionado),
                               PromptBuilder.maxTokens(transcriptCharacters: c.entrada.count,
                                                       selectionCharacters: c.selecionado?.count ?? 0), c.id)
            }
        }
    }

    func testCJKWeighsMore() {
        let han = String(repeating: "我们明天开会", count: 400 / 6) + "我们明天"   // 400 characters
        XCTAssertEqual(han.count, 400)
        XCTAssertEqual(PromptBuilder.budgetCharacters(han), 1200)
        XCTAssertEqual(PromptBuilder.maxTokens(transcript: han, selection: nil), 900,
                       "a 400-character zh dictation was capped at 300 tokens")
        XCTAssertEqual(PromptBuilder.budgetCharacters("你好，世界。"), 18, "full-width marks count as CJK")
        XCTAssertEqual(PromptBuilder.budgetCharacters("ok 好"), 6)
        // zh → en translation of a 650-character selection (was capped at ~490 tokens).
        let selection = String(repeating: "这个项目的预算需要重新评估", count: 50)
        XCTAssertEqual(PromptBuilder.maxTokens(transcript: "翻译成英文", selection: selection),
                       min(2048, (5 + selection.count) * 3 * 3 / 4))
    }
}
