// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Splits a long text (a transcribed file) into pieces the text model can take one at a time.
///
/// A chunk is a slice of the original text, trimmed: whole sentences when they fit; a sentence
/// longer than the limit is cut at its clause marks (", ; :" and "，、；："), then between words,
/// and, only when nothing else is left (Chinese has no spaces), between characters. Joining the
/// chunks gives back the text, apart from the whitespace between them. Lengths are Characters.
public enum TextChunker {
    /// Chunks of at most `maxCharacters` characters (at least 1), in order; none empty.
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let chars = Array(text)
        let limit = max(1, maxCharacters)
        var pieces: [Range<Int>] = []
        for sentence in split(0..<chars.count, in: chars, at: .sentence) {
            pieces += fitting(sentence, in: chars, limit: limit, level: .sentence)
        }
        // Greedy packing: a piece joins the current chunk when the whole slice still fits.
        var out: [String] = []
        var current: Range<Int>?
        for piece in pieces {
            if let c = current, piece.upperBound - c.lowerBound <= limit {
                current = c.lowerBound..<piece.upperBound
            } else {
                if let c = current { out.append(String(chars[c])) }
                current = piece
            }
        }
        if let c = current { out.append(String(chars[c])) }
        return out
    }

    /// Where a piece may end, from the best place to the last resort.
    enum Level: Int, Comparable {
        case sentence, clause, word, character
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var finer: Level? { Level(rawValue: rawValue + 1) }
    }

    /// `range` cut into pieces of at most `limit`, using finer boundaries only where needed.
    private static func fitting(_ range: Range<Int>, in chars: [Character], limit: Int, level: Level) -> [Range<Int>] {
        guard range.count > limit else { return [range] }
        guard let finer = level.finer else { return [] }
        if finer == .character {
            return stride(from: range.lowerBound, to: range.upperBound, by: limit).compactMap {
                trimmed($0..<min($0 + limit, range.upperBound), in: chars)
            }
        }
        return split(range, in: chars, at: finer).flatMap { fitting($0, in: chars, limit: limit, level: finer) }
    }

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    /// Chinese/Japanese sentence ends: no space follows them.
    static let wideSentenceEnds: Set<Character> = ["。", "！", "？", "；", "．"]
    static let clauseMarks: Set<Character> = [",", ";", ":"]
    static let wideClauseMarks: Set<Character> = ["，", "、", "：", "；"]
    /// Closing quotes and brackets stay with the sentence they end ("“Yes!”", "（好的。）").
    static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", "」", "』", "）", "】", "》"]

    /// The non-empty, trimmed pieces of `range`, each ending after a boundary of `level`.
    private static func split(_ range: Range<Int>, in chars: [Character], at level: Level) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        var i = range.lowerBound
        func cut(_ end: Int) {
            if let piece = trimmed(start..<end, in: chars) { pieces.append(piece) }
            start = end
        }
        while i < range.upperBound {
            let c = chars[i]
            switch level {
            case .sentence:
                if c.isNewline {
                    cut(i)
                } else if sentenceEnds.contains(c) || wideSentenceEnds.contains(c) {
                    var end = i + 1
                    while end < range.upperBound, sentenceEnds.contains(chars[end]) || wideSentenceEnds.contains(chars[end])
                        || closers.contains(chars[end]) { end += 1 }
                    if wideSentenceEnds.contains(c) || end == range.upperBound || chars[end].isWhitespace {
                        cut(end)
                        i = end
                        continue
                    }
                }
            case .clause:
                if wideClauseMarks.contains(c) || (clauseMarks.contains(c)
                    && (i + 1 == range.upperBound || chars[i + 1].isWhitespace)) {
                    cut(i + 1)
                }
            case .word:
                if c.isWhitespace { cut(i) }
            case .character:
                break
            }
            i += 1
        }
        cut(range.upperBound)
        return pieces
    }

    /// `range` without leading and trailing whitespace; nil when nothing is left.
    private static func trimmed(_ range: Range<Int>, in chars: [Character]) -> Range<Int>? {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, chars[lower].isWhitespace { lower += 1 }
        while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }
}
