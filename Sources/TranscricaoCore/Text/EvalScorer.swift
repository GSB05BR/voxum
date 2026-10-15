// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One prompt-eval case (fixtures/cases.json, fixtures/cases-<code>.json). Field names are
/// Portuguese to keep the original fixture file readable.
public struct EvalCase: Codable, Sendable {
    public var id: String
    public var entrada: String
    public var modo: String
    public var esperado: String?
    public var deveConter: [String]?
    public var naoDeveConter: [String]?
    public var maxCaracteres: Int?
    /// Text selected on screen when the speech was dictated (edit-by-voice cases); nil = plain dictation.
    public var selecionado: String?
    /// The selection is read-only (web page, tweet, PDF…): the speech is a request about it and
    /// the answer goes to a panel (assistant prompt), never pasted.
    public var selecionadoSomenteLeitura: Bool?
    /// Dictation language of the case (Whisper code, e.g. "en", "zh"); nil = the file's
    /// language (`tcli eval --lang`, Portuguese by default).
    public var lang: String?
    /// Simulates Automatic: `lang` is what Whisper detected, with this probability, and the prompt
    /// language comes from `DictationLanguage.promptLanguage` (as in the app); nil = `lang` is chosen.
    public var langConfidence: Double?

    public init(id: String, entrada: String, modo: String, esperado: String?,
                deveConter: [String]?, naoDeveConter: [String]?, maxCaracteres: Int?,
                selecionado: String? = nil, selecionadoSomenteLeitura: Bool? = nil, lang: String? = nil,
                langConfidence: Double? = nil) {
        self.id = id; self.entrada = entrada; self.modo = modo; self.esperado = esperado
        self.deveConter = deveConter; self.naoDeveConter = naoDeveConter; self.maxCaracteres = maxCaracteres
        self.selecionado = selecionado
        self.selecionadoSomenteLeitura = selecionadoSomenteLeitura
        self.lang = lang
        self.langConfidence = langConfidence
    }
}

public enum EvalScorer {
    /// Empty array = pass. Comparisons ignore case, accents and character width (full-width "？"
    /// matches "?"). CJK text is compared character by character: spaces are ignored around it.
    public static func failures(output: String, for c: EvalCase) -> [String] {
        var out: [String] = []
        for needle in c.deveConter ?? [] where !contains(output, needle) {
            out.append("faltou \"\(needle)\"")
        }
        for needle in c.naoDeveConter ?? [] where contains(output, needle) {
            out.append("não devia conter \"\(needle)\"")
        }
        if let max = c.maxCaracteres, output.count > max {
            out.append("longo demais (\(output.count) > \(max))")
        }
        // Folding is width-insensitive ("？" matches "?"), so full-width punctuation is checked on
        // the raw output: Chinese output (an expected CJK text, or a zh case with no expected text)
        // must not get a half-width ", ? ! : ; ." after a CJK character.
        let expectsCJK = c.esperado.map(CJK.containsCJK) ?? (MultilingualPrompt.baseCode(c.lang ?? "") == "zh")
        if expectsCJK, ChineseScript.fullWidthPunctuation(output) != output {
            out.append("pontuação de meia largura")
        }
        let leakedTags = ["<fala>", "<selecionado>", "<speech>", "<selected>", "<question>"]
        if output.contains("**") || leakedTags.contains(where: output.contains) || output.hasPrefix("\"") {
            out.append("formatação indevida")
        }
        return out
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    /// Substring match after folding; a needle with CJK characters ignores spaces (Chinese has no
    /// spaces between words, the model sometimes adds them) but not line breaks, so a layout needle
    /// such as "\n\n明天" still checks the layout.
    static func contains(_ output: String, _ needle: String) -> Bool {
        let o = fold(output), n = fold(needle)
        guard CJK.containsCJK(n) else { return o.contains(n) }
        func spaceless(_ s: String) -> String {
            String(s.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }.map(Character.init))
        }
        return spaceless(o).contains(spaceless(n))
    }
}
