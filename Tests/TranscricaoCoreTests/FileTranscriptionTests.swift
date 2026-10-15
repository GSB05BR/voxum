// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

/// 16 kHz samples served a piece at a time, like the AVFoundation reader.
final class ArraySampleSource: AudioSampleSource {
    private let samples: [Float]
    private var position = 0
    private(set) var largestRead = 0
    let expectedSamples: Int?

    init(_ samples: [Float], expected: Int? = nil) {
        self.samples = samples
        expectedSamples = expected ?? samples.count
    }

    func read(maxSamples: Int) throws -> [Float] {
        let end = min(samples.count, position + maxSamples)
        defer { position = end }
        largestRead = max(largestRead, end - position)
        return Array(samples[position..<end])
    }
}

/// Records what each block was transcribed with.
final class BlockTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(samples: Int, language: String?)] = []
    var calls: [(samples: Int, language: String?)] { lock.withLock { _calls } }
    var text: (Int) -> String = { "Bloco \($0 + 1)." }
    var detected = "en"
    var confidence: Double? = 0.95
    var delay: UInt64 = 0

    func transcribe(_ samples: [Float], language: String?) async throws -> Transcript {
        let index = lock.withLock { () -> Int in
            _calls.append((samples.count, language))
            return _calls.count - 1
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let language { return Transcript(text: text(index), language: language) }
        return Transcript(text: text(index), language: detected, languageConfidence: confidence)
    }
}

final class FileTranscriptionTests: XCTestCase {
    static let rate = 16_000

    /// "Speech" (a loud tone) or silence, in seconds.
    static func audio(_ parts: [(seconds: Double, speech: Bool)]) -> [Float] {
        parts.flatMap { part -> [Float] in
            let n = Int(part.seconds * Double(rate))
            return part.speech ? (0..<n).map { 0.3 * sin(Float($0) * 0.07) } : [Float](repeating: 0, count: n)
        }
    }

    func testBlocksEndAtASilenceAndCoverTheWholeAudio() async throws {
        let samples = Self.audio([(55, true), (2, false), (70, true)])
        let source = ArraySampleSource(samples)
        let whisper = BlockTranscriber()
        let result = try await FileTranscription.transcribe(source, with: whisper, language: "pt")
        let lengths = whisper.calls.map(\.samples)
        XCTAssertEqual(lengths.reduce(0, +), samples.count)
        for n in lengths { XCTAssertLessThanOrEqual(n, 60 * Self.rate) }
        // The first block ends inside the 2 s pause, not mid-"word".
        XCTAssertGreaterThanOrEqual(lengths[0], 55 * Self.rate)
        XCTAssertLessThanOrEqual(lengths[0], 57 * Self.rate)
        XCTAssertEqual(result.seconds, 127, accuracy: 0.01)
        XCTAssertEqual(result.raw, (1...lengths.count).map { "Bloco \($0)." }.joined(separator: " "))
        // Memory: the file is read a few seconds at a time.
        XCTAssertLessThanOrEqual(source.largestRead, 5 * Self.rate)
    }

    func testAutomaticDecidesTheLanguageOnceOnTheFirstBlock() async throws {
        let whisper = BlockTranscriber()
        let result = try await FileTranscription.transcribe(
            ArraySampleSource(Self.audio([(150, true)])), with: whisper, language: nil)
        XCTAssertEqual(whisper.calls.map(\.language), [nil, "en", "en"])
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.promptLanguage, "en")

        let fixed = BlockTranscriber()
        let pt = try await FileTranscription.transcribe(ArraySampleSource(Self.audio([(150, true)])), with: fixed, language: "pt")
        XCTAssertEqual(fixed.calls.map(\.language), ["pt", "pt", "pt"])
        XCTAssertEqual(pt.language, "pt")
        XCTAssertEqual(pt.promptLanguage, "pt")
    }

    func testAnUnsureDetectionGetsTheNeutralPrompt() async throws {
        let whisper = BlockTranscriber()
        whisper.confidence = 0.5
        let result = try await FileTranscription.transcribe(ArraySampleSource(Self.audio([(20, true)])),
                                                            with: whisper, language: nil)
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.promptLanguage, "")
    }

    func testSilenceIsSkippedAndPhantomSentencesRemoved() async throws {
        let whisper = BlockTranscriber()
        whisper.text = { $0 == 0 ? "Olá a todos. Legendas pela comunidade Amara.org" : "Legendas pela comunidade Amara.org" }
        let result = try await FileTranscription.transcribe(
            ArraySampleSource(Self.audio([(65, false), (30, true), (65, false), (30, true)])), with: whisper, language: "pt")
        XCTAssertEqual(whisper.calls.count, 2, "silent blocks never reach Whisper")
        XCTAssertEqual(result.raw, "Olá a todos.")

        let silent = BlockTranscriber()
        let empty = try await FileTranscription.transcribe(ArraySampleSource(Self.audio([(30, false)])), with: silent, language: nil)
        XCTAssertTrue(silent.calls.isEmpty)
        XCTAssertEqual(empty.raw, "")
        XCTAssertNil(empty.language)
    }

    func testProgressGrowsAndEndsAtOne() async throws {
        var progress: [Double] = []
        var texts: [String] = []
        _ = try await FileTranscription.transcribe(ArraySampleSource(Self.audio([(200, true)])), with: BlockTranscriber(),
                                                   language: "en", onProgress: { progress.append($0) },
                                                   onText: { texts.append($0) })
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertTrue(progress.dropLast().allSatisfy { $0 < 1 })
        XCTAssertEqual(texts.count, 4)
        XCTAssertEqual(texts.last, "Bloco 1. Bloco 2. Bloco 3. Bloco 4.")
        // A source that does not know its length still ends at 1.
        var unknown: [Double] = []
        _ = try await FileTranscription.transcribe(ArraySampleSource(Self.audio([(90, true)]), expected: 0),
                                                   with: BlockTranscriber(), language: "en", onProgress: { unknown.append($0) })
        XCTAssertEqual(unknown.last, 1)
        XCTAssertEqual(unknown, unknown.sorted())
    }

    func testCancelStopsWithinTheCurrentBlock() async throws {
        let whisper = BlockTranscriber()
        whisper.delay = 300_000_000
        let samples = Self.audio([(600, true)]) // 10 blocks
        let task = Task {
            try await FileTranscription.transcribe(ArraySampleSource(samples), with: whisper, language: "pt")
        }
        try await Task.sleep(nanoseconds: 450_000_000) // inside the second block
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled transcription must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.2)
        XCTAssertEqual(whisper.calls.count, 2)
    }

    func testChineseIsNormalisedAndJoinedWithoutSpaces() async throws {
        let whisper = BlockTranscriber()
        whisper.detected = "zh"
        whisper.text = { $0 == 0 ? "今天天氣很好,我們走吧." : "然後回家" }
        let result = try await FileTranscription.transcribe(ArraySampleSource(Self.audio([(100, true)])),
                                                            with: whisper, language: nil)
        XCTAssertEqual(result.raw, "今天天氣很好,我們走吧.然後回家")
        XCTAssertEqual(result.text, "今天天气很好，我们走吧。然后回家")
        XCTAssertEqual(result.promptLanguage, "zh")
    }

    func testQuietestCut() {
        var s = [Float](repeating: 0.5, count: 10_000)
        for i in 6_000..<6_200 { s[i] = 0 }
        let cut = FileTranscription.quietestCut(s, in: 4_000..<10_000, window: 100)
        XCTAssertTrue((6_000..<6_200).contains(cut), "\(cut)")
        XCTAssertEqual(FileTranscription.quietestCut(s, in: 9_990..<10_000, window: 100), 10_000)
        XCTAssertEqual(FileTranscription.join(["a.", "b"]), "a. b")
        XCTAssertEqual(FileTranscription.join(["好。", "走"]), "好。走")
        XCTAssertEqual(FileTranscription.join(["OK", "走"]), "OK 走")
    }

    func testAFileJobIsOneTakeAtATime() {
        // While a file runs, both keys are refused.
        for kind in [TakeKind.dictation, .question, .file] {
            XCTAssertFalse(TakeArbiter.canStart(kind, status: .ready, dictationsInFlight: 0, questionsInFlight: 0, filesInFlight: 1))
        }
        // A file waits for everything else, and for the models.
        XCTAssertTrue(TakeArbiter.canStart(.file, status: .ready, dictationsInFlight: 0, questionsInFlight: 0))
        XCTAssertFalse(TakeArbiter.canStart(.file, status: .processing, dictationsInFlight: 1, questionsInFlight: 0))
        XCTAssertFalse(TakeArbiter.canStart(.file, status: .processing, dictationsInFlight: 0, questionsInFlight: 1))
        XCTAssertFalse(TakeArbiter.canStart(.file, status: .recording(continuous: false), dictationsInFlight: 0, questionsInFlight: 0))
        XCTAssertFalse(TakeArbiter.canStart(.file, status: .preparing("x"), dictationsInFlight: 0, questionsInFlight: 0))
        XCTAssertFalse(TakeArbiter.canStart(.file, status: .error("x"), dictationsInFlight: 0, questionsInFlight: 0))
    }

    func testHistoryUpdatesAFileEntry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: url)
        var entry = DictationResult(date: Date(timeIntervalSince1970: 5), raw: "raw", final: "raw", aiEnabled: false,
                                    usedFallback: false, timings: StageTimings(transcribe: 1, process: 0, total: 1))
        entry.fileName = "reunião.m4a"
        entry.pasted = false
        store.append(entry)
        var organized = entry
        organized.final = "Organized."
        organized.summary = "- Point"
        store.update(organized) { $0.date == entry.date && $0.fileName == entry.fileName }
        XCTAssertEqual(store.entries.count, 1)
        let reloaded = HistoryStore(fileURL: url).entries.first
        XCTAssertEqual(reloaded?.final, "Organized.")
        XCTAssertEqual(reloaded?.summary, "- Point")
        XCTAssertEqual(reloaded?.fileName, "reunião.m4a")
        // History written before files existed still decodes (the new fields are optional).
        let old = #"[{"date":"2026-10-01T10:00:00Z","raw":"a","final":"A","aiEnabled":true,"usedFallback":false,"timings":{"transcribe":1,"process":1,"total":2}}]"#
        try Data(old.utf8).write(to: url)
        XCTAssertNil(HistoryStore(fileURL: url).entries.first?.fileName)
    }
}

final class FileQueueTests: XCTestCase {
    func testANewFileBehindAnotherWaitsForTheOtherFile() {
        // File A transcribing (1 piece); file B opened: nothing of B's own in the lane yet.
        XCTAssertTrue(FileQueue.waitsForOtherFile(piecesInLane: 1, ownPieceQueued: false))
    }

    func testARestartOfTheOnlyJobJustWaits() {
        XCTAssertFalse(FileQueue.waitsForOtherFile(piecesInLane: 1, ownPieceQueued: true))
        XCTAssertFalse(FileQueue.waitsForOtherFile(piecesInLane: 0, ownPieceQueued: false))
    }

    func testARestartBehindAnotherFileWaitsForIt() {
        XCTAssertTrue(FileQueue.waitsForOtherFile(piecesInLane: 2, ownPieceQueued: true))
    }
}
