// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 16 kHz mono samples read from a file a piece at a time (in Engines, through AVFoundation), so
/// a long file never sits in memory whole.
public protocol AudioSampleSource: AnyObject {
    /// The audio's length in 16 kHz samples, when known (for the progress only).
    var expectedSamples: Int? { get }
    /// The next samples, at most `maxSamples`; empty at the end of the audio.
    func read(maxSamples: Int) throws -> [Float]
}

/// What Whisper heard in a file.
public struct FileTranscript: Equatable, Sendable {
    /// Whisper's text: the blocks joined, phantom sentences removed (`HallucinationFilter`).
    public var raw: String
    /// The text as shown, copied, saved and kept in History: a Chinese transcript gets Simplified
    /// characters and full-width punctuation, as a dictation without the AI does
    /// (`ChineseScript.rawForPaste`); any other language is `raw`.
    public var text: String
    /// Whisper code of the spoken language: the chosen one, or the one detected on the first
    /// block with speech (Automatic); nil if unknown.
    public var language: String?
    /// The language Organize and Summarize write in (`DictationLanguage.promptLanguage`; "" = the
    /// language-neutral rules).
    public var promptLanguage: String
    /// Length of the audio read, in seconds.
    public var seconds: Double

    public init(raw: String, text: String, language: String?, promptLanguage: String, seconds: Double) {
        self.raw = raw
        self.text = text
        self.language = language
        self.promptLanguage = promptLanguage
        self.seconds = seconds
    }
}

/// Transcribes a file of any length in blocks (spec §5): the audio is read a few seconds at a time
/// and handed to Whisper about a minute at a time, so memory stays at about one block (~4 MB)
/// whatever the length, the progress moves once per block, and a cancel stops it within the
/// current block (WhisperKit checks cancellation per token). Each block ends at its quietest
/// moment near the minute, so no word is cut in two; inside a block WhisperKit's own VAD
/// chunking takes over.
///
/// The language is decided once: the chosen one, or in Automatic the one Whisper detects on the
/// first block with speech, then passed to every later block (no label flipping mid-file, and the
/// detection pass is paid once).
public enum FileTranscription {
    public static let sampleRate = 16_000

    public struct Options: Sendable {
        /// Longest block handed to Whisper.
        public var blockSeconds: Double
        /// A block ends at the quietest 100 ms within its last `searchSeconds`.
        public var searchSeconds: Double
        /// How much audio is read from the file at a time.
        public var readSeconds: Double
        /// Blocks without speech are skipped (Whisper invents text on silence).
        public var gate: SpeechGate

        public init(blockSeconds: Double = 60, searchSeconds: Double = 10, readSeconds: Double = 5,
                    gate: SpeechGate = SpeechGate()) {
            self.blockSeconds = blockSeconds
            self.searchSeconds = searchSeconds
            self.readSeconds = readSeconds
            self.gate = gate
        }
    }

    /// `language` = the chosen Whisper code; nil = Automatic. `onProgress` gets 0…1 (1 only at the
    /// end); `onText` the transcript so far after each block with speech. Throws
    /// `CancellationError` when the task is cancelled, and the source's or the transcriber's errors.
    public static func transcribe(_ source: AudioSampleSource, with transcriber: Transcriber,
                                  language requested: String?, options: Options = Options(),
                                  onProgress: (Double) -> Void = { _ in },
                                  onText: (String) -> Void = { _ in }) async throws -> FileTranscript {
        let blockSamples = max(1, Int(options.blockSeconds * Double(sampleRate)))
        let searchSamples = min(blockSamples, max(0, Int(options.searchSeconds * Double(sampleRate))))
        let readSamples = max(1, Int(options.readSeconds * Double(sampleRate)))
        var buffer: [Float] = []
        buffer.reserveCapacity(blockSamples + readSamples)
        var ended = false
        var consumed = 0
        var parts: [String] = []
        var language = requested
        var detected: String?
        var confidence: Double?
        onProgress(0)
        while true {
            try Task.checkCancellation()
            while !ended, buffer.count < blockSamples {
                let more = try source.read(maxSamples: readSamples)
                if more.isEmpty { ended = true } else { buffer += more }
            }
            if buffer.isEmpty { break }
            let cut = ended && buffer.count <= blockSamples
                ? buffer.count
                : quietestCut(buffer, in: (blockSamples - searchSamples)..<blockSamples)
            let block = Array(buffer[..<cut])
            buffer.removeFirst(cut)
            consumed += cut
            if options.gate.shouldTranscribe(block) {
                let transcript = try await transcriber.transcribe(block, language: language)
                try Task.checkCancellation()
                if requested == nil, detected == nil, let found = transcript.language, !found.isEmpty {
                    detected = found
                    confidence = transcript.languageConfidence
                    language = found
                }
                if let cleaned = HallucinationFilter.clean(transcript.text) {
                    parts.append(cleaned)
                    onText(join(parts))
                }
            }
            if !(ended && buffer.isEmpty) {
                let total = max(source.expectedSamples ?? 0, consumed + buffer.count)
                onProgress(min(0.99, Double(consumed) / Double(max(1, total))))
            }
        }
        onProgress(1)
        let raw = join(parts)
        let prompt = DictationLanguage.promptLanguage(requested: requested, detected: detected,
                                                      confidence: confidence, transcript: raw)
        let spoken = requested ?? detected
        return FileTranscript(raw: raw, text: ChineseScript.rawForPaste(raw, language: prompt.isEmpty ? spoken : prompt),
                              language: spoken, promptLanguage: prompt, seconds: Double(consumed) / Double(sampleRate))
    }

    /// Where a block ends: the middle of the quietest 100 ms window inside `range` (clamped to the
    /// buffer). An empty range cuts at its end.
    static func quietestCut(_ samples: [Float], in range: Range<Int>, window: Int = sampleRate / 10) -> Int {
        let lower = max(0, min(range.lowerBound, samples.count)), upper = max(lower, min(range.upperBound, samples.count))
        guard upper - lower >= window, window > 0 else { return max(1, upper) }
        var best = upper, bestEnergy = Float.infinity
        var start = lower
        while start + window <= upper {
            var energy: Float = 0
            for i in start..<(start + window) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = start + window / 2
            }
            start += window
        }
        return max(1, best)
    }

    /// Blocks joined by a space, or by nothing between Chinese/Japanese text ("…吃饭。" + "然后…",
    /// also when Whisper ended the block with a half-width "." after Chinese).
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            let lastText = out.unicodeScalars.last {
                !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            if !out.isEmpty, let first = part.unicodeScalars.first {
                let cjkEnd = (out.unicodeScalars.last.map(CJK.isCJKPunctuation) ?? false) || (lastText.map(CJK.isCJK) ?? false)
                out += cjkEnd && (CJK.isCJK(first) || CJK.isCJKPunctuation(first)) ? "" : " "
            }
            out += part
        }
        return out
    }
}

/// The file lane (one piece of file work at a time, in order of arrival).
public enum FileQueue {
    /// A new piece of work waits for another file when the lane holds anything besides this file's
    /// own transcription (which a restart in another language replaces).
    public static func waitsForOtherFile(piecesInLane: Int, ownPieceQueued: Bool) -> Bool {
        piecesInLane - (ownPieceQueued ? 1 : 0) > 0
    }
}
