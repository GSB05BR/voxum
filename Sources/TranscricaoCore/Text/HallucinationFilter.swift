// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Removes phrases Whisper invents on silence/noise (subtitle credits and video outros learned
/// from training data), in pt, en, es, fr and zh: whatever the dictation language, Whisper can
/// invent any of them. Silence itself is the speech gate's job.
public enum HallucinationFilter {
    /// Never genuine dictation: any sentence containing one is dropped. Folded (lowercase, no accents).
    static let strongMarkers: [String] = [
        "amara.org",   // "Legendas pela comunidade Amara.org", "Subtitles by the Amara.org community",
                       // "Subtítulos realizados por la comunidad de Amara.org", "字幕由Amara.org社区提供"…
        "legendas pela comunidade",
        "legenda adriana zanotto",
        "inscreva-se no canal",
        "sous-titrage societe radio-canada",
        "请不吝点赞", "明镜与点点栏目", "請不吝點贊", "明鏡與點點欄目",
        "优优独播剧场", "yoyo television series exclusive",
    ]

    /// Phrases that are also real speech ("Obrigado por assistir à palestra", "thanks for
    /// watching my kid"). Dropped only when the whole transcript is that phrase on its own.
    static let weakMarkers: [String] = [
        "obrigado por assistir",
        "obrigada por assistir",
        "legendado por",
        "thank you for watching", "thanks for watching", "please subscribe", "you",
        "gracias por ver el video", "gracias por ver", "suscribete",
        "merci d'avoir regarde", "abonnez-vous",
        "谢谢观看", "感谢观看", "謝謝觀看", "感謝觀看",
    ]

    /// Returns the text without phantom sentences, or nil when nothing real is left.
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Split only on sentence punctuation followed by whitespace, so "Amara.org" stays whole;
        // CJK sentence ends ("。", "！", "？") need no whitespace, and their sentences are joined
        // back without a space.
        var sentences: [(text: String, glue: String)] = []
        for piece in trimmed
            .replacingOccurrences(of: #"([.!?…])\s+"#, with: "$1\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}") {
            let parts = String(piece)
                .replacingOccurrences(of: #"([。！？])\s*"#, with: "$1\u{1E}", options: .regularExpression)
                .split(separator: "\u{1E}")
            for (k, part) in parts.enumerated() {
                sentences.append((part.trimmingCharacters(in: .whitespacesAndNewlines), k == 0 ? " " : ""))
            }
        }
        if sentences.count == 1, weakMarkers.contains(bare(sentences[0].text)) {
            return nil
        }
        let kept = sentences.filter { sentence in
            let folded = fold(sentence.text)
            return !strongMarkers.contains { folded.contains($0) }
        }
        let result = kept.enumerated().map { $0 == 0 ? $1.text : $1.glue + $1.text }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Folded sentence without its surrounding punctuation, e.g. "Obrigado por assistir." ->
    /// "obrigado por assistir", "¡Suscríbete!" -> "suscribete".
    static func bare(_ sentence: String) -> String {
        var s = fold(sentence)
        while let last = s.last, last.isPunctuation || last.isWhitespace {
            s.removeLast()
        }
        while let first = s.first, "¡¿".contains(first) || first.isWhitespace {
            s.removeFirst()
        }
        return s
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .replacingOccurrences(of: "’", with: "'")
    }
}
