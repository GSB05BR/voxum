// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

/// Whisper silence phrases and model labels in en, es, fr and zh (pt: HallucinationFilterTests,
/// OutputSanitizerTests, unchanged).
final class MultilingualHallucinationTests: XCTestCase {
    func testDropsSilencePhrases() {
        for phantom in ["Thank you for watching.", "Thanks for watching!", "Please subscribe.", "you", "You.",
                        "Subtitles by the Amara.org community",
                        "Gracias por ver el video.", "¡Suscríbete!",
                        "Subtítulos realizados por la comunidad de Amara.org",
                        "Subtítulos por la comunidad de Amara.org",
                        "Merci d'avoir regardé.", "Merci d’avoir regardé !", "Abonnez-vous !",
                        "Sous-titres réalisés par la communauté d'Amara.org",
                        "Sous-titrage Société Radio-Canada",
                        "谢谢观看", "感谢观看！", "字幕由Amara.org社区提供",
                        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
                        "优优独播剧场——YoYo Television Series Exclusive"] {
            XCTAssertNil(HallucinationFilter.clean(phantom), phantom)
        }
    }

    func testKeepsRealSpeechWithWeakPhrases() {
        for speech in ["Thank you for watching the kids yesterday.", "Thank you.", "Did you call?",
                       "Gracias por ver el informe tan rápido.", "Merci d'avoir regardé mon dossier.",
                       "谢谢观看我们的演示，下周见。", "Please subscribe me to the newsletter."] {
            XCTAssertEqual(HallucinationFilter.clean(speech), speech)
        }
    }

    func testRemovesAPhantomSentenceAndKeepsTheSpeech() {
        XCTAssertEqual(HallucinationFilter.clean("I'll be there at eight. Subtitles by the Amara.org community"),
                       "I'll be there at eight.")
        XCTAssertEqual(HallucinationFilter.clean("Nos vemos mañana. Sous-titrage Société Radio-Canada"),
                       "Nos vemos mañana.")
        XCTAssertEqual(HallucinationFilter.clean("我们明天开会。字幕由Amara.org社区提供"), "我们明天开会。")
        XCTAssertEqual(HallucinationFilter.clean("我们明天开会。请准时到。"), "我们明天开会。请准时到。",
                       "Chinese sentences are joined back without spaces")
        XCTAssertEqual(HallucinationFilter.clean("你好。 字幕由Amara.org社区提供。 明天见。"), "你好。明天见。")
    }

    func testPortugueseIsUnchanged() {
        XCTAssertNil(HallucinationFilter.clean("Obrigado por assistir."))
        XCTAssertEqual(HallucinationFilter.clean("Foi ótimo. Obrigado por assistir."), "Foi ótimo. Obrigado por assistir.")
        XCTAssertEqual(HallucinationFilter.clean("Vou chegar às oito.   Legendas pela comunidade Amara.org"),
                       "Vou chegar às oito.")
        XCTAssertEqual(HallucinationFilter.clean("Um.  Dois!\nTrês?"), "Um. Dois! Três?")
    }
}

final class MultilingualSanitizerTests: XCTestCase {
    func testDropsLabels() {
        let cases: [(String, String)] = [
            ("Final text: Send it today.", "Send it today."),
            ("Revised text:\nSend it today.", "Send it today."),
            ("Output:\nSend it today.", "Send it today."),
            ("Answer:\nIt says forty.", "It says forty."),
            ("Texto revisado: Envíalo hoy.", "Envíalo hoy."),
            ("Salida:\nEnvíalo hoy.", "Envíalo hoy."),
            ("Respuesta:\nDice cuarenta.", "Dice cuarenta."),
            ("Texte final : Envoie-le aujourd'hui.", "Envoie-le aujourd'hui."),
            ("Texte révisé\u{00A0}: Envoie-le aujourd'hui.", "Envoie-le aujourd'hui."),
            ("Sortie :\nEnvoie-le aujourd'hui.", "Envoie-le aujourd'hui."),
            ("Réponse :\nIl dit quarante.", "Il dit quarante."),
            ("最终文本：今天发给他。", "今天发给他。"),
            ("修改后：今天发给他。", "今天发给他。"),
            ("输出：\n今天发给他。", "今天发给他。"),
            ("回答：\n上面写着四十。", "上面写着四十。"),
        ]
        for (raw, clean) in cases { XCTAssertEqual(OutputSanitizer.clean(raw), clean, raw) }
    }

    func testKeepsDictatedLabels() {
        for text in ["Answer: yes, I confirm.", "Respuesta: sí, confirmo.", "Réponse : oui, je confirme.",
                     "回答：是的，我确认。", "Output: 40 units per day."] {
            XCTAssertEqual(OutputSanitizer.clean(text), text)
        }
    }

    func testUnwrapsQuotes() {
        XCTAssertEqual(OutputSanitizer.clean("「今天发给他。」"), "今天发给他。")
        XCTAssertEqual(OutputSanitizer.clean("『今天发给他。』"), "今天发给他。")
        XCTAssertEqual(OutputSanitizer.clean("«\u{00A0}Envoie-le aujourd'hui.\u{00A0}»"), "Envoie-le aujourd'hui.")
        XCTAssertEqual(OutputSanitizer.clean("«\u{202F}Envoie-le.\u{202F}»"), "Envoie-le.")
        XCTAssertEqual(OutputSanitizer.clean("「A」和「B」"), "「A」和「B」", "two quotes are not a wrapper")
    }

    func testPortugueseIsUnchanged() {
        XCTAssertEqual(OutputSanitizer.clean("Resposta: sim, confirmo."), "Resposta: sim, confirmo.")
        XCTAssertEqual(OutputSanitizer.clean("Texto final: Manda hoje."), "Manda hoje.")
        XCTAssertEqual(OutputSanitizer.clean("Resposta:\nManda hoje."), "Manda hoje.")
        XCTAssertEqual(OutputSanitizer.clean("Texto: o contrato vence amanhã."), "Texto: o contrato vence amanhã.")
    }
}
