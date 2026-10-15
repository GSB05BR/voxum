// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct StageTimings: Codable, Equatable, Sendable {
    public var transcribe: Double
    public var process: Double
    public var total: Double

    public init(transcribe: Double, process: Double, total: Double) {
        self.transcribe = transcribe
        self.process = process
        self.total = total
    }
}

/// Why the raw transcript was used instead of the text model's output.
public enum FallbackReason: String, Codable, Equatable, Sendable {
    case timeout    // the model did not answer within the processing timeout
    case error      // the model threw
    case truncated  // generation hit maxTokens (cut output is never pasted)
    case empty      // nothing left after sanitizing
    case cancelled  // the user pressed Esc during an edit/answer
    case selectionUnknown // the selection capture never finished: nothing pasted over it
    case selectionChanged // the edit was ready but the selection changed: not pasted (final = the edit)

    public init(error: Error) {
        switch error {
        case is OutputTruncatedError: self = .truncated
        case is TimeoutError: self = .timeout
        case is CancellationError: self = .cancelled
        default: self = .error
        }
    }
}

public struct DictationResult: Codable, Equatable, Sendable {
    public var date: Date
    public var raw: String
    public var final: String
    public var aiEnabled: Bool
    public var usedFallback: Bool
    public var timings: StageTimings
    /// Set when `usedFallback`; optional so history written by older versions still decodes.
    public var fallbackReason: FallbackReason?
    /// True when the model edited (replaced) text selected in the focused app.
    public var editedSelection: Bool? = nil
    /// True when `final` is an answer about a read-only selection (shown in the panel).
    public var answeredSelection: Bool? = nil
    /// True when `raw` is a question asked with the question key and `final` its answer (shown in
    /// the panel, never pasted on its own; `final` is the question when no answer came).
    public var answeredQuestion: Bool? = nil
    /// false = nothing was pasted (failed edit, unreadable selection, answer); nil = pasted.
    public var pasted: Bool? = nil
    /// Language of the dictation (Whisper code: the chosen one, or the detected one in Automatic).
    public var language: String? = nil
    /// Set when this is a transcribed file (spec §5): its name. `raw` is Whisper's text, `final`
    /// the text as shown (organized, once "Organize with AI" ran); nothing is pasted.
    public var fileName: String? = nil
    /// A transcribed file's summary, once "Summarize" ran.
    public var summary: String? = nil

    public init(date: Date, raw: String, final: String, aiEnabled: Bool, usedFallback: Bool,
                timings: StageTimings, fallbackReason: FallbackReason? = nil) {
        self.date = date
        self.raw = raw
        self.final = final
        self.aiEnabled = aiEnabled
        self.usedFallback = usedFallback
        self.timings = timings
        self.fallbackReason = fallbackReason
    }
}

public enum DiscardReason: Equatable, Sendable {
    case tooShortOrSilent
    case noSpeech
}

public enum PipelineOutcome: Equatable, Sendable {
    case inserted(DictationResult)
    case discarded(DiscardReason)
    case failed(String)
    /// Nothing was pasted and the speech is kept (history): an edit that failed or a selection
    /// that could not be read (`hudMessage` set, the selection is intact), or an answer about a
    /// read-only selection (shown in the panel; `hudMessage` nil).
    case notPasted(DictationResult, hudMessage: String?)
}

/// audio → gate → Whisper → hallucination filter → (LLM with timeout → sanitize) → insert.
/// With a selection: editable → the model edits it and the result replaces it (a failure pastes
/// nothing); read-only → the model answers about it in the presenter (never pasted).
/// Runs are serialized: a clip finishing while another is processing is pasted after it.
public actor DictationPipeline {
    private let transcriber: Transcriber
    private let processor: TextProcessor
    private let answerer: SelectionAnswering?
    private let questioner: QuestionAnswering?
    private let presenter: AnswerPresenter
    private let inserter: TextInserter
    private let gate: SpeechGate
    private let processingTimeout: Double
    private let aiEnabled: @Sendable () -> Bool
    /// Whisper code of the dictation language; nil = Automatic (Whisper detects it).
    private let dictationLanguage: @Sendable () -> String?
    private let prepare: @Sendable () async throws -> Void
    /// Called once after a successful `prepare`, whatever the outcome that follows
    /// (lets the caller release a model lease taken in `prepare`).
    private let finish: @Sendable () async -> Void
    private var tail: Task<Void, Never>?
    /// Model work of the current run when it involves a selection (Esc may cancel it).
    private var selectionWork: Task<String, Error>?
    private var selectionWorkKind: SelectionWorkKind?
    enum SelectionWorkKind { case edit, answer }
    /// A question is between its transcription and its model work: an Esc landing then (before
    /// `selectionWork` exists) is remembered here instead of being lost.
    private var questionAwaitingModel = false
    private var questionCancelRequested = false

    public init(transcriber: Transcriber, processor: TextProcessor, inserter: TextInserter,
                answerer: SelectionAnswering? = nil, questioner: QuestionAnswering? = nil,
                presenter: AnswerPresenter = NoAnswerPresenter(),
                gate: SpeechGate = SpeechGate(), processingTimeout: Double = 6,
                aiEnabled: @escaping @Sendable () -> Bool,
                dictationLanguage: @escaping @Sendable () -> String? = { "pt" },
                prepare: @escaping @Sendable () async throws -> Void = {},
                finish: @escaping @Sendable () async -> Void = {}) {
        self.transcriber = transcriber
        self.processor = processor
        self.answerer = answerer
        self.questioner = questioner
        self.presenter = presenter
        self.inserter = inserter
        self.gate = gate
        self.processingTimeout = processingTimeout
        self.aiEnabled = aiEnabled
        self.dictationLanguage = dictationLanguage
        self.prepare = prepare
        self.finish = finish
    }

    /// `selection` yields what the concurrent capture found when the recording started; it is
    /// awaited only after transcription, and only if the AI is on.
    /// `verifyEdit(selected)` is asked right before an edit is pasted: false (the selection changed
    /// or cannot be confirmed) pastes nothing and keeps the edit in the history. Never called for
    /// plain dictation or answers.
    public func run(_ samples: [Float],
                    selection: @escaping @Sendable () async -> CapturedSelection = { .none },
                    verifyEdit: @escaping @Sendable (String) async -> Bool = { _ in true }) async -> PipelineOutcome {
        let previous = tail
        let job = Task { () -> PipelineOutcome in
            await previous?.value
            return await self.execute(samples, selection: selection, verifyEdit: verifyEdit)
        }
        tail = Task { _ = await job.value }
        return await job.value
    }

    /// Question mode (spec §4): transcribes the question and streams the answer into the presenter;
    /// nothing is ever pasted. `context` yields the concurrent selection capture (any selection,
    /// editable or not, is context; none or unknown = no context). `shouldAnswer` is asked once the
    /// question is transcribed, before the panel opens: false (Esc meanwhile) = no answer. Runs in
    /// order with dictations, under the same model lease (`prepare`/`finish`).
    public func ask(_ samples: [Float],
                    context: @escaping @Sendable () async -> CapturedSelection = { .none },
                    shouldAnswer: @escaping @Sendable () async -> Bool = { true }) async -> PipelineOutcome {
        let previous = tail
        let job = Task { () -> PipelineOutcome in
            await previous?.value
            return await self.executeQuestion(samples, context: context, shouldAnswer: shouldAnswer)
        }
        tail = Task { _ = await job.value }
        return await job.value
    }

    /// Esc: stops the model work of an edit or answer in flight (plain dictation is not affected).
    public func cancelSelectionWork() {
        if questionAwaitingModel { questionCancelRequested = true }
        selectionWork?.cancel()
    }

    /// The answer panel was closed: stops an answer in flight, never an edit (a close that lands
    /// after the answer finished must not cancel the next clip's edit).
    public func cancelAnswerWork() {
        guard selectionWorkKind == .answer else { return }
        selectionWork?.cancel()
    }

    private func execute(_ samples: [Float], selection: @escaping @Sendable () async -> CapturedSelection,
                         verifyEdit: @escaping @Sendable (String) async -> Bool) async -> PipelineOutcome {
        guard gate.shouldTranscribe(samples) else { return .discarded(.tooShortOrSilent) }
        let start = Date()

        do { try await prepare() } catch {
            return .failed(String(localized: "Couldn't load the models.", bundle: .main))
        }

        let outcome = await transcribeAndInsert(samples, selection: selection, verifyEdit: verifyEdit, start: start)
        await finish()
        return outcome
    }

    private func executeQuestion(_ samples: [Float], context: @escaping @Sendable () async -> CapturedSelection,
                                 shouldAnswer: @escaping @Sendable () async -> Bool) async -> PipelineOutcome {
        guard gate.shouldTranscribe(samples) else { return .discarded(.tooShortOrSilent) }
        // Unreachable from the app ("No AI" does not watch the question key).
        guard questioner != nil else { return .failed(SelectionEdit.answerFailureMessage) }
        let start = Date()
        do { try await prepare() } catch {
            return .failed(String(localized: "Couldn't load the models.", bundle: .main))
        }
        let outcome = await transcribeAndAnswer(samples, context: context, shouldAnswer: shouldAnswer, start: start)
        await finish()
        return outcome
    }

    private func transcribeAndAnswer(_ samples: [Float], context: @escaping @Sendable () async -> CapturedSelection,
                                     shouldAnswer: @escaping @Sendable () async -> Bool,
                                     start: Date) async -> PipelineOutcome {
        guard let questioner else { return .failed(SelectionEdit.answerFailureMessage) }
        let transcript: Transcript
        let requested = dictationLanguage()
        let t0 = Date()
        do { transcript = try await transcriber.transcribe(samples, language: requested) } catch {
            return .failed(String(localized: "Transcription failed.", bundle: .main))
        }
        let transcribeTime = Date().timeIntervalSince(t0)
        let raw = transcript.text
        // The answer follows the question's language exactly as a dictation does (the chosen one,
        // or the detected one through the confidence gate), never the interface language.
        let language = DictationLanguage.promptLanguage(requested: requested, detected: transcript.language,
                                                        confidence: transcript.languageConfidence, transcript: raw)
        let spoken = requested ?? transcript.language
        guard let question = HallucinationFilter.clean(raw) else { return .discarded(.noSpeech) }
        questionAwaitingModel = true
        questionCancelRequested = false
        defer { questionAwaitingModel = false; questionCancelRequested = false }

        var captured = CapturedSelection.none
        do {
            captured = try await withTimeout(seconds: SelectionEdit.captureWait) { await context() }
        } catch {
            captured = .unknown // a stuck capture: answer without context (nothing is pasted anyway)
        }
        let selected: String?
        if case .selected(let text, _) = captured { selected = SelectionEdit.usable(text) } else { selected = nil }

        let t1 = Date()
        func result(final: String, reason: FallbackReason?) -> DictationResult {
            var r = DictationResult(
                date: start, raw: question, final: final, aiEnabled: true, usedFallback: reason != nil,
                timings: StageTimings(transcribe: transcribeTime, process: Date().timeIntervalSince(t1),
                                      total: Date().timeIntervalSince(start)),
                fallbackReason: reason)
            r.language = spoken?.isEmpty == false ? spoken : nil
            r.answeredQuestion = true
            r.pasted = false
            return r
        }
        // Esc while the question was being transcribed: no panel, the question stays in History.
        // `questionCancelRequested` catches an Esc that lands while `shouldAnswer` is awaited.
        let wanted = await shouldAnswer()
        guard wanted, !questionCancelRequested else {
            return .notPasted(result(final: question, reason: .cancelled), hudMessage: nil)
        }
        questionAwaitingModel = false // from here an Esc finds `selectionWork` (set with no suspension)

        let presenter = self.presenter
        presenter.begin(kind: .question)
        var reason: FallbackReason?
        var final = question
        do {
            let out = try await runModel(selectionCharacters: selected?.count ?? 0, cancellable: .answer,
                                         timeout: QuestionPrompt.timeout) {
                try await questioner.ask(question, context: selected, language: language,
                                         onPartial: { presenter.update($0) })
            }
            let sanitized = OutputSanitizer.cleanAnswer(out)
            if sanitized.isEmpty { reason = .empty } else { final = sanitized }
        } catch {
            reason = FallbackReason(error: error)
        }
        if reason == nil { presenter.finish(final) } else { presenter.fail(SelectionEdit.answerFailureMessage) }
        return .notPasted(result(final: final, reason: reason), hudMessage: nil)
    }

    /// What the pipeline does with the capture (pure; AI off = the selection is ignored).
    enum SelectionPlan: Equatable {
        case dictation
        case edit(String)
        case answer(String)
        case doNotTouch // capture unknown: never paste over a selection that may exist
    }

    static func plan(_ captured: CapturedSelection, aiActive: Bool, canAnswer: Bool) -> SelectionPlan {
        guard aiActive else { return .dictation }
        switch captured {
        case .none: return .dictation
        case .unknown: return .doNotTouch
        case .selected(let text, .editable):
            return SelectionEdit.usable(text).map(SelectionPlan.edit) ?? .dictation
        case .selected(let text, .readOnly):
            guard canAnswer else { return .dictation }
            return SelectionEdit.usable(text).map(SelectionPlan.answer) ?? .dictation
        }
    }

    private func transcribeAndInsert(_ samples: [Float], selection: @escaping @Sendable () async -> CapturedSelection,
                                     verifyEdit: @escaping @Sendable (String) async -> Bool,
                                     start: Date) async -> PipelineOutcome {
        let transcript: Transcript
        let requested = dictationLanguage()
        let t0 = Date()
        do { transcript = try await transcriber.transcribe(samples, language: requested) } catch {
            return .failed(String(localized: "Transcription failed.", bundle: .main))
        }
        let transcribeTime = Date().timeIntervalSince(t0)
        let raw = transcript.text
        // The text model writes in the spoken language: the chosen one, else what Whisper detected
        // (a "pt" label only when Whisper is confident: the Portuguese prompt names the language).
        let language = DictationLanguage.promptLanguage(requested: requested, detected: transcript.language,
                                                        confidence: transcript.languageConfidence, transcript: raw)
        let spoken = requested ?? transcript.language

        guard let cleaned = HallucinationFilter.clean(raw) else { return .discarded(.noSpeech) }

        let useAI = aiEnabled()
        // AI off: the capture is not even awaited; the raw dictation replaces any selection.
        var captured = CapturedSelection.none
        if useAI {
            do {
                captured = try await withTimeout(seconds: SelectionEdit.captureWait) { await selection() }
            } catch {
                captured = .unknown
            }
        }
        let t1 = Date()
        func result(final: String, reason: FallbackReason?) -> DictationResult {
            var r = DictationResult(
                date: start, raw: cleaned, final: final, aiEnabled: useAI, usedFallback: reason != nil,
                timings: StageTimings(transcribe: transcribeTime, process: useAI ? Date().timeIntervalSince(t1) : 0,
                                      total: Date().timeIntervalSince(start)),
                fallbackReason: reason)
            r.language = spoken?.isEmpty == false ? spoken : nil
            return r
        }

        switch Self.plan(captured, aiActive: useAI, canAnswer: answerer != nil) {
        case .doNotTouch:
            var r = result(final: ChineseScript.rawForPaste(cleaned, language: language), reason: .selectionUnknown)
            r.pasted = false
            return .notPasted(r, hudMessage: SelectionEdit.unknownSelectionMessage)
        case .answer(let selected):
            return await answer(cleaned, about: selected, language: language, result: result)
        case .edit(let selected):
            let processor = self.processor
            var reason: FallbackReason?
            var final = cleaned
            do {
                let out = try await runModel(selectionCharacters: selected.count, cancellable: .edit) {
                    try await processor.process(cleaned, selection: selected, language: language)
                }
                let sanitized = OutputSanitizer.clean(out)
                if sanitized.isEmpty { reason = .empty } else { final = sanitized }
            } catch {
                reason = FallbackReason(error: error)
            }
            if let reason {
                // Never the raw speech over the user's text: it goes to the history and the
                // selection stays as it was.
                var r = result(final: ChineseScript.rawForPaste(cleaned, language: language), reason: reason)
                r.pasted = false
                return .notPasted(r, hudMessage: reason == .cancelled ? nil : SelectionEdit.failureMessage)
            }
            final = SelectionEdit.preservingEdges(of: selected, final)
            var r = result(final: final, reason: nil)
            r.editedSelection = true
            // Seconds have passed: the paste would replace whatever is selected NOW.
            guard await verifyEdit(selected) else {
                r.fallbackReason = .selectionChanged
                r.pasted = false
                r.timings.total = Date().timeIntervalSince(start)
                return .notPasted(r, hudMessage: SelectionEdit.selectionChangedMessage)
            }
            await inserter.insert(final)
            r.timings.total = Date().timeIntervalSince(start)
            return .inserted(r)
        case .dictation:
            var final = cleaned
            var reason: FallbackReason?
            if useAI {
                let processor = self.processor
                do {
                    let out = try await runModel(selectionCharacters: 0, cancellable: nil) {
                        try await processor.process(cleaned, selection: nil, language: language)
                    }
                    let sanitized = OutputSanitizer.clean(out)
                    if sanitized.isEmpty { reason = .empty } else { final = sanitized }
                } catch {
                    reason = FallbackReason(error: error)
                }
            }
            // Text the model did not write (AI off, or its fallback) is Whisper's: a Chinese one gets
            // Simplified characters and full-width punctuation, as the model's would (also the raw text
            // kept in History when nothing is pasted). v1 ships Simplified Chinese only: a
            // Traditional-Chinese user's raw text is converted too, like the model's output.
            if !useAI || reason != nil { final = ChineseScript.rawForPaste(final, language: language) }
            let r = result(final: final, reason: reason)
            await inserter.insert(final)
            var inserted = r
            inserted.timings.total = Date().timeIntervalSince(start)
            return .inserted(inserted)
        }
    }

    /// Read-only selection: stream the answer into the presenter; nothing is ever pasted.
    private func answer(_ request: String, about selected: String, language: String,
                        result: (String, FallbackReason?) -> DictationResult) async -> PipelineOutcome {
        guard let answerer else { return .discarded(.noSpeech) } // unreachable: plan checks canAnswer
        let presenter = self.presenter
        presenter.begin()
        var reason: FallbackReason?
        var final = request
        do {
            let out = try await runModel(selectionCharacters: selected.count, cancellable: .answer) {
                try await answerer.answer(request, about: selected, language: language,
                                          onPartial: { presenter.update($0) })
            }
            let sanitized = OutputSanitizer.clean(out)
            if sanitized.isEmpty { reason = .empty } else { final = sanitized }
        } catch {
            reason = FallbackReason(error: error)
        }
        if reason == nil { presenter.finish(final) } else { presenter.fail(SelectionEdit.answerFailureMessage) }
        var r = result(final, reason)
        r.answeredSelection = true
        r.pasted = false
        return .notPasted(r, hudMessage: nil)
    }

    /// Runs the model in a task this actor owns, so both the timeout and Esc stop it
    /// (`withTimeout` alone would only cancel its own wrapper).
    /// `cancellable`: the kind of selection work Esc (and, for answers, closing the panel) may
    /// stop; nil = plain dictation, never cancelled.
    /// `timeout`: overrides the edit/answer timeout (questions get `QuestionPrompt.timeout`).
    private func runModel(selectionCharacters: Int, cancellable: SelectionWorkKind?, timeout: Double? = nil,
                          _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        let work = Task { try await op() }
        if let cancellable { selectionWork = work; selectionWorkKind = cancellable }
        defer { if cancellable != nil { selectionWork = nil; selectionWorkKind = nil } }
        let timeout = timeout ?? SelectionEdit.processingTimeout(base: processingTimeout, selectionCharacters: selectionCharacters)
        do {
            return try await withTimeout(seconds: timeout) { try await work.value }
        } catch {
            work.cancel()
            throw error
        }
    }
}
