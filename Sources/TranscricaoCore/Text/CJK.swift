// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Chinese, Japanese and Korean text has no spaces between words: the evals count it per character.
public enum CJK {
    /// Han ideographs, kana, Hangul and their extensions/compatibility blocks.
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3100...0x312F,   // Bopomofo
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FA1F: // CJK Extensions B…F, compatibility supplement
            return true
        default:
            return false
        }
    }

    /// CJK punctuation and full-width forms ("，", "。", "？", "「"…).
    public static func isCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }

    /// Han ideographs only (no kana, no Hangul).
    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    /// Text written in Chinese: at least 2 Han characters, no kana or Hangul, and more Han
    /// characters than Latin *words* (one Han character is about a syllable, one English word
    /// several letters): "我用Mac" and "我觉得iPhone 15 Pro Max挺好" are Chinese, "Please send it to
    /// 王伟 tomorrow" is not. Japanese written only in kanji ("新宿駅") also passes: callers must
    /// not apply this to a Japanese or Korean label (`DictationLanguage.promptLanguage`).
    public static func looksChinese(_ s: String) -> Bool {
        var han = 0, words = 0, inWord = false
        for sc in s.unicodeScalars {
            if isHan(sc) { han += 1; inWord = false; continue }
            if isCJK(sc) || (0x1100...0x11FF).contains(sc.value) || (0x3130...0x318F).contains(sc.value) { return false }
            let letter = sc.properties.isAlphabetic
            if letter, !inWord { words += 1 }
            inWord = letter
        }
        return han >= 2 && han > words
    }

    public static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: isCJK)
    }

    public static func removingWhitespace(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// Puts spaces around every CJK character so a whitespace split yields one token per character
    /// ("我们 go" → ["我", "们", "go"]); other text is untouched.
    public static func spacedOut(_ s: String) -> String {
        guard containsCJK(s) else { return s }
        var out = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            if isCJK(sc) {
                out.append(" "); out.append(sc); out.append(" ")
            } else {
                out.append(sc)
            }
        }
        return String(out)
    }
}
