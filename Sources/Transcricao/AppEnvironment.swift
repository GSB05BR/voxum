// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import os
import ServiceManagement
import TranscricaoCore
import TranscricaoEngines
import UniformTypeIdentifiers

/// NSLog redacts its message as <private> on recent macOS; this keeps timing lines readable via `log show`.
/// Lines are prefixed with the app name ("Voxum: models ready").
private let logger = Logger(subsystem: AppIdentity.subsystem, category: "app")
func appLog(_ message: String) { logger.notice("\(AppIdentity.name, privacy: .public): \(message, privacy: .public)") }
/// An error's domain and code are public; its description, which can hold file paths (the user's
/// home folder), is private: redacted in `log show` and sysdiagnoses.
func appLog(_ message: String, error: Error) {
    let ns = error as NSError
    logger.notice("\(AppIdentity.name, privacy: .public): \(message, privacy: .public) (\(ns.domain, privacy: .public) \(ns.code, privacy: .public): \(String(describing: error), privacy: .private))")
}

@MainActor
final class AppEnvironment: StatusMenuActions {
    let state = AppState()
    let settings = Settings.shared
    let transcriber = WhisperKitTranscriber()
    let processor: MLXTextProcessor
    let residency: ModelResidency
    let history = HistoryStore(fileURL: ModelLocations.history)
    let recorder = AudioRecorder()
    let hotkey = HotkeyMonitor()
    let downloads = ModelDownloads()
    let updater: Updater
    private(set) var pipeline: DictationPipeline!
    private var cancellables = Set<AnyCancellable>()
    /// Text model being downloaded from Ajustes; applied once downloaded and idle.
    private var pendingTextModel: TextModelChoice?
    private var statusItem: StatusItemController?
    /// Clips handed to the pipeline whose `finish` has not run yet (dictations and questions).
    private var inFlight = 0
    /// The questions among them (0 or 1: one take at a time, see `TakeArbiter`).
    private var questionsInFlight = 0
    /// File work among them (0 or 1): a file being transcribed, organized or summarized. It
    /// counts in `inFlight` too, so model switches, deletions and relaunches wait for it.
    private var filesInFlight = 0
    /// The dictations among the clips in flight.
    private var dictationsInFlight: Int { inFlight - questionsInFlight - filesInFlight }
    /// Dictations and questions in flight, file work aside: what the HUD pill, the answer
    /// panel's "Paste" and the undo pill care about (file work never pastes).
    var clipsInFlight: Int { inFlight - filesInFlight }
    /// A dictation or question still processing or pasting (with its clipboard restore), or an answer
    /// being pasted: quitting or relaunching for an update now would lose it (see `WhenIdle`).
    var hasTakeInProgress: Bool { clipsInFlight > 0 || pastingAnswer }
    /// Set when a paste was skipped because the app was frontmost; surfaced via onFinished.
    private var pendingNotice: String?
    /// True while the current recording holds a residency lease (no idle unload mid-take).
    private var recordingHoldsModels = false
    /// Residency calls issued from here run in order (a release must never overtake its hold).
    private var residencyChain: Task<Void, Never>?

    // Hooks for HUD/sounds (Task 13). Semantics with overlapping clips:
    //  - onRecordingStarted(continuous, isStart): isStart = a recording began (sent `TriggerKey.startDelay` late, and only
    //    if it is still running, so the key used as a modifier gives no feedback: play the start sound + show
    //    the HUD); isStart = false: the running recording became continuous (HUD only, sent at once).
    //  - onLevel: mic level, only while recording.
    //  - onProcessing: a recording ended and its clip was handed to the pipeline.
    //  - onFinished(error): exactly one call per clip that ends (inserted/discarded -> nil, failed -> message),
    //    per cancelled recording (nil) and per mic start failure. It can arrive while a NEWER recording is
    //    active: check `state.status` — if it is `.recording`, do not hide the recording HUD (at most flash
    //    the error); if `.processing`, another clip is still running (or file work: see
    //    `clipsInFlight`); if `.ready`, everything is idle. Also once (nil) when file work ends with no
    //    clip in flight, so a pill a notice brought up during the file is hidden.
    var onRecordingStarted: ((_ continuous: Bool, _ isStart: Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onProcessing: (() -> Void)?
    var onFinished: ((_ errorMessage: String?) -> Void)?
    /// Opens the main window ("Abrir <name>…" menu item).
    var onShowMainWindow: (() -> Void)?
    /// Opens the first-run model chooser (while `state.setupPending`).
    var onShowModelSetup: (() -> Void)?
    /// Short HUD message outside a dictation (e.g. "Escolha os modelos primeiro").
    var onNotice: ((String) -> Void)?
    /// The list of unused models changed (a background scan finished with a different result).
    var onModelFilesChanged: (() -> Void)?
    /// "Apagar modelos não usados" in progress (blocks model switches, setup and preparation).
    private var deleteTask: Task<Void, Never>?
    /// The app is frontmost when a recording starts: give focus back to the previous app so the
    /// paste lands there (the HUD panel must stay visible).
    var onYieldFocus: (() -> Void)?
    /// Edit-by-voice hint for the HUD: true once text selected for the current recording was
    /// captured (the result will replace it), false when a new recording starts.
    var onEditModeChange: ((Bool) -> Void)?
    /// What the recording that just started does (the HUD labels a question), sent at its start.
    var onTakeKindChange: ((TakeKind) -> Void)?

    // Start sound/HUD and ⌘C-capture delay: `TriggerKey.startDelay` of the recording's key (long
    // enough to see a modifier use, ⌥E or right ⌘ + C, short enough to feel instant). Recording
    // itself starts immediately, and the paste path is unaffected.
    /// Identifies the current recording for the delayed start feedback.
    private var recordingID = 0
    /// The key held for the current recording (the ⌘C capture is posted around it: see
    /// `SyntheticEvent.postCommandWhileHolding`). Only this key's stop/cancel ends the recording.
    private var recordingKey: TriggerKey = .default
    /// What the current recording does: dictate (the dictation key) or ask (the question key).
    private var recordingKind: TakeKind = .dictation
    /// Recording id of a question whose processing Esc stopped before the answer started.
    private var cancelledQuestion: Int?
    /// Recording id of the question in flight (Esc targets it).
    private var questionClip: Int?
    /// Uptime when the current recording started.
    private var recordingStartedAt: TimeInterval = 0
    /// Text selected when the current recording started (edit by voice), captured concurrently.
    private var selectionTask: Task<SelectionCapture.Result, Never>?
    /// Later, better classifications of recordings' captures (Electron field upgraded to editable,
    /// or found empty, while the user speaks), by recording id; read by that clip's pipeline run,
    /// never waited for. A new key press does not clear them.
    private var selectionReclassified = SelectionReclassifications()
    /// Answer about a read-only selection (pasted only with its "Colar" button).
    let answerPanel = AnswerPanelController()
    /// The "Transcribe file…" windows (spec §5).
    private(set) lazy var files = FileTranscriptionController(runner: self)
    /// "Desfazer" after an edit by voice was pasted over a selection.
    let undoPill = UndoPillController()
    /// The edit the pill offers to undo: ⌘Z is sent only if it is provably still the last change.
    private struct UndoOffer {
        let pid: pid_t
        /// The text pasted over the selection.
        let text: String
        /// Uptime of its ⌘V (comparable with `HotkeyMonitor.lastOtherInputAt`).
        let pastedAt: TimeInterval
    }
    private var undoOffer: UndoOffer?
    /// Uptime of the last ⌘V of a dictation or an edit (not of "Colar").
    private var lastPasteAt: TimeInterval = 0
    /// Pastes an answer from the panel ("Colar"); same clipboard save/restore as a dictation.
    private var answerInserter = PasteboardInserter()
    /// "Colar" is bringing its app back or pasting: a dictation starting meanwhile must not take
    /// the selection with ⌘C (it would read or clobber the clipboard mid-paste).
    private var pastingAnswer = false
    /// Set when the executed download plan contained Whisper: its first load compiles the CoreML
    /// model for this Mac (~3 min), so the status must say so instead of looking stuck.
    private var whisperNeedsFirstLoad = false
    static let whisperFirstLoadMessage = String(localized: "Optimizing the voice model for this Mac (first time only, ~3 min)…")

    init(updater: Updater) {
        self.updater = updater
        processor = MLXTextProcessor(modelID: Settings.shared.textModel.repoID) // nil = "Sem IA"
        residency = ModelResidency(models: [transcriber, processor])
        let residency = self.residency
        let settings = self.settings
        var inserter = PasteboardInserter()
        inserter.onCopiedOnly = { [weak self] in self?.pendingNotice = String(localized: "Text copied — paste with ⌘V") }
        // A clip pasting while the user clicked into a streaming answer must not paste into it.
        let panel = answerPanel
        inserter.beforePaste = { panel.releaseKeyForPaste() }
        inserter.onPasted = { [weak self] in self?.lastPasteAt = ProcessInfo.processInfo.systemUptime }
        answerInserter.onCopiedOnly = { [weak self] in self?.onNotice?(String(localized: "Text copied — paste with ⌘V")) }
        pipeline = DictationPipeline(
            transcriber: transcriber,
            processor: processor,
            inserter: inserter,
            answerer: processor,
            questioner: processor,
            presenter: PanelAnswerPresenter(panel: answerPanel),
            aiEnabled: { settings.aiActive },
            dictationLanguage: { settings.dictationLanguage.whisperCode },
            prepare: { try await residency.beginUse() },
            finish: { await residency.endUse() })
        // While preparing (first run, missing files) the status line shows the download.
        // Delivered synchronously (no receive(on:)): a deferred delivery could land after the
        // download finished and overwrite "Preparando modelos…" for the whole first load.
        downloads.$progress.sink { [weak self] progress in
            MainActor.assumeIsolated {
                guard let self, let progress, case .preparing = self.state.status else { return }
                self.state.status = .preparing(progress.statusLine)
            }
        }.store(in: &cancellables)
    }

    func start() {
        statusItem = StatusItemController(state: state, settings: settings, actions: self)
        state.history = history.entries
        recorder.onLevel = { [weak self] level in self?.onLevel?(level) }
        let stopForLimit: () -> Void = { [weak self] in
            guard let self else { return }
            let key = self.recordingKey
            self.handle(.stopAndProcess)
            self.hotkey.reset(key) // continuous mode would otherwise stay latched (only this take's key)
        }
        recorder.onLimitReached = stopForLimit
        recorder.onInterrupted = stopForLimit // input device changed: keep what we have
        decideFirstRun()
        refreshUnusedModels() // the menu shows the cached list from its first open
        hotkey.setKeys(settings.watchedKeys)
        hotkey.onAction = { [weak self] action, key in self?.handle(action, key: key) }
        hotkey.onEscape = { [weak self] in self?.escapePressed() }
        hotkey.onOtherInput = { [weak self] event in self?.undoPill.userInput(event) }
        let pill = undoPill
        hotkey.isPassiveClick = { pill.contains($0) } // clicking "Desfazer" is not new input
        undoPill.onUndo = { [weak self] in self?.undoLastEdit() }
        answerPanel.onPaste = { [weak self] text in await self?.pasteAnswer(text) }
        answerPanel.onClose = { [weak self] in
            guard let self else { return }
            Task { await self.pipeline.cancelAnswerWork() } // never the next clip's edit
        }
        hotkey.onContinuousChange = { [weak self] continuous, key in
            guard let self, key == self.recordingKey else { return } // the other key's gesture: not this take
            if case .recording = self.state.status {} else { return }
            let next = DictationStatusLogic.afterContinuousChange(self.state.status, continuous: continuous)
            guard next != self.state.status else { return } // no real recording behind the double tap
            self.state.status = next
            self.onRecordingStarted?(true, false)
        }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        // The microphone prompt blocks until the user answers; don't hold model loading hostage to it.
        Task { state.micGranted = await Permissions.requestMicrophone() }
        state.accessibilityGranted = Permissions.accessibilityGranted
        if !state.accessibilityGranted { Permissions.promptAccessibility() }
        hotkey.start()
        pollAccessibilityUntilGranted()
        await residency.setOnChange { [weak self] event in
            Task { @MainActor in self?.residencyChanged(event) }
        }
        await residency.setPolicy(settings.idleUnload)
        if state.setupPending {
            state.status = .preparing(Self.awaitingSetupMessage) // the chooser starts the download
        } else {
            await prepareModels()
        }
    }

    static let awaitingSetupMessage = String(localized: "Choose the models to get started")

    /// First run: show the model chooser unless the configuration was confirmed before or the
    /// chosen models are already complete on disk (an existing install: confirmed silently).
    private func decideFirstRun() {
        let onDisk = ModelDownloader.plan(for: settings.textModel).isEmpty
        switch FirstRunDecision.decide(confirmed: settings.modelsConfirmed, chosenModelsOnDisk: onDisk) {
        case .showChooser:
            state.setupPending = true
            appLog("no confirmed model choice; showing the model chooser")
        case .confirmSilently:
            settings.modelsConfirmed = true
            appLog("models already on disk; model choice confirmed")
        case .proceed:
            break
        }
    }

    /// "Baixar e começar" in the first-run window. Returns true once the models are downloaded
    /// (loading then continues as on any launch); false if cancelled or failed (`downloads.failure`).
    func beginModelSetup(text: TextModelChoice, idleUnload: IdleUnloadPolicy) async -> Bool {
        guard state.setupPending, !downloads.isRunning, !state.deletingModels else { return false }
        settings.textModel = text
        processor.setModelID(text.repoID)
        applyWatchedKeys()
        setIdleUnload(idleUnload)
        state.status = .preparing(String(localized: "Downloading models…"))
        let setupPlan = ModelDownloader.plan(for: text)
        do {
            try await downloads.run(setupPlan.items)
        } catch {
            state.status = .preparing(Self.awaitingSetupMessage)
            return false
        }
        if setupPlan.items.contains(.whisper) { whisperNeedsFirstLoad = true }
        settings.modelsConfirmed = true
        state.setupPending = false
        appLog("model choice confirmed (\(text.shortName), idle \(idleUnload.title))")
        Task { await prepareModels() }
        return true
    }

    /// Accessibility is granted in System Settings while we run; poll so the menu updates.
    private func pollAccessibilityUntilGranted() {
        guard !state.accessibilityGranted else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if Permissions.accessibilityGranted {
                    self.state.accessibilityGranted = true
                    timer.invalidate()
                    // Global monitors registered before the grant may be inert; re-register.
                    self.hotkey.start()
                }
            }
        }
    }

    func prepareModels() async {
        state.status = .preparing(String(localized: "Preparing models…"))
        await deleteTask?.value // never download/load while model folders are being deleted
        // Missing files (e.g. deleted by hand): download them with progress before loading.
        let plan = ModelDownloader.plan(for: settings.textModel)
        if !plan.isEmpty {
            do {
                try await downloads.run(plan.items)
            } catch {
                state.status = .error(error is CancellationError ? String(localized: "download cancelled")
                                                                  : String(localized: "couldn't download the models"))
                return
            }
            if plan.items.contains(.whisper) { whisperNeedsFirstLoad = true }
            state.status = .preparing(String(localized: "Preparing models…"))
        }
        if whisperNeedsFirstLoad {
            state.status = .preparing(Self.whisperFirstLoadMessage)
            appLog("first Whisper load after download (CoreML compiles the model once)")
        }
        processor.onProgress = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .preparing = self.state.status else { return }
                self.state.status = .preparing(String(localized: "Downloading the text model… \(Int(fraction * 100))%"))
            }
        }
        do {
            try await residency.ensureLoaded()
            whisperNeedsFirstLoad = false
            state.status = DictationStatusLogic.afterPreparation(succeeded: true, inFlight: inFlight)
            appLog("models ready")
            refreshUnusedModels() // a download or a model switch changes what is unused
        } catch {
            appLog("model preparation failed", error: error)
            state.status = .error(String(localized: "\(DictationStatusLogic.prepareFailedMessage) (\(error.localizedDescription))"))
        }
    }

    /// Background load/unload (e.g. reload after idle unload): the idle icon shows "loading",
    /// a failed reload while idle becomes a retryable error. Recording/processing are never touched.
    private func residencyChanged(_ event: ResidencyEvent) {
        state.modelsLoading = event == .loading
        state.memory = ModelMemoryState(event)
        if event == .failed { appLog("model load failed") }
        state.status = DictationStatusLogic.afterResidencyEvent(state.status, event)
    }

    private func residencyOp(_ op: @escaping @Sendable (ModelResidency) async -> Void) {
        let previous = residencyChain
        let residency = self.residency
        residencyChain = Task { await previous?.value; await op(residency) }
    }

    private func releaseRecordingHold() {
        guard recordingHoldsModels else { return }
        recordingHoldsModels = false
        residencyOp { await $0.endUse() }
    }

    // MARK: - Dictation

    /// `key`: the trigger that fired (nil when not from a key, e.g. the 5-minute limit).
    func handle(_ action: HotkeyAction, key: TriggerKey? = nil) {
        switch action {
        case .startCapture:
            // A watched key that is neither the dictation key nor an available question key starts
            // nothing (unreachable today; never a dictation on the wrong key).
            let kind: TakeKind
            if let key {
                guard let known = TakeArbiter.kind(of: key, dictation: settings.dictationKey,
                                                   question: settings.questionAvailable ? settings.questionKey : nil) else {
                    hotkey.reset(key)
                    appLog("start refused: \(key.rawValue) is neither the dictation nor the question key")
                    return
                }
                kind = known
            } else {
                kind = .dictation
            }
            // A refused start must not leave the hotkey machine believing a recording runs
            // (a following double tap would otherwise latch "continuous" on nothing).
            // One take at a time: a question needs everything else finished, and nothing starts
            // while a question records or is answered (`TakeArbiter`).
            guard state.micGranted, state.accessibilityGranted,
                  TakeArbiter.canStart(kind, status: state.status, dictationsInFlight: dictationsInFlight,
                                       questionsInFlight: questionsInFlight, filesInFlight: filesInFlight) else {
                if let key { hotkey.reset(key) } else { hotkey.reset() } // only the refused key's gesture
                if state.setupPending { remindModelSetupIfHeld(key ?? settings.dictationKey) }
                else if let key, state.micGranted, state.accessibilityGranted, case .processing = state.status {
                    explainBusyIfHeld(key, refused: kind)
                }
                return
            }
            // Focus must return to the previous app so the paste does not land in our own window.
            // (NSApp.hide would also hide the HUD panel.)
            // The answer panel yields once the recording is confirmed (announceStartLater, before
            // any ⌘C), not here: the key used as a modifier (⌥+E) must not close it. At release it
            // only gives the keyboard back.
            let appWasActive = NSApp.isActive
            if appWasActive { onYieldFocus?() }
            Task { try? await residency.ensureLoaded() } // reload in parallel with speech if evicted
            do {
                try recorder.start()
                undoPill.dismiss() // a new dictation: the last edit's undo offer is gone
                undoOffer = nil
                state.status = .recording(continuous: false)
                // Lease: an idle unload must not fire mid-recording (released on stop/cancel;
                // the pipeline then takes its own lease for the clip).
                recordingHoldsModels = true
                residencyOp { await $0.hold() }
                recordingID += 1
                recordingKey = key ?? settings.dictationKey
                recordingKind = kind
                onTakeKindChange?(kind)
                recordingStartedAt = ProcessInfo.processInfo.systemUptime
                announceStartLater(recordingID)
                startSelectionCapture(recordingID, appWasActive: appWasActive)
            } catch {
                // Transient (e.g. headphones connecting): keep the current status, no lasting error.
                appLog("mic start failed", error: error)
                state.status = DictationStatusLogic.afterMicFailure(state.status)
                if let key { hotkey.reset(key) } else { hotkey.reset() } // this take's key only
                onFinished?(String(localized: "Microphone unavailable"))
            }

        case .stopAndProcess:
            guard case .recording = state.status,
                  TakeArbiter.applies(actionFrom: key, toTakeOf: recordingKey) else { return }
            // Released before its start was even announced: too short to keep, no processing pill.
            if recordingKey.cancelsStop(heldFor: ProcessInfo.processInfo.systemUptime - recordingStartedAt) {
                handle(.cancel)
                return
            }
            // The panel already yielded at the start confirmation; one that opened since (an earlier
            // clip's answer) stays open, but must not hold the keyboard when this clip pastes.
            answerPanel.releaseKeyForPaste()
            let samples = recorder.stop()
            releaseRecordingHold()
            let selection = selectionTask
            selectionTask = nil
            let clipID = recordingID
            let queuedAt = ProcessInfo.processInfo.systemUptime
            inFlight += 1
            state.status = .processing
            onProcessing?()
            if recordingKind == .question {
                ask(samples, clipID: clipID, selection: selection)
                return
            }
            Task {
                let outcome = await pipeline.run(samples, selection: { [self] in
                    let captured = await selection?.value.selection ?? .none
                    // Whatever classification exists now (the upgrade may still be running: not awaited).
                    return await latestSelection(clipID, captured)
                }, verifyEdit: { text in
                    // The edit replaces whatever is selected at paste time: check it is still the
                    // captured selection, in the same app.
                    guard let target = await selection?.value.target else { return false }
                    return await SelectionCapture.stillSelected(text, target: target)
                })
                // A clip that failed because the models are gone (reload after idle unload failed)
                // must surface as an error with "Tentar de novo", not as "Pronto".
                var modelsLost = false
                if case .failed = outcome { modelsLost = await !residency.isLoaded }
                // An edit pasted over the selection: offer to undo it in that app (verifyEdit just
                // checked that this app was frontmost with the same selection). Only if its ⌘V
                // really went out for this clip (not the copy-only fallback).
                var offer: UndoOffer?
                if case .inserted(let result) = outcome, result.editedSelection == true,
                   lastPasteAt >= queuedAt, let pid = await selection?.value.target?.pid {
                    offer = UndoOffer(pid: pid, text: result.final, pastedAt: lastPasteAt)
                }
                finish(outcome, modelsLost: modelsLost, undo: offer)
            }

        case .cancel:
            // Esc reaches every key's machine: only this take's key cancels it.
            guard case .recording = state.status,
                  TakeArbiter.applies(actionFrom: key, toTakeOf: recordingKey) else { return }
            recorder.cancel()
            releaseRecordingHold()
            selectionTask?.cancel()
            selectionTask = nil
            state.status = DictationStatusLogic.afterCancel(state.status, inFlight: inFlight)
            onFinished?(nil)
            // A notice held back for this recording (Colar dropped) must not surface later as the
            // error of an unrelated dictation.
            if let notice = pendingNotice { pendingNotice = nil; onNotice?(notice) }
        }
    }

    /// Question mode: transcribe the question, then stream the answer into the panel (never pasted
    /// on its own). Any selection captured during the recording, editable or not, is its context.
    private func ask(_ samples: [Float], clipID: Int, selection: Task<SelectionCapture.Result, Never>?) {
        questionsInFlight += 1
        questionClip = clipID
        cancelledQuestion = nil
        Task {
            let outcome = await pipeline.ask(samples, context: { [self] in
                let captured = await selection?.value.selection ?? .none
                return await latestSelection(clipID, captured)
            }, shouldAnswer: { [self] in
                await questionStillWanted(clipID)
            })
            var modelsLost = false
            if case .failed = outcome { modelsLost = await !residency.isLoaded }
            questionsInFlight = max(0, questionsInFlight - 1)
            if questionClip == clipID { questionClip = nil }
            finish(outcome, modelsLost: modelsLost)
        }
    }

    private func questionStillWanted(_ clipID: Int) -> Bool { cancelledQuestion != clipID }

    /// A key refused because another take is running: if it is still held after its start delay
    /// with nothing else typed (so not used as a modifier), say why nothing records. Shown in the
    /// panel while it streams an answer, else on the HUD.
    private func explainBusyIfHeld(_ key: TriggerKey, refused kind: TakeKind) {
        let pressedAt = ProcessInfo.processInfo.systemUptime
        let message = filesInFlight > 0
            ? Self.fileBusyMessage
            : questionsInFlight > 0
            ? String(localized: "Wait for the answer to finish (Esc stops it)")
            : String(localized: "Wait for the dictation to finish and try again")
        DispatchQueue.main.asyncAfter(deadline: .now() + key.startDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hotkey.heldKeys.contains(key), self.hotkey.lastOtherInputAt < pressedAt,
                      case .processing = self.state.status else { return }
                appLog("\(kind == .question ? "question" : "dictation") refused: \(self.filesInFlight > 0 ? "a file is being transcribed" : "another take is running")")
                if self.answerPanel.isVisible { self.answerPanel.showNotice(message) } else { self.onNotice?(message) }
            }
        }
    }

    /// Captures the selected text concurrently with the recording (never on the paste path).
    /// Skipped when the AI is off (the raw dictation just replaces the selection) and when the app
    /// was frontmost (focus is still being handed back, so the focused element would be our own
    /// window). While another clip is in flight only accessibility is read, no ⌘C (that clip's
    /// paste and clipboard restore could race it); its paste may change the selection, which the
    /// check before an edit's paste catches.
    /// A question captures the selection too (its context) whenever a text model can answer, even
    /// with "Organize with AI" off; it never shows the edit hint (nothing will replace the selection).
    private func startSelectionCapture(_ id: Int, appWasActive: Bool) {
        selectionTask?.cancel()
        selectionTask = nil
        onEditModeChange?(false)
        let question = recordingKind == .question
        guard question ? settings.questionAvailable : settings.aiActive, !appWasActive else { return }
        let allowCopy = inFlight == 0 && !pastingAnswer
        let started = Date()
        let trigger = recordingKey
        selectionTask = Task { @MainActor [weak self] in
            let result = await SelectionCapture.capture(trigger: trigger, triggerHeld: { [weak self] in
                self?.hotkey.heldKeys.contains(trigger) == true // real events only, never our own
            }, copyAllowed: allowCopy, confirmCopy: { [weak self] in
                // ⌘C only once the hold is clearly a dictation, not the key used as a modifier (⌥E, ⌘C…).
                let remaining = trigger.startDelay - Date().timeIntervalSince(started)
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                // A tap released before then is discarded by the speech gate anyway: no ⌘C for it.
                guard let self, !Task.isCancelled, self.recordingID == id,
                      case .recording = self.state.status else { return false }
                // The paste or edit of this dictation must not land in the answer panel.
                self.answerPanel.yieldForNewDictation()
                return true
            }, userInputSince: { [weak self] uptime in
                (self?.hotkey.lastOtherInputAt ?? 0) > uptime
            }, onUpgrade: { [weak self] better in
                guard let self else { return }
                // Stored even if a newer recording started: this clip may still be processing.
                self.selectionReclassified.store(better, for: id)
                if !question, self.recordingID == id, case .recording = self.state.status,
                   case .selected(let text, .editable) = better,
                   SelectionEdit.usable(text) != nil { self.onEditModeChange?(true) }
            })
            guard let self, !Task.isCancelled else { return .none }
            // HUD hint only for an editable selection the pipeline will actually edit.
            if !question, case .selected(let text, .editable) = result.selection, SelectionEdit.usable(text) != nil,
               self.recordingID == id { self.onEditModeChange?(true) }
            return result
        }
    }

    /// The hotkey before the models were chosen: if `key` is still held a moment later with no other
    /// key typed (so not used as a modifier, e.g. ⌥+E), say why nothing records and open the chooser.
    private func remindModelSetupIfHeld(_ key: TriggerKey) {
        let pressedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.setupPending, self.hotkey.heldKeys.contains(key),
                      self.hotkey.lastOtherInputAt < pressedAt else { return }
                self.onNotice?(String(localized: "Choose the models first"))
                self.onShowModelSetup?()
            }
        }
    }

    /// The capture of recording `id` as currently known: its reclassification if one arrived,
    /// else `captured`.
    private func latestSelection(_ id: Int, _ captured: CapturedSelection) -> CapturedSelection {
        selectionReclassified.take(id) ?? captured
    }

    static let colarHint = String(localized: "Click in a text box and tap Paste")

    /// "Colar" in the answer panel: pastes into the focused text field of the app in front now
    /// (the user may have clicked into another field or app first; the panel stays open on
    /// outside clicks). Nil = the paste went ahead (the panel closed); otherwise a message the
    /// panel shows inline and stays open. Nothing is pasted and the clipboard is not touched
    /// unless that focus is editable text, checked over accessibility (bounded): a ⌘V into a web
    /// page or PDF would do nothing, into a terminal it could run lines.
    private func pasteAnswer(_ text: String) async -> String? {
        func busyReason() -> String? {
            if case .recording = state.status { return String(localized: "Finish the dictation to paste.") }
            return clipsInFlight > 0 || pastingAnswer ? String(localized: "Wait for the dictation to finish to paste.") : nil
        }
        func frontmostPID() -> pid_t? {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return app.processIdentifier
        }
        if let reason = busyReason() { return reason }
        guard let pid = frontmostPID() else { return Self.colarHint }
        let facts = await SelectionCapture.pasteTargetFacts(pid: pid)
        guard PasteSafety.acceptsPaste(facts) else {
            appLog("Colar refused (focus is not editable text)")
            return Self.colarHint
        }
        if let reason = busyReason() { return reason }
        guard frontmostPID() == pid else { return Self.colarHint }
        pastingAnswer = true
        defer { pastingAnswer = false }
        answerPanel.close()
        // The panel just closed: let the keyboard settle back in the app's window.
        try? await Task.sleep(nanoseconds: 80_000_000)
        // A dictation started meanwhile, or another app came forward: never paste elsewhere.
        var recording = false
        if case .recording = state.status { recording = true }
        guard frontmostPID() == pid, inFlight == 0, !recording else {
            appLog("Colar dropped (focus or state changed)")
            let notice = String(localized: "Not pasted — answer in History")
            if recording { pendingNotice = notice } else { onNotice?(notice) } // after the recording
            return nil
        }
        appLog("answer pasted from the panel")
        await answerInserter.insert(text)
        return nil
    }

    /// "Desfazer" on the pill. ⌘Z is sent only if the edit is provably still the last change in
    /// that app: no key press or click since its paste, the same app in front, and its focused
    /// field shows the pasted text right before the cursor (read over accessibility, bounded).
    /// Anything else, including "can't tell", sends nothing: a ⌘Z that undoes the user's own
    /// typing would lose their work.
    private func undoLastEdit() {
        guard let offer = undoOffer else { return }
        undoOffer = nil
        let changed = String(localized: "Not undone — the text changed after the edit")
        func untouched() -> Bool {
            var recording = false
            if case .recording = state.status { recording = true }
            return !recording && clipsInFlight == 0
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == offer.pid
                && PasteSafety.undoAllowedByInput(lastOtherInputAt: hotkey.lastOtherInputAt, pastedAt: offer.pastedAt)
        }
        guard untouched() else {
            appLog("undo not sent (input or focus changed since the edit)")
            onNotice?(changed)
            return
        }
        Task { @MainActor in
            let read = await SelectionCapture.textBeforeCursor(pid: offer.pid, utf16Length: offer.text.utf16.count)
            let check = PasteSafety.undoCheck(pasted: offer.text, textBeforeCursor: read.text,
                                              selectionLength: read.selectionLength)
            guard check == .confirmed, untouched() else {
                appLog("undo not sent (\(check == .unreadable ? "text unreadable" : "text changed"))")
                onNotice?(check == .unreadable ? String(localized: "Not undone — couldn't check the text") : changed)
                return
            }
            SyntheticEvent.postCommand(key: SyntheticEvent.zKey)
            appLog("edit undone (⌘Z)")
        }
    }

    /// Esc anywhere: closes the answer panel and stops an edit/answer still generating.
    /// While recording, Esc only cancels the recording (through the hotkey machine; this runs
    /// before it): an earlier clip's answer still streaming in the panel is left alone.
    /// A question still being transcribed (no panel yet) is dropped: its answer never starts.
    private func escapePressed() {
        if case .recording = state.status { return }
        if answerPanel.isVisible { answerPanel.close() }
        guard case .processing = state.status else { return }
        if let clip = questionClip { cancelledQuestion = clip }
        Task { await pipeline.cancelSelectionWork() }
    }

    /// Plays the start sound and shows the HUD only if this recording survives the delay
    /// (the key used as a modifier, ⌥+E / ⌘+C, cancels it first and gets no feedback at all).
    private func announceStartLater(_ id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingKey.startDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      DictationStatusLogic.shouldAnnounceStart(recording: id, current: self.recordingID,
                                                               status: self.state.status),
                      case .recording(let continuous) = self.state.status else { return }
                // Confirmed dictation (not the key used as a modifier): the answer panel gives way now.
                self.answerPanel.yieldForNewDictation()
                self.onRecordingStarted?(continuous, true)
            }
        }
    }

    private func finish(_ outcome: PipelineOutcome, modelsLost: Bool, undo: UndoOffer? = nil) {
        var errorMessage: String?
        switch outcome {
        case .inserted(let result):
            history.append(result)
            state.history = history.entries
            appLog("transcribe \(String(format: "%.2f", result.timings.transcribe))s, process \(String(format: "%.2f", result.timings.process))s, total \(String(format: "%.2f", result.timings.total))s\(result.editedSelection == true ? " (edit)" : "")\(result.usedFallback ? " (fallback: \(result.fallbackReason?.rawValue ?? "?"))" : "")")
        case .discarded:
            break
        case .failed(let message):
            errorMessage = message
        case .notPasted(let result, let hudMessage):
            // Nothing was pasted (the selection, if any, is intact); the speech or the answer is
            // kept in the history.
            history.append(result)
            state.history = history.entries
            let what = result.answeredQuestion == true ? "question" : result.answeredSelection == true ? "answer" : "edit not applied"
            appLog("\(what): transcribe \(String(format: "%.2f", result.timings.transcribe))s, process \(String(format: "%.2f", result.timings.process))s\(result.fallbackReason.map { " (\($0.rawValue))" } ?? "")")
            errorMessage = hudMessage
        }
        inFlight = max(0, inFlight - 1)
        state.status = DictationStatusLogic.afterClipFinished(state.status, inFlight: inFlight, modelsLost: modelsLost)
        errorMessage = errorMessage ?? pendingNotice
        pendingNotice = nil
        onFinished?(errorMessage)
        // Only when the HUD spot is free: no newer recording and no other clip still processing.
        // And only if nothing was typed or clicked since the paste (e.g. the user's own ⌘Z, or
        // typing, while the processing pill was still up): Desfazer would undo that instead.
        if let undo, errorMessage == nil, inFlight == 0, case .ready = state.status,
           PasteSafety.undoAllowedByInput(lastOtherInputAt: hotkey.lastOtherInputAt, pastedAt: undo.pastedAt) {
            undoOffer = undo
            undoPill.show()
        }
    }

    // MARK: - StatusMenuActions

    /// The quick switch; with "Sem IA" there is no model to switch on (the controls are disabled).
    func toggleAI() {
        guard settings.textModel.usesAI else { return }
        settings.aiEnabled.toggle()
    }
    func toggleSounds() { settings.soundsEnabled.toggle() }

    func setIdleUnload(_ policy: IdleUnloadPolicy) {
        settings.idleUnload = policy
        Task { await residency.setPolicy(policy) }
    }

    func setTextModel(_ choice: TextModelChoice) {
        guard choice != settings.textModel else { return }
        // Never unload while recording/processing/preparing/downloading/deleting: ignore the click.
        guard isIdle else { return }
        if !ModelDownloader.isOnDisk(text: choice) {
            let plan = ModelDownloadPlan(text: choice, whisperOnDisk: true, textOnDisk: false)
            let free = ModelDownloader.freeBytes
            guard plan.fits(freeBytes: free) else {
                showAlert(String(localized: "Not enough free space"),
                          String(localized: "\(choice.shortName) needs ~\(ByteText.approx(plan.totalBytes)) (plus a margin of \(ByteText.approx(ModelDownloadPlan.headroomBytes))); free on disk: \(ByteText.approx(free ?? 0)). Free up space and try again."))
                return
            }
            // Download first; dictation keeps working with the current model meanwhile.
            pendingTextModel = choice
            Task {
                do { try await downloads.run([.text(choice)]) } catch {
                    if pendingTextModel == choice, downloads.failure == nil { pendingTextModel = nil } // cancelled
                    return
                }
                applyPendingTextModelWhenIdle(choice)
            }
            return
        }
        switchTextModel(choice)
    }

    /// The downloaded model is applied as soon as nothing is recording/processing.
    private func applyPendingTextModelWhenIdle(_ choice: TextModelChoice) {
        guard pendingTextModel == choice else { return }
        guard state.status == .ready, inFlight == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.applyPendingTextModelWhenIdle(choice) }
            }
            return
        }
        pendingTextModel = nil
        switchTextModel(choice)
    }

    private func switchTextModel(_ choice: TextModelChoice) {
        // Claim the state synchronously so a second click is rejected before the Task runs.
        state.status = .preparing(choice.usesAI ? String(localized: "Switching model…") : String(localized: "Turning off the AI…"))
        Task {
            await residency.unloadNow()
            // Persist and apply together so settings and processor.modelID always agree,
            // even if the load fails ("Tentar de novo" then retries this same model).
            // "Sem IA": no model id, so only Whisper is loaded.
            processor.setModelID(choice.repoID)
            settings.textModel = choice
            applyWatchedKeys() // "No AI" stops watching the question key; a model brings it back
            files.refresh() // "No AI" turns Organize and Summarize off in the file windows
            await prepareModels()
        }
    }

    func cancelDownload() {
        pendingTextModel = nil
        downloads.cancel()
    }

    /// "Tentar de novo" next to a failed download.
    func retryDownload() {
        // First run: the chooser owns that download; it keeps its error and its own retry button.
        if state.setupPending { onShowModelSetup?(); return }
        if let choice = pendingTextModel {
            // A model switch retried mid-dictation: keep the pending model and the error for later.
            guard isIdle else { onNotice?(String(localized: "Wait for the dictation to finish and try again")); return }
            downloads.clearFailure()
            pendingTextModel = nil
            setTextModel(choice)
            return
        }
        downloads.clearFailure()
        if case .error = state.status { retryPreparation() }
    }

    // MARK: - Unused models

    /// Last background scan (the menu and the window read this on every open/tick: walking the
    /// model folders is file-system work kept off the main thread). Asking starts a new scan;
    /// `onModelFilesChanged` fires when its result differs. Deletion itself rescans synchronously.
    func unusedModels() -> [UnusedModelFolder] {
        refreshUnusedModels()
        return unusedModelsCache
    }
    private var unusedModelsCache: [UnusedModelFolder] = []
    private var unusedScan: Task<Void, Never>?
    private var unusedRescanWanted = false

    private func refreshUnusedModels() {
        guard unusedScan == nil else { unusedRescanWanted = true; return }
        let hub = ModelLocations.hub, whisper = ModelLocations.whisper, keep = settings.textModel.repoID
        unusedScan = Task {
            let found = await Task.detached(priority: .utility) {
                UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: keep)
            }.value
            unusedScan = nil
            if found != unusedModelsCache {
                unusedModelsCache = found
                onModelFilesChanged?()
            }
            // Asked again meanwhile (files or the model in use may have changed): scan once more.
            if unusedRescanWanted { unusedRescanWanted = false; refreshUnusedModels() }
        }
    }

    private func scanUnusedModelsNow() -> [UnusedModelFolder] {
        UnusedModels.find(hub: ModelLocations.hub, whisperBase: ModelLocations.whisper,
                          keepRepoID: settings.textModel.repoID)
    }

    /// Lists the models the current configuration does not use and deletes them after an
    /// explicit confirmation. The models in use are never candidates (and are re-checked here).
    func deleteUnusedModels() {
        guard canDeleteModels else { return }
        let unused = scanUnusedModelsNow() // user-initiated: fresh, not the cached list
        guard !unused.isEmpty else { return }
        let total = unused.reduce(Int64(0)) { $0 + $1.bytes }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let size = ByteText.approx(total)
        alert.messageText = unused.count == 1
            ? String(localized: "Delete 1 unused model (\(size))?")
            : String(localized: "Delete \(unused.count) unused models (\(size))?")
        let inUse = settings.textModel.usesAI
            ? String(localized: "\(ModelCatalog.whisperTitle) and \(settings.textModel.shortName)")
            : String(localized: "\(ModelCatalog.whisperTitle) (with “No AI”, the text model also counts as unused)")
        alert.informativeText = unused.map { "• \($0.name) — \(ByteText.approx($0.bytes))" }.joined(separator: "\n")
            + "\n\n" + String(localized: "The files are deleted for good (they don't go to the Trash). In use and kept: \(inUse). To use a deleted model again, it is downloaded again.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        let delete = alert.addButton(withTitle: String(localized: "Delete"))
        delete.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // Things may have changed while the alert was open (a dictation, a download, a model
        // switch): check again, and delete only what is still unused.
        guard canDeleteModels else {
            showAlert(String(localized: "Nothing was deleted"),
                      String(localized: "\(AppIdentity.name) was busy (dictation, download or model switch). Try again in a moment."))
            return
        }
        let still = Set(scanUnusedModelsNow().flatMap(\.urls))
        let urls = unused.flatMap(\.urls).filter { still.contains($0) }
        state.deletingModels = true
        deleteTask = Task {
            let failures = await Task.detached(priority: .utility) { () -> [String] in
                var failed: [String] = []
                for url in urls {
                    do { try FileManager.default.removeItem(at: url) } catch {
                        appLog("could not delete \(url.lastPathComponent)", error: error)
                        failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return failed
            }.value
            appLog("deleted \(urls.count - failures.count) of \(urls.count) unused model folder(s)")
            state.deletingModels = false
            deleteTask = nil
            refreshUnusedModels() // measured again only now that the files are gone
            if !failures.isEmpty {
                showAlertWhenIdle(String(localized: "Some models couldn't be deleted"), failures.joined(separator: "\n"))
            }
        }
    }

    /// Deleting or switching models needs the app idle: nothing recording/processing/preparing/
    /// downloading/deleting.
    private var isIdle: Bool {
        state.status == .ready && inFlight == 0 && !downloads.isRunning && !state.deletingModels
    }
    private var canDeleteModels: Bool { isIdle }

    /// An alert nobody asked for right now (a background deletion failed) activates the app: never
    /// in the middle of a dictation (its paste would turn into "Texto copiado"), so it waits.
    private func showAlertWhenIdle(_ title: String, _ text: String) {
        let dictating: Bool
        switch state.status {
        case .recording, .processing: dictating = true
        default: dictating = inFlight > 0
        }
        guard !dictating else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.showAlertWhenIdle(title, text) }
            }
            return
        }
        showAlert(title, text)
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            appLog("launch at login failed", error: error)
        }
    }

    // MARK: - Dictation key

    /// Watches the new key at once (no relaunch). A recording held with the old key is cancelled:
    /// its release would no longer be seen. The question key can never be the dictation key: if it
    /// was the new key, it is turned off, and the window and the HUD say so.
    func setDictationKey(_ key: TriggerKey) {
        guard key != settings.dictationKey else { return }
        let question = settings.questionKey
        // A dictation held with the old key is cancelled (its release would no longer be seen), and so
        // is a question held with the key that becomes the dictation key; a question on a key that
        // stays the question key goes on.
        if case .recording = state.status, recordingKind == .dictation || recordingKey == key {
            let held = recordingKey
            handle(.cancel)
            hotkey.reset(held) // a key that stays watched keeps its machine: drop the cancelled gesture
        }
        if TriggerKeyValidation.clearsQuestion(key, question: question) {
            settings.questionKey = nil
            state.questionKeyCleared = true
            onNotice?(Self.questionKeyClearedMessage)
            appLog("question key turned off (it became the dictation key)")
        }
        settings.dictationKey = key
        applyWatchedKeys()
        hotkey.start()
        appLog("dictation key: \(key.rawValue)")
    }

    static let questionKeyClearedMessage = String(localized: "Question key turned off: it is now the dictation key.")

    /// Off (nil) or a key other than the dictation key. A question recording held with the old key
    /// is cancelled (its release would no longer be seen); a dictation goes on.
    func setQuestionKey(_ key: TriggerKey?) {
        guard TriggerKeyValidation.allowed(dictation: settings.dictationKey, question: key) else { return }
        state.questionKeyCleared = false
        guard key != settings.questionKey else { return }
        if case .recording = state.status, recordingKind == .question {
            let held = recordingKey
            handle(.cancel)
            hotkey.reset(held)
        }
        settings.questionKey = key
        applyWatchedKeys()
        appLog("question key: \(key?.rawValue ?? "off")")
    }

    /// The dictation key, plus the question key while a text model can answer.
    private func applyWatchedKeys() {
        hotkey.setKeys(settings.watchedKeys)
    }

    // MARK: - Languages

    func setDictationLanguage(_ language: DictationLanguage) {
        settings.dictationLanguage = language
        appLog("dictation language: \(language.rawValue)")
    }

    /// Writes (or removes, for System) `AppleLanguages` in the app's domain; the interface changes
    /// on the next launch, so it offers to reopen now.
    func setAppLanguage(_ language: AppLanguage) {
        // "System" always clears a saved value, even one the app does not support (it reads as System).
        guard language != settings.appLanguage || (language == .system && settings.hasAppLanguage) else { return }
        settings.appLanguage = language
        appLog("app language: \(language.rawValue)")
        // Called from a picker's binding or a menu action: the alert's modal loop runs afterwards.
        Task { @MainActor in self.offerRelaunch() }
    }

    /// Nothing to reopen into while a dictation, download or deletion runs (it would be lost):
    /// the new language then simply comes with the next launch.
    private var canRelaunch: Bool {
        if case .recording = state.status { return false }
        return inFlight == 0 && !downloads.isRunning && !state.deletingModels
    }

    private func offerRelaunch() {
        guard canRelaunch else {
            onNotice?(String(localized: "The new language is used the next time \(AppIdentity.name) opens."))
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reopen \(AppIdentity.name) to change the language?")
        alert.informativeText = String(localized: "The new language is used the next time \(AppIdentity.name) opens.")
        alert.addButton(withTitle: String(localized: "Reopen now"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    /// Quits and opens the app again once this process is gone. Never in the middle of a
    /// dictation, a download or a deletion (it would be lost); outside an app bundle (dev runs)
    /// there is nothing to reopen.
    private func relaunch() {
        guard canRelaunch else { // something started while the alert was open
            onNotice?(String(localized: "The new language is used the next time \(AppIdentity.name) opens."))
            return
        }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            appLog("relaunch skipped: not running from an app bundle")
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0 = the bundle path (passed as an argument, never interpolated into the script).
        reopen.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                            bundle.path]
        do {
            try reopen.run()
        } catch {
            appLog("relaunch failed", error: error)
            return
        }
        NSApp.terminate(nil)
    }

    func copyHistory(_ entry: DictationResult, raw: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw ? entry.raw : entry.final, forType: .string)
    }

    /// Until the models are chosen, "Abrir <name>…" opens the chooser.
    func showMainWindow() {
        if state.setupPending { onShowModelSetup?() } else { onShowMainWindow?() }
    }

    func retryPreparation() { Task { await prepareModels() } }

    /// Called when the menu opens so granted permissions stop showing as warnings.
    func refreshPermissions() {
        state.micGranted = Permissions.microphoneGranted
        let ax = Permissions.accessibilityGranted
        if ax && !state.accessibilityGranted { hotkey.start() }
        state.accessibilityGranted = ax
    }

    func requestPermissions() {
        Permissions.promptAccessibility()
        state.accessibilityGranted = Permissions.accessibilityGranted
    }
}

// MARK: - Files (spec §5)

extension AppEnvironment: FileJobRunner {
    static let fileBusyMessage = String(localized: "Wait for the file transcription to finish")

    /// "Transcribe file…" (window and menu).
    func transcribeFile() {
        guard !state.setupPending else { onShowModelSetup?(); return }
        files.choose()
    }

    /// Drag and drop and "Open With".
    func transcribeFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !state.setupPending else {
            onNotice?(String(localized: "Choose the models first"))
            onShowModelSetup?()
            return
        }
        files.open(urls)
    }

    var aiAvailable: Bool { settings.textModel.usesAI }

    /// Waits (polling, on the main actor) until nothing records or processes, no other file runs,
    /// and the models are ready; then counts as in flight (keys refused, no model switch) and
    /// takes a residency lease (no idle unload mid-file).
    func beginFileWork(waiting: @escaping @MainActor (String) -> Void) async throws {
        var said: String?
        while true {
            try Task.checkCancellation()
            if state.setupPending { throw FileJobError(message: String(localized: "Choose the models first")) }
            if case .error = state.status {
                throw FileJobError(message: String(localized: "Couldn't load the models.", bundle: .main))
            }
            if !downloads.isRunning, !state.deletingModels,
               TakeArbiter.canStart(.file, status: state.status, dictationsInFlight: dictationsInFlight,
                                    questionsInFlight: questionsInFlight, filesInFlight: filesInFlight) { break }
            let reason: String
            switch state.status {
            case .preparing: reason = String(localized: "Waiting for the models…")
            case .recording, .processing:
                // Files wait for each other in the windows' queue, so this is a dictation or question.
                reason = String(localized: "Waiting for the dictation to finish…")
            default: reason = String(localized: "Waiting…")
            }
            if reason != said { said = reason; waiting(reason) }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        filesInFlight += 1
        inFlight += 1
        state.status = .processing
        do {
            try await residency.beginUse()
        } catch {
            await endFileWork(holdsModels: false)
            throw FileJobError(message: String(localized: "Couldn't load the models.", bundle: .main))
        }
    }

    func endFileWork() async { await endFileWork(holdsModels: true) }

    private func endFileWork(holdsModels: Bool) async {
        if holdsModels { await residency.endUse() }
        filesInFlight = max(0, filesInFlight - 1)
        inFlight = max(0, inFlight - 1)
        let modelsLost = await !residency.isLoaded
        state.status = DictationStatusLogic.afterClipFinished(state.status, inFlight: inFlight, modelsLost: modelsLost)
        if clipsInFlight == 0 { onFinished?(nil) } // hides a pill a notice left during the file
    }

    func transcribe(_ url: URL, language: String?, onProgress: @escaping @Sendable (Double) -> Void,
                    onText: @escaping @Sendable (String) -> Void) async throws -> FileTranscript {
        try await Self.transcribeFile(transcriber, url, language: language, onProgress: onProgress, onText: onText)
    }

    /// Off the main actor: the reading and the block loop run on the cooperative pool.
    private nonisolated static func transcribeFile(_ transcriber: WhisperKitTranscriber, _ url: URL, language: String?,
                                                   onProgress: @escaping @Sendable (Double) -> Void,
                                                   onText: @escaping @Sendable (String) -> Void) async throws -> FileTranscript {
        try await transcriber.transcribeFile(url, language: language, onProgress: onProgress, onText: onText)
    }

    func organize(_ text: String, language: String,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptTasks.Organized {
        try await Self.organize(processor, text, language: language, onProgress: onProgress)
    }

    private nonisolated static func organize(_ processor: MLXTextProcessor, _ text: String, language: String,
                                             onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptTasks.Organized {
        try await TranscriptTasks.organize(text, language: language, using: processor, onProgress: onProgress)
    }

    func summarize(_ text: String, language: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await Self.summarize(processor, text, language: language, onProgress: onProgress)
    }

    private nonisolated static func summarize(_ processor: MLXTextProcessor, _ text: String, language: String,
                                              onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await TranscriptTasks.summarize(text, language: language, using: processor, onProgress: onProgress)
    }

    func recordFile(_ entry: DictationResult, update: Bool) {
        if update {
            history.update(entry) { $0.date == entry.date && $0.fileName == entry.fileName }
        } else {
            history.append(entry)
        }
        state.history = history.entries
    }

    /// "Copy" in a file window: the only clipboard write, on the user's click.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedName
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                MainActor.assumeIsolated {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
}
