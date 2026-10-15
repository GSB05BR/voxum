// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// "Organize with AI" and "Summarize" on a transcribed file (spec §5). Both run the text model on
/// pieces that fit its budget (`TextChunker`), report their progress, and stop when their task is
/// cancelled (the model work is cancelled too, not left running).
public enum TranscriptTasks {
    /// Characters of `text` that weigh about `budget` in the token budget
    /// (`PromptBuilder.budgetCharacters`): fewer for Chinese, whose characters cost more tokens.
    public static func characters(forBudget budget: Int, in text: String) -> Int {
        let weighed = PromptBuilder.budgetCharacters(text)
        guard weighed > 0 else { return budget }
        return max(100, budget * text.count / weighed)
    }

    /// Runs `op` in a task of its own, so both the timeout and a cancel of the caller stop it
    /// (`withTimeout` alone would leave the work running after its caller is cancelled).
    static func run<T: Sendable>(timeout: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let work = Task { try await op() }
        return try await withTaskCancellationHandler {
            do {
                return try await withTimeout(seconds: timeout) { try await work.value }
            } catch {
                work.cancel()
                throw error
            }
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Organize

    /// Budget of one piece for "Organize": the size of a long dictation, which is what the
    /// dictation prompt was tuned on (its output cap is 1024 tokens; 1200 characters ≈ 900).
    public static let organizeBudget = 1200
    /// Longest the model may take on one piece before the piece is kept as transcribed.
    public static let organizeTimeout: Double = 180

    public struct Organized: Equatable, Sendable {
        public var text: String
        public var pieces: Int
        /// Pieces kept as transcribed: the model failed, hit its cap, or wrote something of a very
        /// different length (it answered, summarized or composed instead of cleaning up).
        public var keptAsTranscribed: Int

        public init(text: String, pieces: Int, keptAsTranscribed: Int) {
            self.text = text
            self.pieces = pieces
            self.keptAsTranscribed = keptAsTranscribed
        }
    }

    /// The model's output is used for a piece only if its length is within these bounds of the
    /// piece's (weighed) length; otherwise the piece stays as transcribed.
    static let organizeLengthRatio: ClosedRange<Double> = 0.4...1.8
    /// Share of the output's content words that must come from the piece; below it the model
    /// added something of its own (an answer, a composed message) and the piece stays as transcribed.
    static let organizeMinFidelity = 0.7

    /// The content words of `text`: lowercased, diacritics stripped, letters and digits only,
    /// 4+ characters; CJK runs as character bigrams (no spaces between words there).
    static func contentWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var words: [String] = []
        var latin = "", cjk: [Character] = []
        func flush() {
            if latin.count >= 4 { words.append(latin) }
            latin = ""
            if cjk.count == 1 { words.append(String(cjk)) }
            if cjk.count > 1 { for i in 0..<(cjk.count - 1) { words.append(String(cjk[i...i + 1])) } }
            cjk = []
        }
        for ch in folded {
            if let scalar = ch.unicodeScalars.first, CJK.isCJK(scalar) {
                if !latin.isEmpty { flush() }
                cjk.append(ch)
            } else if ch.isLetter || ch.isNumber {
                if !cjk.isEmpty { flush() }
                latin.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// True when at least `organizeMinFidelity` of the output's content words occur in the piece
    /// (a cleanup keeps the speaker's words; an appended answer or a composed text does not).
    static func isFaithful(_ output: String, to piece: String) -> Bool {
        let produced = contentWords(output)
        guard produced.count >= 5 else { return true } // too short to judge: the length guard decides
        let source = Set(contentWords(piece))
        let found = produced.filter(source.contains).count
        return Double(found) / Double(produced.count) >= organizeMinFidelity
    }

    /// "Organize with AI": the dictation prompt plus the recording note (`RecordingOrganizing`, in
    /// `language`) on each piece, in order; pieces joined by a blank line. A piece the model fails on is kept as
    /// transcribed (Chinese gets Simplified characters, as a dictation's fallback does). Throws
    /// `CancellationError` when cancelled.
    public static func organize(_ text: String, language: String, using processor: RecordingOrganizing,
                                onProgress: (Double) -> Void = { _ in }) async throws -> Organized {
        let pieces = TextChunker.chunks(text, maxCharacters: characters(forBudget: organizeBudget, in: text))
        var out: [String] = []
        var kept = 0
        onProgress(0)
        for (i, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            var result: String?
            do {
                let raw = try await run(timeout: organizeTimeout) {
                    try await processor.organizeRecording(piece, language: language)
                }
                let cleaned = OutputSanitizer.clean(raw)
                let ratio = Double(PromptBuilder.budgetCharacters(cleaned)) / Double(max(1, PromptBuilder.budgetCharacters(piece)))
                if !cleaned.isEmpty, organizeLengthRatio.contains(ratio), isFaithful(cleaned, to: piece) { result = cleaned }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
            }
            if result == nil { kept += 1 }
            out.append(result ?? ChineseScript.rawForPaste(piece, language: language))
            onProgress(Double(i + 1) / Double(pieces.count))
        }
        return Organized(text: out.joined(separator: "\n\n"), pieces: pieces.count, keptAsTranscribed: kept)
    }

    // MARK: Summarize

    /// Budget of one piece for "Summarize" (≈ 1500 tokens of transcript, about 10 minutes of speech).
    public static let summaryBudget = 6000
    public static let summaryTimeout: Double = 240

    public struct SummaryError: Error, Equatable {
        public init() {}
    }

    /// "Summarize": bullet points in `language`. A transcript that fits one piece is summarized at
    /// once; a longer one is summarized piece by piece and the notes of the pieces are then
    /// summarized together (again in pieces if they are still too long). Throws `SummaryError`
    /// when the model gives nothing usable, `CancellationError` when cancelled.
    public static func summarize(_ text: String, language: String, using summarizer: TranscriptSummarizing,
                                 onProgress: (Double) -> Void = { _ in }) async throws -> String {
        onProgress(0)
        var material = text
        var done = 0
        // Each round replaces the material by the notes of its pieces; every round shortens it.
        for _ in 0..<4 {
            let pieces = TextChunker.chunks(material, maxCharacters: characters(forBudget: summaryBudget, in: material))
            guard pieces.count > 1 else { break }
            var notes: [String] = []
            for piece in pieces {
                notes.append(try await summarizeOnce(piece, language: language, using: summarizer))
                done += 1
                // The total is not known before the last round: a bound that only grows.
                onProgress(min(0.95, Double(done) / Double(done + pieces.count - notes.count + 1)))
            }
            let next = notes.joined(separator: "\n")
            guard PromptBuilder.budgetCharacters(next) < PromptBuilder.budgetCharacters(material) else { break }
            material = next
        }
        let summary = try await summarizeOnce(material, language: language, using: summarizer)
        onProgress(1)
        return summary
    }

    private static func summarizeOnce(_ text: String, language: String,
                                      using summarizer: TranscriptSummarizing) async throws -> String {
        try Task.checkCancellation()
        let raw: String
        do {
            raw = try await run(timeout: summaryTimeout) { try await summarizer.summarize(text, language: language) }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw SummaryError()
        }
        let cleaned = SummaryPrompt.clean(raw)
        guard !cleaned.isEmpty else { throw SummaryError() }
        return cleaned
    }
}
