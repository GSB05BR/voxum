// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Whisper writes Mandarin in either script and often with half-width punctuation; v1 ships
/// Simplified Chinese. The text model's prompt asks for Simplified, but raw text ("No AI", or the
/// fallback when the model fails) is pasted as Whisper wrote it: `rawForPaste` fixes that.
public enum ChineseScript {
    /// Traditional → Simplified characters (ICU's Hant-Hans); text without CJK is unchanged.
    public static func simplified(_ s: String) -> String {
        guard CJK.containsCJK(s) else { return s }
        return s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }

    private static let fullWidth: [Character: Character] = [",": "，", "?": "？", "!": "！", ":": "：", ";": "；", ".": "。"]

    /// Half-width ", ? ! : ; ." right after a CJK character (or right after a mark this already made
    /// full-width: "什么?!" → "什么？！") become full-width, and the spaces Whisper puts after them
    /// go. Anything else stays: "3,000", "v1.2", "OK, 好" (the comma follows a Latin letter), and
    /// any whitespace-delimited run with a URL ("http://例子.中国"). A "." becomes "。" only at the
    /// end of a sentence (followed by a space, a CJK character or the end), so "第3.5版" keeps its
    /// decimal point. An ellipsis ("..." or "…") after Chinese becomes "……".
    public static func fullWidthPunctuation(_ s: String) -> String {
        let chars = Array(s)
        let protected = urlMask(chars)
        var out = ""
        var i = 0
        func isCJK(_ c: Character) -> Bool { c.unicodeScalars.first.map(CJK.isCJK) ?? false }
        func isWide(_ c: Character) -> Bool { c.unicodeScalars.first.map(CJK.isCJKPunctuation) ?? false }
        var previous: Character?
        func skipSpaces() {
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j > i, j < chars.count { i = j }
        }
        while i < chars.count {
            let c = chars[i]
            // An ellipsis after Chinese ("好的..." or "好的…") is the Chinese one, "……", not "。。。".
            if !protected[i], c == "." || c == "…", let prev = previous, isCJK(prev) || isWide(prev) {
                var j = i
                while j < chars.count, chars[j] == "." || chars[j] == "…", !protected[j] { j += 1 }
                if c == "…" || j - i >= 2 {
                    out.append(contentsOf: "……")
                    previous = "。" // wide, so "……?" still becomes "……？" (U+2026 is not CJK punctuation)
                    i = j
                    skipSpaces()
                    continue
                }
            }
            guard !protected[i], let wide = fullWidth[c], let prev = previous, isCJK(prev) || isWide(prev) else {
                out.append(c); previous = c; i += 1; continue
            }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == ".", let next, !next.isWhitespace, !isCJK(next), fullWidth[next] == nil {
                out.append(c); previous = c; i += 1; continue
            }
            out.append(wide)
            previous = wide
            i += 1
            // Full-width punctuation carries its own spacing: drop the spaces before the next text.
            skipSpaces()
        }
        return out
    }

    /// Characters inside a whitespace-delimited run that contains "://" (a URL) are left alone.
    private static func urlMask(_ chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)
        var start = 0
        for end in 0...chars.count where end == chars.count || chars[end].isWhitespace {
            if end > start, String(chars[start..<end]).contains("://") {
                for k in start..<end { mask[k] = true }
            }
            start = end + 1
        }
        return mask
    }

    /// The raw transcript as pasted without the model: for Chinese dictation (`language` "zh",
    /// chosen or detected) Simplified characters and full-width punctuation; any other language
    /// is unchanged.
    public static func rawForPaste(_ s: String, language: String?) -> String {
        guard let language, MultilingualPrompt.baseCode(language) == "zh" else { return s }
        return fullWidthPunctuation(simplified(s))
    }
}
