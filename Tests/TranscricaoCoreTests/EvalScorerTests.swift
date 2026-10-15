// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class EvalScorerTests: XCTestCase {
    let c = EvalCase(id: "x", entrada: "e", modo: "ditado", esperado: nil,
                     deveConter: ["Como você está"], naoDeveConter: ["vai"], maxCaracteres: 40)

    func testPasses() {
        XCTAssertEqual(EvalScorer.failures(output: "Oi, tudo bem? Como VOCÊ está?", for: c), [])
    }
    func testReportsEachFailure() {
        let f = EvalScorer.failures(output: "**Como você vai?** " + String(repeating: "a", count: 40), for: c)
        XCTAssertEqual(f.count, 4) // missing, forbidden, too long, markdown
    }
    func testIsAccentInsensitive() {
        XCTAssertEqual(EvalScorer.failures(output: "como voce esta", for: c), [])
    }

    func testFlagsLeakedSelectionTag() {
        XCTAssertEqual(EvalScorer.failures(output: "<selecionado>Como você está", for: c), ["formatação indevida"])
    }
    func testDecodesOptionalSelection() throws {
        let json = #"[{"id":"a","entrada":"e","modo":"ditado"},{"id":"b","entrada":"e","modo":"edicao","selecionado":"oi"},{"id":"c","entrada":"e","modo":"pergunta-selecao","selecionado":"oi","selecionadoSomenteLeitura":true}]"#
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
        XCTAssertNil(cases[0].selecionado)
        XCTAssertEqual(cases[1].selecionado, "oi")
        XCTAssertNil(cases[1].selecionadoSomenteLeitura)
        XCTAssertEqual(cases[2].selecionadoSomenteLeitura, true)
    }
    func testFixturesDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["cases.json", "holdout.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent("fixtures/\(name)"))
            let cases = try JSONDecoder().decode([EvalCase].self, from: data)
            XCTAssertFalse(cases.isEmpty)
            XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "duplicate ids in \(name)")
        }
    }
}

final class EvalScorerLanguageTests: XCTestCase {
    func testDecodesTheLanguageField() throws {
        let json = #"[{"id":"a","entrada":"e","modo":"ditado","lang":"zh"},{"id":"b","entrada":"e","modo":"ditado"}]"#
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
        XCTAssertEqual(cases[0].lang, "zh")
        XCTAssertNil(cases[1].lang)
    }

    func testCJKNeedlesIgnoreSpacesAndWidth() {
        let c = EvalCase(id: "zh", entrada: "e", modo: "ditado", esperado: nil,
                         deveConter: ["明天开会", "?"], naoDeveConter: ["下午三点"], maxCaracteres: 20, lang: "zh")
        XCTAssertEqual(EvalScorer.failures(output: "我们明天 开会吗？", for: c), [])
        XCTAssertEqual(EvalScorer.failures(output: "我们明天开会吗。", for: c), ["faltou \"?\""])
        XCTAssertEqual(EvalScorer.failures(output: "明天开会，下午 三点？", for: c), ["não devia conter \"下午三点\""])
        // Length counts characters, not bytes.
        XCTAssertEqual(EvalScorer.failures(output: String(repeating: "会", count: 21) + "明天开会？", for: c).count, 1)
    }

    func testExpectedChineseNeedsFullWidthPunctuation() {
        let c = EvalCase(id: "zh", entrada: "e", modo: "ditado", esperado: "明天开会吗？",
                         deveConter: ["明天开会", "?"], naoDeveConter: nil, maxCaracteres: nil, lang: "zh")
        XCTAssertEqual(EvalScorer.failures(output: "明天开会吗？", for: c), [])
        XCTAssertEqual(EvalScorer.failures(output: "明天开会吗?", for: c), ["pontuação de meia largura"])
        XCTAssertEqual(EvalScorer.failures(output: "明天开会, 好吗？", for: c), ["pontuação de meia largura"])
        XCTAssertEqual(EvalScorer.failures(output: "明天3,000元？", for: c).count, 1, "only the missing needle")
        // Not checked when the expected text is not CJK (a Latin output keeps its own punctuation).
        let en = EvalCase(id: "en", entrada: "e", modo: "ditado", esperado: "Are we meeting tomorrow?",
                          deveConter: nil, naoDeveConter: nil, maxCaracteres: nil, lang: "en")
        XCTAssertEqual(EvalScorer.failures(output: "明天开会吗?", for: en), [])
        // A zh case with no expected text (commands, summaries) is checked too; an English output is not.
        let zh = EvalCase(id: "zh", entrada: "e", modo: "comando", esperado: nil,
                          deveConter: nil, naoDeveConter: nil, maxCaracteres: nil, lang: "zh")
        XCTAssertEqual(EvalScorer.failures(output: "好的, 明天见", for: zh), ["pontuação de meia largura"])
        XCTAssertEqual(EvalScorer.failures(output: "OK, see you tomorrow.", for: zh), [])
    }

    func testCJKNeedlesKeepTheirLineBreaks() {
        let c = EvalCase(id: "zh", entrada: "e", modo: "ditado", esperado: "各位同事：\n明天开会。",
                         deveConter: nil, naoDeveConter: ["\n\n明天"], maxCaracteres: nil, lang: "zh")
        XCTAssertEqual(EvalScorer.failures(output: "各位同事：\n明天 开会。", for: c), [])
        XCTAssertEqual(EvalScorer.failures(output: "各位同事：\n\n明天开会。", for: c), ["não devia conter \"\n\n明天\""])
    }

    func testLatinNeedlesStillNeedTheirSpaces() {
        let c = EvalCase(id: "en", entrada: "e", modo: "ditado", esperado: nil,
                         deveConter: ["new york"], naoDeveConter: nil, maxCaracteres: nil, lang: "en")
        XCTAssertEqual(EvalScorer.failures(output: "I live in New York.", for: c), [])
        XCTAssertEqual(EvalScorer.failures(output: "I live in Newyork.", for: c), ["faltou \"new york\""])
    }

    func testFlagsLeakedMultilingualTags() {
        let c = EvalCase(id: "x", entrada: "e", modo: "ditado", esperado: nil,
                         deveConter: nil, naoDeveConter: nil, maxCaracteres: nil)
        XCTAssertEqual(EvalScorer.failures(output: "<speech>Hi", for: c), ["formatação indevida"])
        XCTAssertEqual(EvalScorer.failures(output: "<selected>Hi", for: c), ["formatação indevida"])
    }

    func testLanguageFixturesDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("fixtures")
        let files = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { ($0.hasPrefix("cases-") || $0.hasPrefix("holdout-")) && $0.hasSuffix(".json") }
        XCTAssertTrue(files.contains("cases-en.json"))
        for name in files {
            let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
            XCTAssertFalse(cases.isEmpty, name)
            XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "duplicate ids in \(name)")
            XCTAssertTrue(cases.allSatisfy { $0.lang != nil }, "every case of \(name) names its language")
        }
    }
}
