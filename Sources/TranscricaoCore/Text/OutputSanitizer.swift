// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Strips the wrapping small models like to add around the answer.
/// Only unambiguous wrappers are removed: dictated words that happen to look
/// like a label ("Resposta: sim") or markup-like text ("__init__", "> x") are kept.
public enum OutputSanitizer {
    public static func clean(_ raw: String) -> String {
        var s = raw
        s = replace(s, #"(?s)<think>.*?</think>"#, "")
        if let open = s.range(of: "<think>") {
            // Unterminated reasoning: nothing after it is usable.
            s = String(s[..<open.lowerBound])
        }
        s = replace(s, #"</?(fala|selecionado|speech|selected)>"#, "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // (a) "Texto final:" / "Texto revisado:" at the very start.
        s = replace(s, #"(?i)^texto\s+(final|revisado)\s*:\s*"#, "")
        // (b) First line is only a label word followed by ":" and a newline: drop that line.
        s = replace(s, #"(?i)^(texto final|texto|resposta|sa[ií]da|output)[ \t]*:[ \t]*\n"#, "")
        // The same for the other languages (fr puts a space before ":", zh uses "："):
        // (a) unambiguous "final/revised text" labels, even with text on the same line;
        s = replace(s, #"(?i)^(final text|revised text|texte\s+(final|r[ée]vis[ée])|最终文本|修改后的文本|修改后)[ \t\u00A0\u202F]*[:：]\s*"#, "")
        // (b) a label alone on the first line ("Answer: yes" is kept).
        s = replace(s, #"(?i)^(text|output|answer|salida|respuesta|texte|sortie|r[ée]ponse|输出|回答|答案)[ \t\u00A0\u202F]*[:：][ \t]*\n"#, "")
        s = replace(s, #"\*\*"#, "")
        s = replace(s, #"(?m)^#{1,6}\s+"#, "")
        // Markdown hard breaks ("  " before a newline) would paste as stray spaces.
        s = replace(s, #"(?m)[ \t]+$"#, "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripWrappingQuotes(s)   // « … » leaves its no-break spaces: trimmed below
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A question's answer: `clean`, plus the question prompt's own tags.
    public static func cleanAnswer(_ raw: String) -> String {
        clean(replace(raw, #"</?question>"#, ""))
    }

    static func stripWrappingQuotes(_ s: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»"),
                                               ("「", "」"), ("『", "』")]
        guard s.count >= 2, let first = s.first, let last = s.last else { return s }
        for (open, close) in pairs where first == open && last == close {
            let inner = s.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { return String(inner) }
        }
        return s
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
