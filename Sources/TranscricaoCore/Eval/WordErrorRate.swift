// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Word error rate for the transcription eval (`tcli wer`). Pure; no model or audio code here.
public enum WordErrorRate {
    public struct Result: Equatable, Sendable {
        public let edits: Int
        public let referenceWords: Int
        public var rate: Double { referenceWords == 0 ? (edits == 0 ? 0 : 1) : Double(edits) / Double(referenceWords) }
    }

    /// Lowercases, drops punctuation (keeps letters, digits and the apostrophe/hyphen inside words),
    /// optionally strips accents, and splits on whitespace. CJK characters are one token each
    /// (character error rate for Chinese, which has no spaces).
    public static func words(_ text: String, ignoreAccents: Bool) -> [String] {
        var s = text.lowercased()
        if ignoreAccents { s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR")) }
        // "1.250" / "1,5": drop the separator between digits so a number stays one token.
        s = s.replacingOccurrences(of: "(?<=\\d)[.,](?=\\d)", with: "", options: .regularExpression)
        let cleaned = String(s.unicodeScalars.map { sc -> Character in
            CharacterSet.alphanumerics.contains(sc) || sc.properties.isAlphabetic ? Character(sc) : " "
        })
        return CJK.spacedOut(cleaned).split(whereSeparator: { $0 == " " || $0.isWhitespace }).map(String.init)
    }

    /// Word-level Levenshtein distance against one reference.
    public static func compute(reference: String, hypothesis: String, ignoreAccents: Bool = false) -> Result {
        let r = words(reference, ignoreAccents: ignoreAccents)
        let h = words(hypothesis, ignoreAccents: ignoreAccents)
        return Result(edits: distance(r, h), referenceWords: r.count)
    }

    /// Best (lowest-edit) result among equally valid references, e.g. the same number written
    /// in words or in digits.
    public static func compute(references: [String], hypothesis: String, ignoreAccents: Bool = false) -> Result {
        let results = references.map { compute(reference: $0, hypothesis: hypothesis, ignoreAccents: ignoreAccents) }
        return results.min { $0.edits < $1.edits } ?? Result(edits: 0, referenceWords: 0)
    }

    /// Corpus WER: total edits over total reference words (not the mean of per-sentence rates).
    public static func aggregate(_ results: [Result]) -> Result {
        Result(edits: results.reduce(0) { $0 + $1.edits }, referenceWords: results.reduce(0) { $0 + $1.referenceWords })
    }

    static func distance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// One entry of `fixtures/audio/ptbr/refs.json`.
public struct WERCase: Codable, Sendable {
    public let id: String
    public let audio: String          // relative to the refs.json directory
    public let ref: String
    public let alts: [String]?        // other equally correct spellings (digits vs words)
    public let voice: String?
    public let refSource: String?     // set when `ref` is not hand-written (e.g. "turbo-output")
    public var allReferences: [String] { [ref] + (alts ?? []) }
}
