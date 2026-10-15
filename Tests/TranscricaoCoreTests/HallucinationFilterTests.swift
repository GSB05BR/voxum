// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class HallucinationFilterTests: XCTestCase {
    func testDropsKnownPhantomWholeText() {
        XCTAssertNil(HallucinationFilter.clean("Legendas pela comunidade Amara.org"))
        XCTAssertNil(HallucinationFilter.clean("  Inscreva-se no canal!  "))
        XCTAssertNil(HallucinationFilter.clean(""))
        XCTAssertNil(HallucinationFilter.clean("   "))
    }

    func testRemovesPhantomSentenceButKeepsSpeech() {
        XCTAssertEqual(
            HallucinationFilter.clean("Vou chegar às oito. Legendas pela comunidade Amara.org"),
            "Vou chegar às oito.")
    }

    func testKeepsGenuineThanks() {
        XCTAssertEqual(HallucinationFilter.clean("Obrigado."), "Obrigado.")
        XCTAssertEqual(HallucinationFilter.clean("Obrigada pela ajuda!"), "Obrigada pela ajuda!")
    }

    func testIsAccentAndCaseInsensitive() {
        XCTAssertNil(HallucinationFilter.clean("LEGENDAS PELA COMUNIDADE AMARA.ORG."))
        XCTAssertNil(HallucinationFilter.clean("Obrigado por assistir."))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(HallucinationFilter.clean("  oi tudo bem  "), "oi tudo bem")
    }
}

extension HallucinationFilterTests {
    func testKeepsRealSpeechWithWeakMarker() {
        XCTAssertEqual(HallucinationFilter.clean("Obrigado por assistir à palestra de hoje, pessoal."),
                       "Obrigado por assistir à palestra de hoje, pessoal.")
    }
    func testKeepsWeakMarkerSentenceAfterOtherSpeech() {
        XCTAssertEqual(HallucinationFilter.clean("Foi ótimo. Obrigado por assistir."),
                       "Foi ótimo. Obrigado por assistir.")
    }
}
