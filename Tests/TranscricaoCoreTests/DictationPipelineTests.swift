// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var text: String
    var error: Error?
    var delay: Double = 0
    /// Language Whisper "detects" when none is requested.
    var detected: String? = "pt"
    /// Whisper's probability for `detected` (Automatic only).
    var confidence: Double?
    private(set) var requested: [String?] = []
    init(_ text: String) { self.text = text }
    func transcribe(_ samples: [Float], language: String?) async throws -> Transcript {
        requested.append(language)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        if let language { return Transcript(text: text, language: language) }
        return Transcript(text: text, language: detected, languageConfidence: confidence)
    }
}

final class FakeProcessor: TextProcessor, @unchecked Sendable {
    var transform: (String) -> String = { $0.uppercased() }
    var error: Error?
    var delay: Double = 0
    private(set) var selections: [String?] = []
    private(set) var languages: [String] = []
    func process(_ transcript: String, selection: String?, language: String) async throws -> String {
        selections.append(selection)
        languages.append(language)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        return transform(transcript)
    }
}

actor RecordingInserter: TextInserter {
    private(set) var inserted: [String] = []
    func insert(_ text: String) async { inserted.append(text) }
}

struct Boom: Error {}

final class DictationPipelineTests: XCTestCase {
    let speech: [Float] = (0..<16_000).map { 0.1 * sin(Float($0) * 0.0864) }

    func make(_ t: FakeTranscriber, _ p: FakeProcessor, ai: Bool = true, timeout: Double = 6,
              prepare: @escaping @Sendable () async throws -> Void = {}) -> (DictationPipeline, RecordingInserter) {
        let ins = RecordingInserter()
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: ins,
                                     processingTimeout: timeout, aiEnabled: { ai }, prepare: prepare)
        return (pipe, ins)
    }

    func testHappyPathInsertsProcessedText() async {
        let (pipe, ins) = make(FakeTranscriber("oi"), FakeProcessor())
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(r.raw, "oi")
        XCTAssertEqual(r.final, "OI")
        XCTAssertFalse(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["OI"])
    }

    func testSilenceIsDiscarded() async {
        let (pipe, ins) = make(FakeTranscriber("oi"), FakeProcessor())
        let outcome = await pipe.run([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(outcome, .discarded(.tooShortOrSilent))
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testHallucinationIsDiscarded() async {
        let (pipe, _) = make(FakeTranscriber("Legendas pela comunidade Amara.org"), FakeProcessor())
        let outcome = await pipe.run(speech)
        XCTAssertEqual(outcome, .discarded(.noSpeech))
    }

    func testProcessorErrorFallsBackToRaw() async {
        let p = FakeProcessor(); p.error = Boom()
        let (pipe, ins) = make(FakeTranscriber("oi tudo bem"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertTrue(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi tudo bem"])
    }

    func testProcessorTimeoutFallsBackToRaw() async {
        let p = FakeProcessor(); p.delay = 2
        let (pipe, ins) = make(FakeTranscriber("oi"), p, timeout: 0.2)
        let start = Date()
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertTrue(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testEmptyProcessorOutputFallsBackToRaw() async {
        let p = FakeProcessor(); p.transform = { _ in "  **  " }
        let (pipe, ins) = make(FakeTranscriber("oi"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertTrue(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    // MARK: fallback reasons (logged, never the text)

    func testSuccessHasNoFallbackReason() async {
        let (pipe, _) = make(FakeTranscriber("oi"), FakeProcessor())
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertNil(r.fallbackReason)
    }

    func testTruncatedOutputIsNeverPasted() async {
        let p = FakeProcessor(); p.error = OutputTruncatedError()
        let (pipe, ins) = make(FakeTranscriber("oi tudo bem"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertTrue(r.usedFallback)
        XCTAssertEqual(r.fallbackReason, .truncated)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi tudo bem"])
    }

    func testFallbackReasonTimeout() async {
        let p = FakeProcessor(); p.delay = 2
        let (pipe, _) = make(FakeTranscriber("oi"), p, timeout: 0.2)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(r.fallbackReason, .timeout)
    }

    func testFallbackReasonError() async {
        let p = FakeProcessor(); p.error = Boom()
        let (pipe, _) = make(FakeTranscriber("oi"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(r.fallbackReason, .error)
    }

    func testFallbackReasonEmpty() async {
        let p = FakeProcessor(); p.transform = { _ in "  **  " }
        let (pipe, _) = make(FakeTranscriber("oi"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(r.fallbackReason, .empty)
    }

    func testFallbackDecision() {
        XCTAssertEqual(FallbackReason(error: OutputTruncatedError()), .truncated)
        XCTAssertEqual(FallbackReason(error: TimeoutError()), .timeout)
        XCTAssertEqual(FallbackReason(error: Boom()), .error)
    }

    func testAIDisabledSkipsProcessor() async {
        let p = FakeProcessor(); p.error = Boom()
        let (pipe, ins) = make(FakeTranscriber("oi"), p, ai: false)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertFalse(r.aiEnabled)
        XCTAssertFalse(r.usedFallback)
        XCTAssertNil(r.fallbackReason)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testTranscriberErrorFails() async {
        let t = FakeTranscriber("x"); t.error = Boom()
        let (pipe, ins) = make(t, FakeProcessor())
        guard case .failed = await pipe.run(speech) else { return XCTFail() }
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testPrepareErrorFails() async {
        let (pipe, _) = make(FakeTranscriber("x"), FakeProcessor(), prepare: { throw Boom() })
        guard case .failed = await pipe.run(speech) else { return XCTFail() }
    }

    func testRunsAreSerializedInOrder() async {
        let t = FakeTranscriber("a")
        let p = FakeProcessor()
        let ins = RecordingInserter()
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: ins,
                                     processingTimeout: 6, aiEnabled: { true })
        p.delay = 0.3
        p.transform = { $0 }
        // First run is slow; second must wait for it and paste after it.
        let first = Task { await pipe.run(self.speech) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        t.text = "b"
        p.delay = 0
        let second = Task { await pipe.run(self.speech) }
        _ = await first.value
        _ = await second.value
        let got = await ins.inserted
        XCTAssertEqual(got, ["a", "b"])
    }

    func testNonCooperativeProcessorTimesOut() async {
        let ins = RecordingInserter()
        let pipe = DictationPipeline(transcriber: FakeTranscriber("oi"), processor: BlockingProcessor(),
                                     inserter: ins, processingTimeout: 0.2, aiEnabled: { true })
        let start = Date()
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertTrue(r.usedFallback)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testFinishCalledOnceOnSuccess() async {
        let counter = Counter()
        let pipe = DictationPipeline(transcriber: FakeTranscriber("oi"), processor: FakeProcessor(),
                                     inserter: RecordingInserter(), processingTimeout: 6,
                                     aiEnabled: { true }, finish: { counter.bump() })
        guard case .inserted = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(counter.value, 1)
    }

    func testFinishCalledOnceWhenTranscriberFails() async {
        let counter = Counter()
        let t = FakeTranscriber("x"); t.error = Boom()
        let pipe = DictationPipeline(transcriber: t, processor: FakeProcessor(),
                                     inserter: RecordingInserter(), processingTimeout: 6,
                                     aiEnabled: { true }, finish: { counter.bump() })
        guard case .failed = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(counter.value, 1)
    }

    func testFinishCalledOnceOnHallucinationDiscard() async {
        let counter = Counter()
        let pipe = DictationPipeline(transcriber: FakeTranscriber("Legendas pela comunidade Amara.org"),
                                     processor: FakeProcessor(), inserter: RecordingInserter(),
                                     processingTimeout: 6, aiEnabled: { true }, finish: { counter.bump() })
        let outcome = await pipe.run(speech)
        XCTAssertEqual(outcome, .discarded(.noSpeech))
        XCTAssertEqual(counter.value, 1)
    }

    func testFinishNotCalledOnSilence() async {
        let counter = Counter()
        let pipe = DictationPipeline(transcriber: FakeTranscriber("oi"), processor: FakeProcessor(),
                                     inserter: RecordingInserter(), processingTimeout: 6,
                                     aiEnabled: { true }, finish: { counter.bump() })
        let outcome = await pipe.run([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(outcome, .discarded(.tooShortOrSilent))
        XCTAssertEqual(counter.value, 0)
    }

    func testFinishNotCalledWhenPrepareThrows() async {
        let counter = Counter()
        let ins = RecordingInserter()
        let pipe = DictationPipeline(transcriber: FakeTranscriber("oi"), processor: FakeProcessor(),
                                     inserter: ins, processingTimeout: 6, aiEnabled: { true },
                                     prepare: { throw Boom() }, finish: { counter.bump() })
        guard case .failed = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(counter.value, 0)
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    // MARK: edit by voice (editable selection)

    func sel(_ text: String) -> @Sendable () async -> CapturedSelection { { .selected(text, .editable) } }

    func notPasted(_ outcome: PipelineOutcome) -> (DictationResult, String?)? {
        if case .notPasted(let r, let msg) = outcome { return (r, msg) }
        return nil
    }

    func testSelectionIsPassedToProcessorAndEditReplacesIt() async {
        let p = FakeProcessor(); p.transform = { _ in "Texto editado." }
        let (pipe, ins) = make(FakeTranscriber("deixa mais formal"), p)
        guard case .inserted(let r) = await pipe.run(speech, selection: sel("e aí, blz?")) else { return XCTFail() }
        XCTAssertEqual(p.selections, ["e aí, blz?"])
        XCTAssertEqual(r.final, "Texto editado.")
        XCTAssertEqual(r.editedSelection, true)
        XCTAssertNil(r.pasted)
        let got = await ins.inserted
        XCTAssertEqual(got, ["Texto editado."])
    }

    func testEditIsNotPastedWhenTheSelectionChanged() async {
        let p = FakeProcessor(); p.transform = { _ in "Paragraph one." }
        let (pipe, ins) = make(FakeTranscriber("traduz pro inglês"), p)
        let asked = Recorder()
        guard let (r, msg) = notPasted(await pipe.run(speech, selection: sel("Parágrafo um.\n"),
                                                      verifyEdit: { asked.add($0); return false })) else { return XCTFail() }
        XCTAssertEqual(asked.values, ["Parágrafo um.\n"], "checked against the captured selection")
        XCTAssertEqual(r.final, "Paragraph one.\n", "the edit is kept for the history")
        XCTAssertEqual(r.fallbackReason, .selectionChanged)
        XCTAssertEqual(r.editedSelection, true)
        XCTAssertEqual(r.pasted, false)
        XCTAssertEqual(msg, SelectionEdit.selectionChangedMessage)
        let got = await ins.inserted
        XCTAssertEqual(got, [], "never pasted over whatever is selected now")
    }

    func testVerifyEditIsNotAskedForDictationNorAnswers() async {
        let asked = Recorder()
        let (pipe, ins) = make(FakeTranscriber("oi"), FakeProcessor())
        guard case .inserted = await pipe.run(speech, verifyEdit: { asked.add($0); return false }) else { return XCTFail() }
        let got = await ins.inserted
        XCTAssertEqual(got, ["OI"], "plain dictation is unaffected")
        let (answering, _, _, _) = makeAnswering(FakeAnswerer())
        _ = await answering.run(speech, selection: { .selected("x", .readOnly) }, verifyEdit: { asked.add($0); return false })
        XCTAssertEqual(asked.values, [])
    }

    func testEditKeepsSelectionEdgeWhitespace() async {
        let p = FakeProcessor(); p.transform = { _ in "Novo parágrafo." }
        let (pipe, ins) = make(FakeTranscriber("melhora"), p)
        _ = await pipe.run(speech, selection: sel("velho paragrafo\n"))
        let got = await ins.inserted
        XCTAssertEqual(got, ["Novo parágrafo.\n"])
    }

    func testNoSelectionKeepsPlainDictation() async {
        let p = FakeProcessor()
        let (pipe, _) = make(FakeTranscriber("oi"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(p.selections, [nil])
        XCTAssertNil(r.editedSelection)
        XCTAssertNil(r.pasted)
    }

    func testEditFailureKeepsSpeechAndPastesNothing() async {
        for (error, reason) in [(Boom() as Error, FallbackReason.error), (OutputTruncatedError(), .truncated)] {
            let p = FakeProcessor(); p.error = error
            let (pipe, ins) = make(FakeTranscriber("traduz pro inglês"), p)
            guard let (r, msg) = notPasted(await pipe.run(speech, selection: sel("Bom dia"))) else { return XCTFail() }
            XCTAssertEqual(r.final, "traduz pro inglês") // the speech is kept for the history
            XCTAssertEqual(r.fallbackReason, reason)
            XCTAssertEqual(r.pasted, false)
            XCTAssertEqual(msg, SelectionEdit.failureMessage)
            let got = await ins.inserted
            XCTAssertEqual(got, [])
        }
    }

    func testEditEmptyOutputPastesNothing() async {
        let p = FakeProcessor(); p.transform = { _ in "  **  " }
        let (pipe, ins) = make(FakeTranscriber("resume"), p)
        guard let (r, _) = notPasted(await pipe.run(speech, selection: sel("texto"))) else { return XCTFail() }
        XCTAssertEqual(r.fallbackReason, .empty)
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testEditTimeoutPastesNothing() async {
        let p = FakeProcessor(); p.delay = 2
        let (pipe, ins) = make(FakeTranscriber("resume"), p, timeout: 0.2)
        let start = Date()
        guard let (r, _) = notPasted(await pipe.run(speech, selection: sel("abc"))) else { return XCTFail() }
        XCTAssertEqual(r.fallbackReason, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testEscCancelsEditInFlight() async {
        let p = FakeProcessor(); p.delay = 3
        let (pipe, ins) = make(FakeTranscriber("resume"), p)
        let start = Date()
        let run = Task { await pipe.run(self.speech, selection: self.sel("abc")) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await pipe.cancelSelectionWork()
        guard let (r, msg) = notPasted(await run.value) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(r.fallbackReason, .cancelled)
        XCTAssertNil(msg, "Esc is the user's own choice: no error pill")
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testClosingThePanelNeverCancelsAnEdit() async {
        let p = FakeProcessor(); p.delay = 0.4; p.transform = { _ in "Editado." }
        let (pipe, ins) = make(FakeTranscriber("melhora"), p)
        let run = Task { await pipe.run(self.speech, selection: self.sel("abc")) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        await pipe.cancelAnswerWork() // a late close of the previous clip's answer panel (m2)
        guard case .inserted(let r) = await run.value else { return XCTFail() }
        XCTAssertNil(r.fallbackReason)
        let got = await ins.inserted
        XCTAssertEqual(got, ["Editado."])
    }

    func testClosingThePanelCancelsTheAnswer() async {
        let a = FakeAnswerer(); a.delay = 3
        let (pipe, _, pres, _) = makeAnswering(a)
        let start = Date()
        let run = Task { await pipe.run(self.speech, selection: { .selected("x", .readOnly) }) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await pipe.cancelAnswerWork()
        guard let (r, _) = notPasted(await run.value) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(r.fallbackReason, .cancelled)
        XCTAssertEqual(pres.events.last, "fail:\(SelectionEdit.answerFailureMessage)")
    }

    func testEscDoesNotCancelPlainDictation() async {
        let p = FakeProcessor(); p.delay = 0.4
        let (pipe, ins) = make(FakeTranscriber("oi"), p)
        let run = Task { await pipe.run(self.speech) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        await pipe.cancelSelectionWork()
        guard case .inserted(let r) = await run.value else { return XCTFail() }
        XCTAssertNil(r.fallbackReason)
        let got = await ins.inserted
        XCTAssertEqual(got, ["OI"])
    }

    func testAIDisabledWithSelectionPastesRawDictation() async {
        let p = FakeProcessor()
        let probe = Counter()
        let (pipe, ins) = make(FakeTranscriber("oi"), p, ai: false)
        guard case .inserted(let r) = await pipe.run(speech, selection: {
            probe.bump(); return .selected("sel", .editable)
        }) else { return XCTFail() }
        XCTAssertEqual(probe.value, 0, "selection is not even awaited with the AI off")
        XCTAssertNil(r.editedSelection)
        XCTAssertEqual(p.selections, [])
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testTooLongSelectionIsPlainDictation() async {
        let p = FakeProcessor()
        let (pipe, ins) = make(FakeTranscriber("oi"), p)
        let long = String(repeating: "a", count: SelectionEdit.maxCharacters + 1)
        guard case .inserted(let r) = await pipe.run(speech, selection: sel(long)) else { return XCTFail() }
        XCTAssertEqual(p.selections, [nil])
        XCTAssertNil(r.editedSelection)
        let got = await ins.inserted
        XCTAssertEqual(got, ["OI"])
    }

    func testSlowCaptureIsStillAwaited() async {
        let p = FakeProcessor(); p.transform = { _ in "Editado." }
        let (pipe, ins) = make(FakeTranscriber("melhora"), p)
        _ = await pipe.run(speech, selection: {
            try? await Task.sleep(nanoseconds: 600_000_000) // slower than the old 0.3 s cap
            return .selected("texto", .editable)
        })
        XCTAssertEqual(p.selections, ["texto"])
        let got = await ins.inserted
        XCTAssertEqual(got, ["Editado."])
    }

    func testStuckCaptureNeverPastesOverTheSelection() async {
        let p = FakeProcessor()
        let (pipe, ins) = make(FakeTranscriber("deixa mais formal"), p)
        let start = Date()
        guard let (r, msg) = notPasted(await pipe.run(speech, selection: {
            try? await Task.sleep(nanoseconds: 5_000_000_000); return .selected("tarde", .editable)
        })) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(start), SelectionEdit.captureWait + 1)
        XCTAssertEqual(r.fallbackReason, .selectionUnknown)
        XCTAssertEqual(r.final, "deixa mais formal")
        XCTAssertEqual(msg, SelectionEdit.unknownSelectionMessage)
        XCTAssertEqual(p.selections, [])
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    // MARK: read-only selection → answer in the panel

    func makeAnswering(_ a: FakeAnswerer, ai: Bool = true, timeout: Double = 6)
        -> (DictationPipeline, RecordingInserter, RecordingPresenter, FakeProcessor) {
        let ins = RecordingInserter(), pres = RecordingPresenter(), p = FakeProcessor()
        let pipe = DictationPipeline(transcriber: FakeTranscriber("traduz pra português"), processor: p,
                                     inserter: ins, answerer: a, presenter: pres,
                                     processingTimeout: timeout, aiEnabled: { ai })
        return (pipe, ins, pres, p)
    }

    func testReadOnlySelectionIsAnsweredInThePanelNeverPasted() async {
        let a = FakeAnswerer(); a.chunks = ["Acabamos ", "de lançar."]
        let (pipe, ins, pres, p) = makeAnswering(a)
        guard let (r, msg) = notPasted(await pipe.run(speech, selection: { .selected("Just shipped.", .readOnly) })) else {
            return XCTFail()
        }
        XCTAssertEqual(a.calls.first?.selection, "Just shipped.")
        XCTAssertEqual(a.calls.first?.request, "traduz pra português")
        XCTAssertEqual(r.final, "Acabamos de lançar.")
        XCTAssertEqual(r.answeredSelection, true)
        XCTAssertEqual(r.pasted, false)
        XCTAssertNil(msg)
        XCTAssertEqual(p.selections, [], "the edit/dictation prompt is not used")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(pres.events, ["begin", "update:Acabamos ", "update:Acabamos de lançar.", "finish:Acabamos de lançar."])
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testAnswerFailureShowsErrorInThePanel() async {
        let a = FakeAnswerer(); a.error = Boom()
        let (pipe, ins, pres, _) = makeAnswering(a)
        guard let (r, msg) = notPasted(await pipe.run(speech, selection: { .selected("x", .readOnly) })) else {
            return XCTFail()
        }
        XCTAssertEqual(r.fallbackReason, .error)
        XCTAssertNil(msg, "the error is shown inside the panel, not in the HUD")
        XCTAssertEqual(pres.events, ["begin", "fail:\(SelectionEdit.answerFailureMessage)"])
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testReadOnlySelectionIgnoredWithAIOff() async {
        let a = FakeAnswerer()
        let (pipe, ins, pres, _) = makeAnswering(a, ai: false)
        guard case .inserted = await pipe.run(speech, selection: { .selected("x", .readOnly) }) else { return XCTFail() }
        XCTAssertTrue(a.calls.isEmpty)
        XCTAssertEqual(pres.events, [])
        let got = await ins.inserted
        XCTAssertEqual(got, ["traduz pra português"])
    }

    func testReadOnlySelectionWithoutAnswererIsDictation() async {
        let p = FakeProcessor()
        let (pipe, ins) = make(FakeTranscriber("oi"), p)
        guard case .inserted = await pipe.run(speech, selection: { .selected("x", .readOnly) }) else { return XCTFail() }
        XCTAssertEqual(p.selections, [nil])
        let got = await ins.inserted
        XCTAssertEqual(got, ["OI"])
    }

    func testSelectionPlan() {
        typealias P = DictationPipeline
        XCTAssertEqual(P.plan(.none, aiActive: true, canAnswer: true), .dictation)
        XCTAssertEqual(P.plan(.unknown, aiActive: true, canAnswer: true), .doNotTouch)
        XCTAssertEqual(P.plan(.unknown, aiActive: false, canAnswer: true), .dictation)
        XCTAssertEqual(P.plan(.selected("a", .editable), aiActive: true, canAnswer: false), .edit("a"))
        XCTAssertEqual(P.plan(.selected("a", .editable), aiActive: false, canAnswer: true), .dictation)
        XCTAssertEqual(P.plan(.selected("a", .readOnly), aiActive: true, canAnswer: true), .answer("a"))
        XCTAssertEqual(P.plan(.selected("a", .readOnly), aiActive: true, canAnswer: false), .dictation)
        XCTAssertEqual(P.plan(.selected("a", .readOnly), aiActive: false, canAnswer: true), .dictation)
        XCTAssertEqual(P.plan(.selected("  ", .readOnly), aiActive: true, canAnswer: true), .dictation)
    }
}

/// Processor that ignores cancellation and blocks its thread.
final class BlockingProcessor: TextProcessor, @unchecked Sendable {
    func process(_ transcript: String, selection: String?, language: String) async throws -> String {
        Thread.sleep(forTimeInterval: 1.5)
        return transcript
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func bump() { lock.withLock { _value += 1 } }
}

final class FakeAnswerer: SelectionAnswering, @unchecked Sendable {
    var chunks: [String] = ["Resposta."]
    var error: Error?
    var delay: Double = 0
    private(set) var calls: [(request: String, selection: String)] = []
    private(set) var languages: [String] = []
    func answer(_ request: String, about selection: String, language: String,
                onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        calls.append((request, selection))
        languages.append(language)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        var text = ""
        for c in chunks { text += c; onPartial(text) }
        return text
    }
}

final class RecordingPresenter: AnswerPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    private func add(_ e: String) { lock.withLock { _events.append(e) } }
    func begin() { add("begin") }
    func update(_ partial: String) { add("update:\(partial)") }
    func finish(_ text: String) { add("finish:\(text)") }
    func fail(_ message: String) { add("fail:\(message)") }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func add(_ v: String) { lock.withLock { _values.append(v) } }
}

/// The dictation language reaches Whisper, and the language spoken reaches the text model.
final class DictationPipelineLanguageTests: XCTestCase {
    let speech: [Float] = (0..<16_000).map { 0.1 * sin(Float($0) * 0.0864) }

    func testDefaultIsPortugueseAsBefore() async {
        let t = FakeTranscriber("oi"), p = FakeProcessor()
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(), aiEnabled: { true })
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(t.requested, ["pt"])
        XCTAssertEqual(p.languages, ["pt"])
        XCTAssertEqual(r.language, "pt")
    }

    func testFixedLanguageGoesToWhisperAndThePrompt() async {
        let t = FakeTranscriber("hello"), p = FakeProcessor()
        t.detected = "de" // ignored: the language was fixed
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                     aiEnabled: { true }, dictationLanguage: { "en" })
        _ = await pipe.run(speech)
        _ = await pipe.run(speech, selection: { .selected("hi", .editable) })
        XCTAssertEqual(t.requested, ["en", "en"])
        XCTAssertEqual(p.languages, ["en", "en"])
    }

    func testAutomaticUsesTheDetectedLanguage() async {
        let t = FakeTranscriber("bonjour"), p = FakeProcessor()
        t.detected = "fr"
        t.confidence = 0.97
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                     aiEnabled: { true }, dictationLanguage: { nil })
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(t.requested, [nil])
        XCTAssertEqual(p.languages, ["fr"])
        XCTAssertEqual(r.language, "fr")
    }

    /// "No AI" and the model's fallback paste Whisper's text: Chinese gets Simplified characters and
    /// full-width punctuation; the model's own output and other languages are untouched.
    func testRawChineseIsSimplifiedWhenTheModelDoesNotWriteIt() async {
        func run(ai: Bool, fails: Bool = false, language: String?, detected: String? = nil) async -> String? {
            let t = FakeTranscriber("會議資料, 明天發?"), p = FakeProcessor()
            t.detected = detected
            p.transform = { $0 }
            if fails { p.error = Boom() }
            let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                         aiEnabled: { ai }, dictationLanguage: { language })
            guard case .inserted(let r) = await pipe.run(speech) else { return nil }
            return r.final
        }
        let noAI = await run(ai: false, language: "zh")
        XCTAssertEqual(noAI, "会议资料，明天发？")
        let detected = await run(ai: false, language: nil, detected: "zh")
        XCTAssertEqual(detected, "会议资料，明天发？")
        let fallback = await run(ai: true, fails: true, language: "zh")
        XCTAssertEqual(fallback, "会议资料，明天发？")
        let model = await run(ai: true, language: "zh")
        XCTAssertEqual(model, "會議資料, 明天發?", "the model's output is pasted as it wrote it")
        let otherLanguage = await run(ai: false, language: "ja")
        XCTAssertEqual(otherLanguage, "會議資料, 明天發?")
        // Japanese in kanji only, labeled ja in Automatic: pasted as Whisper wrote it.
        for kanji in ["新宿駅", "会議室予約"] {
            let t = FakeTranscriber(kanji), p = FakeProcessor()
            t.detected = "ja"
            let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                         aiEnabled: { false }, dictationLanguage: { nil })
            guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
            XCTAssertEqual(r.final, kanji)
        }
    }

    /// Automatic: a low-confidence "en" label gets the neutral rules (the English examples
    /// translated a mislabeled Spanish clip); a confident one keeps its prompt.
    func testAutomaticLabelWithExamplesNeedsConfidence() async {
        let t = FakeTranscriber("necesito que me llames"), p = FakeProcessor()
        t.detected = "en"
        t.confidence = 0.45
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                     aiEnabled: { true }, dictationLanguage: { nil })
        _ = await pipe.run(speech)
        t.confidence = 0.97
        _ = await pipe.run(speech)
        XCTAssertEqual(p.languages, ["", "en"])
    }

    func testAutomaticWithNothingDetectedKeepsTheSpokenLanguage() async {
        let t = FakeTranscriber("hallo"), p = FakeProcessor()
        t.detected = nil
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                     aiEnabled: { true }, dictationLanguage: { nil })
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(p.languages, [""])
        XCTAssertNil(r.language)
    }

    func testAutomaticPortugueseNeedsConfidenceForThePortuguesePrompt() async {
        // A short Spanish clip labeled "pt" must not get the prompt that says "português do Brasil".
        let t = FakeTranscriber("muchas gracias por todo"), p = FakeProcessor()
        t.detected = "pt"
        t.confidence = 0.55
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                     aiEnabled: { true }, dictationLanguage: { nil })
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        t.confidence = 0.97
        _ = await pipe.run(speech)
        XCTAssertEqual(p.languages, ["", "pt"])
        XCTAssertEqual(r.language, "pt", "the result still reports what Whisper detected")
    }

    func testFixedPortugueseIgnoresConfidence() async {
        let t = FakeTranscriber("oi"), p = FakeProcessor()
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: RecordingInserter(),
                                     aiEnabled: { true }, dictationLanguage: { "pt" })
        _ = await pipe.run(speech)
        XCTAssertEqual(p.languages, ["pt"])
    }

    func testAnswersUseTheSpokenLanguage() async {
        let t = FakeTranscriber("was steht hier"), a = FakeAnswerer()
        t.detected = "de"
        let pipe = DictationPipeline(transcriber: t, processor: FakeProcessor(), inserter: RecordingInserter(),
                                     answerer: a, aiEnabled: { true }, dictationLanguage: { nil })
        _ = await pipe.run(speech, selection: { .selected("Hello", .readOnly) })
        XCTAssertEqual(a.languages, ["de"])
    }
}
