// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What Whisper heard: the raw text and the language it was transcribed in.
public struct Transcript: Equatable, Sendable {
    public var text: String
    /// Whisper language code ("pt", "en", "zh", …): the requested one, or the detected one when
    /// the language was left to Whisper; nil if unknown.
    public var language: String?
    /// Probability (0…1) Whisper's language ID gave `language` when it was detected; nil when the
    /// language was requested or not measured.
    public var languageConfidence: Double?

    public init(text: String, language: String?, languageConfidence: Double? = nil) {
        self.text = text
        self.language = language
        self.languageConfidence = languageConfidence
    }
}

public protocol Transcriber: AnyObject, Sendable {
    /// 16 kHz mono Float32 samples → raw transcript. `language` = Whisper code; nil = detect it.
    func transcribe(_ samples: [Float], language: String?) async throws -> Transcript
}

public protocol TextProcessor: AnyObject, Sendable {
    /// Raw transcript → final text (may contain reasoning/markdown; the pipeline sanitizes).
    /// `selection` = text selected in the focused app (edit by voice), nil for plain dictation.
    /// `language` = the dictation's Whisper code ("pt" = the Portuguese prompt; "" = unknown).
    /// Throws `OutputTruncatedError` when generation stopped at the token cap.
    func process(_ transcript: String, selection: String?, language: String) async throws -> String
}

extension TextProcessor {
    /// Portuguese.
    public func process(_ transcript: String, selection: String?) async throws -> String {
        try await process(transcript, selection: selection, language: "pt")
    }

    public func process(_ transcript: String) async throws -> String {
        try await process(transcript, selection: nil)
    }
}

/// A processor that can answer a spoken request about a read-only selection (assistant mode),
/// streaming the text as it is generated.
public protocol SelectionAnswering: AnyObject, Sendable {
    /// `onPartial` receives the whole text generated so far. Throws `OutputTruncatedError` at the cap.
    func answer(_ request: String, about selection: String, language: String,
                onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

extension SelectionAnswering {
    /// Portuguese.
    public func answer(_ request: String, about selection: String,
                       onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await answer(request, about: selection, language: "pt", onPartial: onPartial)
    }
}

/// A processor that can answer a question asked with the question key (spec §4), streaming the
/// text as it is generated.
public protocol QuestionAnswering: AnyObject, Sendable {
    /// `context` = the selected text, if any; `language` = the question's Whisper code ("" =
    /// unknown). `onPartial` receives the whole text generated so far. Throws
    /// `OutputTruncatedError` at the cap.
    func ask(_ question: String, context: String?, language: String,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

/// "Organize with AI" on a piece of a transcribed file: `PromptBuilder.recordingMessages`
/// (the dictation prompt plus the recording note). Throws `OutputTruncatedError` at the token cap.
public protocol RecordingOrganizing: AnyObject, Sendable {
    func organizeRecording(_ piece: String, language: String) async throws -> String
}

/// A processor that can summarize a transcribed file ("Summarize", spec §5).
public protocol TranscriptSummarizing: AnyObject, Sendable {
    /// `text` = a transcript, a part of one, or the notes of its parts (`PromptBuilder.summaryMessages`);
    /// `language` = the file's Whisper code ("" = unknown). Returns the model's raw output.
    /// Throws `OutputTruncatedError` at the cap.
    func summarize(_ text: String, language: String) async throws -> String
}

/// What the answer panel is showing.
public enum AnswerKind: Equatable, Sendable {
    /// An answer about a read-only selection (a spoken request about it).
    case selection
    /// The answer to a question asked with the question key.
    case question
}

/// Shows the answer about a read-only selection, or to a question (the floating panel). Called
/// from any thread, in order (begin → updates → finish or fail); implementations hop to the main
/// queue in FIFO order.
public protocol AnswerPresenter: Sendable {
    func begin()
    /// Defaults to `begin()` (an answer about a selection).
    func begin(kind: AnswerKind)
    func update(_ partial: String)
    func finish(_ text: String)
    func fail(_ message: String)
}

extension AnswerPresenter {
    public func begin(kind: AnswerKind) { begin() }
}

public struct NoAnswerPresenter: AnswerPresenter {
    public init() {}
    public func begin() {}
    public func update(_ partial: String) {}
    public func finish(_ text: String) {}
    public func fail(_ message: String) {}
}

/// The text model stopped because it hit `maxTokens`: its output is cut mid-way and must never
/// be pasted (the pipeline falls back to the raw transcript).
public struct OutputTruncatedError: Error, Equatable {
    public init() {}
}

public protocol TextInserter: Sendable {
    func insert(_ text: String) async
}

/// A model that can be loaded into / evicted from memory.
public protocol ResidentModel: AnyObject, Sendable {
    func load() async throws
    func unload() async
}
