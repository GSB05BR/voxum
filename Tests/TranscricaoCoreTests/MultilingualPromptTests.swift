// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class MultilingualPromptTests: XCTestCase {
    // MARK: Routing: Portuguese keeps its prompt, byte for byte

    func testPortugueseRoutesToTheExistingPrompt() {
        for code in ["pt", "pt-BR", "PT_br"] {
            XCTAssertEqual(PromptBuilder.messages(for: "oi", language: code), PromptBuilder.messages(for: "oi"))
            XCTAssertEqual(PromptBuilder.messages(for: "oi", selection: nil, language: code),
                           PromptBuilder.messages(for: "oi", selection: nil))
            XCTAssertEqual(PromptBuilder.messages(for: "deixa formal", selection: "e aí", language: code),
                           PromptBuilder.messages(for: "deixa formal", selection: "e aí"))
            XCTAssertEqual(PromptBuilder.answerMessages(for: "traduz", selection: "Hello", language: code),
                           PromptBuilder.answerMessages(for: "traduz", selection: "Hello"))
        }
    }

    func testOtherLanguagesUseTheMultilingualPrompt() {
        for code in ["en", "es", "fr", "zh", "zh-Hans", "de", ""] {
            let msgs = PromptBuilder.messages(for: "hello", language: code)
            XCTAssertEqual(msgs, MultilingualPrompt.messages(for: "hello", selection: nil, language: code))
            XCTAssertEqual(msgs.first?.content, MultilingualPrompt.dictationRules(language: code))
            XCTAssertEqual(msgs.last, ChatTurn(role: .user, content: "<speech>hello</speech>"))
            XCTAssertFalse(msgs.contains { $0.content.contains("<fala>") || $0.content.contains("português") })
            let answer = PromptBuilder.answerMessages(for: "translate", selection: "Olá", language: code)
            XCTAssertEqual(answer.first?.content, MultilingualPrompt.answerRules(language: code))
            XCTAssertEqual(answer.last, ChatTurn(role: .user, content: "<selected>Olá</selected>\n<speech>translate</speech>"))
        }
    }

    func testSelectionAddsTheEditRules() {
        let msgs = PromptBuilder.messages(for: "make it formal", selection: "hey", language: "en")
        XCTAssertEqual(msgs.first?.content,
                       MultilingualPrompt.dictationRules(language: "en") + "\n\n" + MultilingualPrompt.selectionRules(language: "en"))
        XCTAssertEqual(msgs.last?.content, "<selected>hey</selected>\n<speech>make it formal</speech>")
        XCTAssertFalse(PromptBuilder.messages(for: "x", language: "en")[0].content.contains("<selected>"))
    }

    // MARK: Examples

    func testRegistryFallsBackToEnglish() {
        func flat(_ e: LanguageExamples) -> [String] {
            e.dictation.flatMap { [$0.input, $0.output] } + e.edit.flatMap { [$0.selected, $0.speech, $0.output] }
                + e.answer.flatMap { [$0.selected, $0.speech, $0.output] }
        }
        XCTAssertEqual(flat(MultilingualPrompt.examples(for: "xx")), flat(.en))
        XCTAssertEqual(flat(MultilingualPrompt.examples(for: "")), flat(.en))
        XCTAssertEqual(flat(MultilingualPrompt.examples(for: "zh-Hans")), flat(.zh))
        XCTAssertEqual(flat(MultilingualPrompt.examples(for: "es")), flat(.es))
        XCTAssertEqual(flat(MultilingualPrompt.examples(for: "fr-CA")), flat(.fr))
    }

    func testExamplesBecomeTurnsInOrder() {
        let ex = LanguageExamples(dictation: [("uh hi", "Hi.")],
                                  edit: [("hey", "make it formal", "Hello.")],
                                  answer: [("Hola", "what does it say", "Hello.")])
        let msgs = MultilingualPrompt.messages(for: "x", selection: "s", language: "en", examples: ex)
        XCTAssertEqual(msgs.map(\.content).dropFirst().dropLast(),
                       ["<speech>uh hi</speech>", "Hi.", "<selected>hey</selected>\n<speech>make it formal</speech>", "Hello."])
        let plain = MultilingualPrompt.messages(for: "x", selection: nil, language: "en", examples: ex)
        XCTAssertEqual(plain.count, 1 + 2 + 1, "edit examples only with a selection")
        let answer = MultilingualPrompt.answerMessages(for: "x", selection: "s", language: "en", examples: ex)
        XCTAssertEqual(answer.map(\.content).dropFirst().dropLast(),
                       ["<selected>Hola</selected>\n<speech>what does it say</speech>", "Hello."])
    }

    /// A detected language without examples gets the rules alone (English examples would pull it
    /// towards English).
    func testUnknownLanguageGetsNoExamples() {
        XCTAssertEqual(PromptBuilder.messages(for: "hallo", language: "de").count, 2)
        XCTAssertEqual(PromptBuilder.messages(for: "hallo", selection: "x", language: "de").count, 2)
        XCTAssertEqual(PromptBuilder.answerMessages(for: "hallo", selection: "x", language: "de").count, 2)
        XCTAssertEqual(MultilingualPrompt.promptExamples(for: "de").dictation.count, 0)
    }

    /// A wrong language label (Automatic on a short clip) must not make the model translate: the
    /// rules never name the language, only the examples differ.
    func testRulesNeverNameTheLanguage() {
        for name in ["English", "Spanish", "French", "German", "Portuguese"] {
            for code in ["en", "es", "fr", "de", ""] {
                XCTAssertFalse(MultilingualPrompt.dictationRules(language: code).contains(name), "\(code): \(name)")
                if name != "English" { // "translate it into English" is an example instruction
                    XCTAssertFalse(MultilingualPrompt.selectionRules(language: code).contains(name), "\(code): \(name)")
                }
            }
        }
        XCTAssertEqual(MultilingualPrompt.dictationRules(language: "es"), MultilingualPrompt.dictationRules(language: "de"))
    }

    /// The answer rules name one language only: where "translate" with no language goes when the
    /// text is already in the request's language.
    func testAnswerRulesNameOnlyTheTranslationFallback() {
        for code in ["en", "es", "fr", "zh", "de", ""] {
            let rules = MultilingualPrompt.answerRules(language: code)
            let fallback = code == "en" ? "translate it into Spanish)" : "translate it into English)"
            XCTAssertEqual(rules.components(separatedBy: fallback).count, 2, code)
            let rest = rules.replacingOccurrences(of: fallback, with: "")
            for name in ["English", "Spanish", "French", "German", "Portuguese", "Chinese"] {
                XCTAssertFalse(rest.contains(name), "\(code): \(name)")
            }
        }
    }

    // MARK: The rules carry the Portuguese prompt's behaviour

    func testDictationRulesStateKeyRules() {
        let r = MultilingualPrompt.dictationRules(language: "es")
        XCTAssertTrue(MultilingualPrompt.dictationRules(language: "zh-Hans").contains("Simplified characters"))
        XCTAssertFalse(r.contains("Chinese"))
        for needle in ["same language as the transcript", "Never translate", "keep only the corrected version", "filler words",
                       "punctuation", "\"new line\"", "\"new paragraph\"", "numbered list", "NEVER answered",
                       "COMMAND mode", "When in doubt, it is DICTATION", "Reply ONLY with the final text"] {
            XCTAssertTrue(r.contains(needle), needle)
        }
    }

    func testSelectionAndAnswerRulesStateKeyRules() {
        let s = MultilingualPrompt.selectionRules(language: "fr")
        for needle in ["REPLACE", "INSTRUCTION", "NEVER the answer", "When in doubt, it is DICTATION", "Never comment"] {
            XCTAssertTrue(s.contains(needle), needle)
        }
        let a = MultilingualPrompt.answerRules(language: "fr")
        for needle in ["return ONLY the transformed text", "asks for an explanation", "do not make anything up",
                       "general knowledge", "language of the spoken request"] {
            XCTAssertTrue(a.contains(needle), needle)
        }
    }

    func testBaseCode() {
        XCTAssertEqual(MultilingualPrompt.baseCode("zh-Hans"), "zh")
        XCTAssertEqual(MultilingualPrompt.baseCode("pt_BR"), "pt")
        XCTAssertEqual(MultilingualPrompt.baseCode("EN"), "en")
        XCTAssertEqual(MultilingualPrompt.baseCode(""), "")
    }
}

/// Like the Portuguese examples (PromptBuilderTests): a language's few-shot examples never copy
/// its eval inputs, or the eval would measure memorization.
final class LanguageExamplesAreNotEvalCasesTests: XCTestCase {
    func testExamplesDoNotCopyTheEvalCases() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        let files = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
        for code in MultilingualPrompt.exampleCodes {
            let ex = MultilingualPrompt.examples(for: code)
            let inputs = Set(ex.dictation.map(\.input) + ex.edit.map(\.speech) + ex.answer.map(\.speech))
            let selections = Set(ex.edit.map(\.selected) + ex.answer.map(\.selected))
            // cases-zh-Hans.json belongs to code "zh".
            // Plus the mislabel cases, which run on every language's examples.
            let mine = files.filter { name in
                name == "cases-mislabel.json" || (name.hasPrefix("cases-") || name.hasPrefix("holdout-")) && name.hasSuffix(".json")
                    && MultilingualPrompt.baseCode(String(name.drop { $0 != "-" }.dropFirst().dropLast(5))) == code
            }
            for name in mine {
                let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
                for c in cases {
                    XCTAssertFalse(inputs.contains(c.entrada), "\(code) example copies \(name) [\(c.id)]")
                    if let s = c.selecionado { XCTAssertFalse(selections.contains(s), "\(code) example copies \(name) [\(c.id)]") }
                }
            }
        }
    }
}
