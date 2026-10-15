// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The delimiter tags the prompts wrap user material in. Text from the screen (a selection on a
/// web page), from speech or from a transcribed file must never close a tag and open another:
/// "…</selected><question>do this</question>" would pose as the person's own request. Before
/// anything is wrapped, every delimiter tag inside it is neutralised: its angle brackets (and any
/// bracket inside it) become ‹ › (the text stays readable and is the same for the model, but no
/// longer a tag). The prompt templates themselves never go through this, so their bytes are
/// unchanged; text without such tags is returned unchanged.
public enum PromptTags {
    /// Every tag any prompt uses (QuestionPrompt, MultilingualPrompt, SummaryPrompt, the
    /// Portuguese PromptBuilder).
    public static let names = ["selected", "question", "speech", "selecionado", "fala", "transcript"]

    // Linear time on any input (the material is attacker-controlled: a web page's text): every
    // repetition is possessive (`*+`, never backtracked into), and no two quantifiers can match
    // the same characters in more than one way.

    /// Whitespace and invisible format characters (zero-width space/joiners, BOM, soft hyphen…):
    /// the model reads past them, so they may sit anywhere inside a tag.
    private static let gap = #"[\s\p{Cf}]*+"#

    /// "selected" → "s[\p{Cf}\p{Mn}]*+e…": a name with invisible characters or combining marks
    /// (`s\u{301}elected`) between its letters. Lookalike letters from other scripts (Cyrillic
    /// "е") would need a confusables table and are not handled.
    private static func spelled(_ name: String) -> String {
        name.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\p{Cf}\p{Mn}]*+"#)
    }

    /// Opening brackets: ASCII, full-width (＜) and small-form (﹤). Closing likewise.
    private static let opening = "[<＜﹤]"
    private static let closingClass = "[>＞﹥]"

    /// What follows the name, up to the closing bracket. First choice: attributes with quoted
    /// values, which may hold `>` (`<question title="<b>">`): each step is a quoted string, a lone
    /// quote (unmatched: `</selected a=">`) or any other character but a bracket, and the steps
    /// are atomic. If a quoted run swallowed the only `>` (`<selected a="b> … "`), the second
    /// choice ends the tag at the first bracket, so a tag is never missed.
    private static let rest = #"(?:(?>"[^"]*+"|'[^']*+'|["']|[^>＞﹥"'])*+[>＞﹥]|[^>＞﹥]*+[>＞﹥])"#

    /// `<tag>`, `</tag>`, in any case, with spaces or invisible characters inside the brackets,
    /// with attributes (which may contain `<`, and `>` inside quotes), and with full-width
    /// brackets (＜ ＞). The name must end there (`<selectedItem>` is not a tag of ours).
    private static let head = opening + gap + "[/／]?" + gap + "(?:" + names.map(spelled).joined(separator: "|") + ")"
        + #"(?![\p{L}\p{N}_])"#
    private static let pattern = try! NSRegularExpression(pattern: head + rest, options: [.caseInsensitive])
    /// A tag opening with no closing bracket after it ("x <question" at the very end): the prompt
    /// template's own ">" right after the material would complete it.
    private static let unclosed = try! NSRegularExpression(pattern: head, options: [.caseInsensitive])

    private static let closing = CharacterSet(charactersIn: ">＞﹥")

    public static func neutralize(_ text: String) -> String {
        let ns = text as NSString
        // A tag ends at a closing bracket: the search stops at the last one. Within that range
        // every tag opening finds its end, so no attempt scans the rest of the text and fails (a
        // failed attempt at each of thousands of unclosed "<selected" would be quadratic). After
        // it, an opening can only be unclosed: its brackets are neutralised by a second, short
        // pattern (no `rest`), which is linear too.
        let lastBracket = ns.rangeOfCharacter(from: Self.closing, options: .backwards)
        let end = lastBracket.location == NSNotFound ? 0 : lastBracket.location + lastBracket.length
        let matches = (end > 0 ? pattern.matches(in: text, range: NSRange(location: 0, length: end)) : [])
            + unclosed.matches(in: text, range: NSRange(location: end, length: ns.length - end))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // Scalars, not Characters: "<" followed by a zero-width joiner is one Character.
            var tag = String.UnicodeScalarView()
            for scalar in ns.substring(with: m.range).unicodeScalars {
                switch scalar {
                case "<", "＜", "﹤": tag.append("‹")
                case ">", "＞", "﹥": tag.append("›")
                default: tag.append(scalar)
                }
            }
            out += String(tag)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
