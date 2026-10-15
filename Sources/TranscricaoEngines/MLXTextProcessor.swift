// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import TranscricaoCore

public enum TextEngineError: Error { case notLoaded, unexpectedToolCall }

/// In-process LLM via MLX. Each request uses a fresh ChatSession (no memory
/// between dictations): system prompt + few-shot history + the transcript.
public final class MLXTextProcessor: TextProcessor, SelectionAnswering, QuestionAnswering, TranscriptSummarizing, RecordingOrganizing, ResidentModel,
    @unchecked Sendable {
    private let lock = NSLock()
    private var container: ModelContainer?
    private var _modelID: String?
    public var onProgress: (@Sendable (Double) -> Void)?

    /// `modelID` nil = no text model ("Sem IA"): load/unload do nothing and nothing is resident.
    public init(modelID: String?) {
        _modelID = modelID
    }

    public var modelID: String? { lock.withLock { _modelID } }
    public var isLoaded: Bool { lock.withLock { container != nil } }

    /// Takes effect on the next load(); callers unload first.
    public func setModelID(_ id: String?) { lock.withLock { _modelID = id } }

    public func load() async throws {
        if isLoaded { return }
        guard let id = modelID else { return } // no text model: memory stays Whisper only
        let loaded: ModelContainer
        if let local = LocalModelFiles.hubSnapshot(repoID: id, cache: ModelLocations.hub) {
            // Complete snapshot on disk: load the directory directly. Going through the hub
            // downloader would first list the repo files on huggingface.co (a network round trip
            // on every launch, and a failure path when offline).
            do {
                loaded = try await LLMModelFactory.shared.loadContainer(
                    from: local, using: #huggingFaceTokenizerLoader())
                engineLog("text model loaded from local snapshot")
            } catch {
                engineLog("text model local load failed; retrying via download", error: error)
                loaded = try await download(id)
            }
        } else {
            engineLog("text model not found locally; downloading")
            loaded = try await download(id)
        }
        lock.withLock { container = loaded }
        do {
            _ = try await process("teste") // warm up kernels
        } catch is OutputTruncatedError {
            // Warm-up only needs the kernels compiled; a cut answer is fine here.
        }
    }

    /// First run (or incomplete cache): resolve through the hub, downloading what is missing.
    private func download(_ id: String) async throws -> ModelContainer {
        let hub = HubClient(cache: HubCache(cacheDirectory: ModelLocations.hub))
        let progress = onProgress
        return try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: id),
            progressHandler: { p in progress?(p.fractionCompleted) })
    }

    public func unload() async {
        lock.withLock { container = nil }
        MLX.Memory.clearCache()
    }

    public func process(_ transcript: String, selection: String?, language: String) async throws -> String {
        try await generate(PromptBuilder.messages(for: transcript, selection: selection, language: language),
                           maxTokens: PromptBuilder.maxTokens(transcript: transcript, selection: selection))
    }

    /// Read-only selection: the assistant prompt, streamed (the panel shows the text as it comes).
    public func answer(_ request: String, about selection: String, language: String,
                       onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await generate(PromptBuilder.answerMessages(for: request, selection: selection, language: language),
                           maxTokens: PromptBuilder.maxTokens(transcript: request, selection: selection),
                           onPartial: onPartial)
    }

    /// Question mode: the assistant prompt (`QuestionPrompt`), streamed into the panel.
    public func ask(_ question: String, context: String?, language: String,
                    onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await generate(PromptBuilder.questionMessages(for: question, context: context, language: language),
                           maxTokens: QuestionPrompt.maxTokens(question: question, context: context),
                           onPartial: onPartial)
    }

    /// "Organize with AI" on a piece of a transcribed file: the dictation prompt plus the
    /// recording note (`PromptBuilder.recordingMessages`), with the dictation's token cap.
    public func organizeRecording(_ piece: String, language: String) async throws -> String {
        try await generate(PromptBuilder.recordingMessages(for: piece, language: language),
                           maxTokens: PromptBuilder.maxTokens(transcript: piece, selection: nil))
    }

    /// "Summarize" on a transcribed file: the summary prompt (`SummaryPrompt`), not streamed.
    public func summarize(_ text: String, language: String) async throws -> String {
        try await generate(PromptBuilder.summaryMessages(for: text, language: language), maxTokens: SummaryPrompt.maxTokens)
    }

    private func generate(_ turns: [ChatTurn], maxTokens: Int,
                          onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let container = lock.withLock({ container }) else { throw TextEngineError.notLoaded }
        let system = turns.first?.content
        let history: [Chat.Message] = turns.dropFirst().dropLast().map { turn in
            switch turn.role {
            case .assistant: .assistant(turn.content)
            case .system: .system(turn.content) // a later system turn (the recording note)
            case .user: .user(turn.content)
            }
        }
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        // Hybrid-thinking models (Qwen3, Qwen3.5) read `enable_thinking` in their chat template;
        // templates without it ignore the variable, so this changes nothing for the other models.
        let session = ChatSession(container, instructions: system, history: history,
                                  generateParameters: params,
                                  additionalContext: ["enable_thinking": false])
        // Iterate the stream ourselves so a cancelled Task (pipeline timeout, Esc)
        // stops generating at the next chunk instead of running to maxTokens.
        var output = ""
        var truncated = false
        for try await item in session.streamDetails(to: turns.last?.content ?? "") {
            try Task.checkCancellation()
            switch item {
            case .chunk(let chunk):
                output += chunk
                onPartial?(output)
            case .info(let info): truncated = info.stopReason == .length
            case .toolCall, .rejectedToolCall: throw TextEngineError.unexpectedToolCall // no tools here
            }
        }
        try Task.checkCancellation()
        // Hitting maxTokens means the text is cut mid-way: never paste it.
        if truncated { throw OutputTruncatedError() }
        return output
    }
}
