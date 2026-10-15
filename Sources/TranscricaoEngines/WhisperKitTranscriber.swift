// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TranscricaoCore
import WhisperKit

public enum WhisperError: Error { case notLoaded }

public final class WhisperKitTranscriber: Transcriber, ResidentModel, @unchecked Sendable {
    public static let variant = ModelCatalog.whisperVariant

    /// WhisperKit CoreML variant (folder name in argmaxinc/whisperkit-coreml); the default is the app's model.
    public let modelVariant: String

    private let lock = NSLock()
    private var kit: WhisperKit?

    public init(variant: String = WhisperKitTranscriber.variant) { modelVariant = variant }

    public var isLoaded: Bool { lock.withLock { kit != nil } }

    /// `language` = Whisper code ("pt", "en", "zh"…); nil = detect it (Automatic), per window.
    static func options(language: String?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad)   // > 30 s clips (continuous mode)
    }

    /// `modelFolder` set → load that local folder with no network access (download: false);
    /// nil → WhisperKit resolves/downloads the variant from the hub (first run only).
    /// `downloadBase` stays set either way: WhisperKit finds the local tokenizer through it
    /// (`<downloadBase>/models/openai/whisper-large-v3/tokenizer.json`).
    static func config(variant: String = WhisperKitTranscriber.variant, modelFolder: URL?) -> WhisperKitConfig {
        WhisperKitConfig(
            model: variant,
            downloadBase: ModelLocations.whisper,
            modelFolder: modelFolder?.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: modelFolder == nil)
    }

    public func load() async throws {
        if isLoaded { return }
        let loaded: WhisperKit
        if let local = LocalModelFiles.whisperFolder(variant: modelVariant, downloadBase: ModelLocations.whisper) {
            do {
                loaded = try await WhisperKit(Self.config(variant: modelVariant, modelFolder: local))
                engineLog("whisper loaded from local folder")
            } catch {
                // A damaged local copy should not strand the user: try the normal download path once.
                engineLog("whisper local load failed; retrying via download", error: error)
                loaded = try await WhisperKit(Self.config(variant: modelVariant, modelFolder: nil))
            }
        } else {
            engineLog("whisper not found locally; downloading")
            loaded = try await WhisperKit(Self.config(variant: modelVariant, modelFolder: nil))
        }
        _ = try await loaded.transcribe(audioArray: [Float](repeating: 0, count: 16_000),
                                        decodeOptions: Self.options(language: "pt")) // warm up
        lock.withLock { kit = loaded }
    }

    public func unload() async {
        let current = lock.withLock { () -> WhisperKit? in
            defer { kit = nil }
            return kit
        }
        await current?.unloadModels()
    }

    public func transcribe(_ samples: [Float], language: String?) async throws -> Transcript {
        guard let kit = lock.withLock({ kit }) else { throw WhisperError.notLoaded }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.options(language: language))
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard language == nil else { return Transcript(text: text, language: language) }
        let detected = Self.detectedLanguage(results.map(\.language))
        let confidence = DictationLanguage.needsConfidence(detected: detected, transcript: text)
            ? await confidence(of: detected, in: samples, kit: kit) : nil
        return Transcript(text: text, language: detected, languageConfidence: confidence)
    }

    /// A whole file (spec §5), read and transcribed in blocks (`FileTranscription`, `AudioFileReader`):
    /// memory stays at about a minute of audio whatever the length. `language` nil = Automatic
    /// (detected once, on the first block with speech). Cancelling the calling task stops it within
    /// the current block (WhisperKit checks cancellation per token).
    public func transcribeFile(_ url: URL, language: String?,
                               onProgress: (Double) -> Void = { _ in },
                               onText: (String) -> Void = { _ in }) async throws -> FileTranscript {
        guard isLoaded else { throw WhisperError.notLoaded }
        let reader = try await AudioFileReader.open(url)
        return try await FileTranscription.transcribe(reader, with: self, language: language,
                                                      onProgress: onProgress, onText: onText)
    }

    /// Probability Whisper's language ID gives `language` on the clip's first 30 s (one more encoder
    /// pass: transcription results carry no probabilities). nil when that pass picks another
    /// language or fails: the label is then not trusted.
    private func confidence(of language: String?, in samples: [Float], kit: WhisperKit) async -> Double? {
        guard let language, let lid = try? await kit.detectLangauge(audioArray: samples),
              lid.language == language, let logProb = lid.langProbs[language] else { return nil }
        return Self.probability(logProb: logProb)
    }

    /// WhisperKit reports the language token's log-probability (softmax over the language tokens).
    static func probability(logProb: Float) -> Double { min(1, max(0, exp(Double(logProb)))) }

    /// The language of the clip: the one most windows were detected in (the first on a tie).
    static func detectedLanguage(_ languages: [String]) -> String? {
        let found = languages.filter { !$0.isEmpty }
        guard let first = found.first else { return nil }
        let counts = Dictionary(found.map { ($0, 1) }, uniquingKeysWith: +)
        return found.first { counts[$0] == counts.values.max() } ?? first
    }
}
