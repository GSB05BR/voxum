// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import XCTest
@testable import TranscricaoCore

final class PromptBuilderTests: XCTestCase {
    func testMessagesShape() {
        let msgs = PromptBuilder.messages(for: "oi tudo bem")
        XCTAssertEqual(msgs.first?.role, .system)
        XCTAssertEqual(msgs.last, ChatTurn(role: .user, content: "<fala>oi tudo bem</fala>"))
        // system + (user, assistant) per example + final user
        XCTAssertEqual(msgs.count, 1 + PromptBuilder.examples.count * 2 + 1)
        for (i, ex) in PromptBuilder.examples.enumerated() {
            XCTAssertEqual(msgs[1 + i * 2], ChatTurn(role: .user, content: "<fala>\(ex.fala)</fala>"))
            XCTAssertEqual(msgs[2 + i * 2], ChatTurn(role: .assistant, content: ex.texto))
        }
    }

    func testIncludesUserExamplesVerbatim() {
        let falas = PromptBuilder.examples.map(\.fala)
        XCTAssertTrue(falas.contains("oi tudo bem como você vai não quis dizer como você está"))
        XCTAssertTrue(falas.contains("crie uma mensagem de parabéns pra mim seja bem curto e casual"))
    }

    func testSystemPromptStatesKeyRules() {
        let p = PromptBuilder.systemPrompt
        XCTAssertTrue(p.contains("SOMENTE com o texto final"))
        XCTAssertTrue(p.contains("Na dúvida, é DITADO"))
        XCTAssertTrue(p.contains("não responda a perguntas"))
    }

    func testMaxTokensBounds() {
        XCTAssertEqual(PromptBuilder.maxTokens(forInputCharacters: 10), 256)
        XCTAssertEqual(PromptBuilder.maxTokens(forInputCharacters: 800), 600)
        XCTAssertEqual(PromptBuilder.maxTokens(forInputCharacters: 10_000), 1024)
    }

    // MARK: selection (edit by voice)

    /// SHA-256 of the plain-dictation turns for "oi" as built before edit-by-voice (e4498a0),
    /// checked by compiling that commit's PromptBuilder. Changing it means the prompt of every plain
    /// dictation changed: re-run the eval (CLAUDE.md) before updating this value.
    static let noSelectionPromptSHA256 = "3728f1a3395ac9797029108e5047cf0dbf1038683dd9a9c0082e27b6257e9957"

    func testNoSelectionPromptIsUnchanged() {
        for msgs in [PromptBuilder.messages(for: "oi", selection: nil), PromptBuilder.messages(for: "oi")] {
            let joined = msgs.map { "\($0.role)\u{1F}\($0.content)" }.joined(separator: "\u{1E}")
            let hex = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, Self.noSelectionPromptSHA256)
            XCTAssertEqual(msgs.count, 20)
            XCTAssertFalse(msgs.contains { $0.content.contains("selecionado") })
        }
    }

    func testSelectionPromptShape() {
        let msgs = PromptBuilder.messages(for: "deixa mais formal", selection: "e aí, blz?")
        XCTAssertEqual(msgs.first?.role, .system)
        XCTAssertTrue(msgs[0].content.hasPrefix(PromptBuilder.systemPrompt))
        XCTAssertTrue(msgs[0].content.hasSuffix(PromptBuilder.selectionRules))
        XCTAssertEqual(msgs.last, ChatTurn(role: .user,
                                           content: "<selecionado>e aí, blz?</selecionado>\n<fala>deixa mais formal</fala>"))
        let exampleCount = PromptBuilder.examples.count + PromptBuilder.selectionExamples.count
        XCTAssertEqual(msgs.count, 1 + exampleCount * 2 + 1)
        // Plain examples first (unchanged), then the selection examples.
        let base = PromptBuilder.examples.count * 2
        for (i, ex) in PromptBuilder.selectionExamples.enumerated() {
            XCTAssertEqual(msgs[1 + base + i * 2].content, "<selecionado>\(ex.selecionado)</selecionado>\n<fala>\(ex.fala)</fala>")
            XCTAssertEqual(msgs[2 + base + i * 2], ChatTurn(role: .assistant, content: ex.texto))
        }
    }

    func testSelectionRulesStateKeyRules() {
        let r = PromptBuilder.selectionRules
        XCTAssertTrue(r.contains("SUBSTITUIR"))
        XCTAssertTrue(r.contains("NUNCA a resposta"))
        XCTAssertTrue(r.contains("Na dúvida, é DITADO"))
        XCTAssertTrue(r.contains("Nunca comente"))
    }

    func testSelectionExamplesAreNotEvalCases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var entries = Set<String>(), selections = Set<String>()
        for name in ["cases.json", "holdout.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent("fixtures/\(name)"))
            for c in try JSONDecoder().decode([EvalCase].self, from: data) {
                entries.insert(c.entrada)
                if let s = c.selecionado { selections.insert(s) }
            }
        }
        for ex in PromptBuilder.selectionExamples {
            XCTAssertFalse(entries.contains(ex.fala))
            XCTAssertFalse(selections.contains(ex.selecionado))
        }
    }

    func testMaxTokensCountsSelection() {
        XCTAssertEqual(PromptBuilder.maxTokens(transcriptCharacters: 800, selectionCharacters: 0),
                       PromptBuilder.maxTokens(forInputCharacters: 800))
        XCTAssertEqual(PromptBuilder.maxTokens(transcriptCharacters: 20, selectionCharacters: 20), 256)
        XCTAssertEqual(PromptBuilder.maxTokens(transcriptCharacters: 100, selectionCharacters: 1500), 1200)
        XCTAssertEqual(PromptBuilder.maxTokens(transcriptCharacters: 30, selectionCharacters: SelectionEdit.maxCharacters), 2048)
    }

    // MARK: read-only selection (answer mode)

    func testAnswerMessagesShape() {
        let msgs = PromptBuilder.answerMessages(for: "traduz", selection: "Hello")
        XCTAssertEqual(msgs.first, ChatTurn(role: .system, content: PromptBuilder.answerSystemPrompt))
        XCTAssertEqual(msgs.count, 1 + PromptBuilder.answerExamples.count * 2 + 1)
        XCTAssertEqual(msgs.last, ChatTurn(role: .user, content: "<selecionado>Hello</selecionado>\n<fala>traduz</fala>"))
        for (i, ex) in PromptBuilder.answerExamples.enumerated() {
            XCTAssertEqual(msgs[1 + i * 2].content, "<selecionado>\(ex.selecionado)</selecionado>\n<fala>\(ex.fala)</fala>")
            XCTAssertEqual(msgs[2 + i * 2], ChatTurn(role: .assistant, content: ex.texto))
        }
    }

    func testAnswerPromptRules() {
        let p = PromptBuilder.answerSystemPrompt
        XCTAssertTrue(p.contains("português do Brasil"))
        XCTAssertTrue(p.contains("não invente"))
        XCTAssertTrue(p.contains("conhecimento geral"))
        // Transform requests get only the transformed text; explaining needs a request for it.
        XCTAssertTrue(p.contains("devolva SOMENTE o texto transformado"))
        XCTAssertTrue(p.contains("pedir uma explicação"))
        XCTAssertFalse(PromptBuilder.systemPrompt.contains("assistente"), "the dictation prompt is untouched")
    }

    func testAnswerExamplesAreNotEvalCases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var entries = Set<String>(), selections = Set<String>()
        for name in ["cases.json", "holdout.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent("fixtures/\(name)"))
            for c in try JSONDecoder().decode([EvalCase].self, from: data) {
                entries.insert(c.entrada)
                if let s = c.selecionado { selections.insert(s) }
            }
        }
        for ex in PromptBuilder.answerExamples {
            XCTAssertFalse(entries.contains(ex.fala))
            XCTAssertFalse(selections.contains(ex.selecionado))
        }
    }
}
