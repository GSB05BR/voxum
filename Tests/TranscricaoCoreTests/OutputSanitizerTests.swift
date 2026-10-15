// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class OutputSanitizerTests: XCTestCase {
    func testPlainTextUnchanged() {
        XCTAssertEqual(OutputSanitizer.clean("Oi, tudo bem? Como você está?"), "Oi, tudo bem? Como você está?")
    }
    func testRemovesThinkBlocks() {
        XCTAssertEqual(OutputSanitizer.clean("<think>hmm</think>\nOi!"), "Oi!")
        XCTAssertEqual(OutputSanitizer.clean("<think>never closed"), "")
    }
    func testRemovesLabels() {
        XCTAssertEqual(OutputSanitizer.clean("Texto final: Bom dia."), "Bom dia.")
        XCTAssertEqual(OutputSanitizer.clean("Resposta:\nBom dia."), "Bom dia.")
    }
    func testKeepsDictatedLabelWords() {
        XCTAssertEqual(OutputSanitizer.clean("Resposta: sim, confirmo."), "Resposta: sim, confirmo.")
        XCTAssertEqual(OutputSanitizer.clean("Texto final: Bom dia."), "Bom dia.")
        XCTAssertEqual(OutputSanitizer.clean("Texto revisado: Bom dia."), "Bom dia.")
    }
    func testKeepsDunderAndLeadingGreaterThan() {
        XCTAssertEqual(OutputSanitizer.clean("use __init__ aqui"), "use __init__ aqui")
        XCTAssertEqual(OutputSanitizer.clean("> citação"), "> citação")
    }
    func testRemovesMarkdown() {
        XCTAssertEqual(OutputSanitizer.clean("**Parabéns!** Tudo de bom."), "Parabéns! Tudo de bom.")
        XCTAssertEqual(OutputSanitizer.clean("## Assunto\nOlá"), "Assunto\nOlá")
    }
    func testStripsWrappingQuotes() {
        XCTAssertEqual(OutputSanitizer.clean("\"Bom dia.\""), "Bom dia.")
        XCTAssertEqual(OutputSanitizer.clean("“Bom dia.”"), "Bom dia.")
        // Inner quotes mean the quotes are content, keep them.
        XCTAssertEqual(OutputSanitizer.clean("\"Oi\", disse ele, \"tudo bem\""), "\"Oi\", disse ele, \"tudo bem\"")
    }
    func testRemovesEchoedTags() {
        XCTAssertEqual(OutputSanitizer.clean("<fala>Oi.</fala>"), "Oi.")
        XCTAssertEqual(OutputSanitizer.clean("<selecionado>Oi.</selecionado>"), "Oi.")
        // Tags of the multilingual prompt.
        XCTAssertEqual(OutputSanitizer.clean("<speech>Hi.</speech>"), "Hi.")
        XCTAssertEqual(OutputSanitizer.clean("<selected>Hi.</selected>"), "Hi.")
    }

    func testTrailingSpacesAtLineEndsAreRemoved() {
        XCTAssertEqual(OutputSanitizer.clean("Lista de compras:  \n1. Tomate  \n2. Arroz"),
                       "Lista de compras:\n1. Tomate\n2. Arroz")
    }
}
