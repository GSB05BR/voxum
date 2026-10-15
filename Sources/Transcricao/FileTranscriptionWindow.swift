// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import TranscricaoCore
import TranscricaoEngines
import UniformTypeIdentifiers

/// What the file windows need from the app (`AppEnvironment`; the debug showcase fakes it).
@MainActor
protocol FileJobRunner: AnyObject {
    /// A text model can organize and summarize ("No AI" has none).
    var aiAvailable: Bool { get }
    /// Waits until file work may run (no dictation or question, no other file, models ready) and
    /// takes the models (a residency lease). `waiting` gets what it waits for. Throws
    /// `FileJobError` with a message, or `CancellationError`.
    func beginFileWork(waiting: @escaping @MainActor (String) -> Void) async throws
    /// Releases what `beginFileWork` took.
    func endFileWork() async
    func transcribe(_ url: URL, language: String?, onProgress: @escaping @Sendable (Double) -> Void,
                    onText: @escaping @Sendable (String) -> Void) async throws -> FileTranscript
    func organize(_ text: String, language: String,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptTasks.Organized
    func summarize(_ text: String, language: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// One History entry per file: appended once transcribed, updated when organized or summarized.
    func recordFile(_ entry: DictationResult, update: Bool)
    /// "Copy" (the only clipboard write, on the user's click) and "Save .txt…".
    func copy(_ text: String)
    func save(_ text: String, suggestedName: String)
}

struct FileJobError: Error {
    let message: String
}

/// One file: its transcription, then what Organize and Summarize made of it.
@MainActor
final class FileJob: ObservableObject {
    enum Phase: Equatable {
        case waiting(String)
        case transcribing
        case done
        case failed(String)
        case cancelled
    }

    enum AIWork: Equatable { case organizing, summarizing }
    enum Tab: Hashable { case transcript, organized, summary }

    let url: URL
    var name: String { url.lastPathComponent }
    @Published var phase: Phase = .waiting("")
    @Published var progress: Double = 0
    @Published var liveText = ""
    @Published var transcript: FileTranscript?
    @Published var organized: TranscriptTasks.Organized?
    @Published var summary: String?
    @Published var aiWork: AIWork?
    @Published var aiProgress: Double = 0
    /// What the queued Organize/Summarize waits for (nil once it runs).
    @Published var aiWaiting: String?
    /// The last Organize/Summarize failed, or a note about its result.
    @Published var aiNote: String?
    @Published var tab: Tab = .transcript
    /// The window's language picker (Automatic by default, independent of the dictation language):
    /// the transcription's language, and the language Organize and Summarize write in.
    @Published var language: DictationLanguage = .automatic
    /// The picker's value when the shown transcript was made (nil before the first one).
    var transcribedLanguage: DictationLanguage?
    /// The History entry of this file, once transcribed.
    var entry: DictationResult?
    var task: Task<Void, Never>?
    var aiTask: Task<Void, Never>?
    /// Bumped by every start and cancel: late callbacks of an older run are ignored.
    var generation = 0
    var aiGeneration = 0

    init(url: URL) { self.url = url }

    /// The picker changed since the transcript was made: the window offers to transcribe again.
    var languageChanged: Bool {
        transcript != nil && transcribedLanguage != nil && transcribedLanguage != language
    }

    /// The language Organize and Summarize write in: the picker's language, or with Automatic the
    /// one the transcription detected (its prompt language).
    var aiLanguage: String? {
        guard let transcript else { return nil }
        return language.whisperCode ?? transcript.promptLanguage
    }

    var shownText: String {
        switch tab {
        case .transcript: return transcript?.text ?? liveText
        case .organized: return organized?.text ?? ""
        case .summary: return summary ?? ""
        }
    }

    /// "1:08 · Português"
    var subtitle: String? {
        guard let transcript else { return nil }
        let duration = Duration.seconds(transcript.seconds)
            .formatted(.time(pattern: transcript.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        guard let code = transcript.language,
              let language = Locale.current.localizedString(forLanguageCode: code) else { return duration }
        return "\(duration) · \(language.capitalized(with: Locale.current))"
    }
}

/// The "Transcribe file…" windows (spec §5): one window per file. Files and their Organize and
/// Summarize run one at a time, in the order asked (a second file opened while one runs waits
/// its turn in its own window, which says so); dictation and questions are refused meanwhile.
@MainActor
final class FileTranscriptionController: NSObject, NSWindowDelegate, ObservableObject {
    private let runner: FileJobRunner
    /// Mirrors `runner.aiAvailable` for the windows (`refresh()` after a text model change).
    @Published private(set) var aiAvailable: Bool
    private var windows: [NSWindow: FileJob] = [:]
    /// The last piece of file work asked for: the next one starts after it.
    private var lane: Task<Void, Never>?
    /// Pieces of file work queued or running: a new one waits for another file's.
    private var laneCount = 0

    /// Something is queued or running (quitting asks first).
    var hasWork: Bool { laneCount > 0 }

    init(runner: FileJobRunner) {
        self.runner = runner
        aiAvailable = runner.aiAvailable
    }

    /// The text model changed (a model chosen, or "No AI").
    func refresh() {
        if aiAvailable != runner.aiAvailable { aiAvailable = runner.aiAvailable }
    }

    static let contentTypes: [UTType] = [.audio, .movie, .audiovisualContent]

    /// "Transcribe file…": the open panel (several files at once are queued).
    func choose() {
        AppActivation.windowWillShow()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose audio or video files to transcribe")
        panel.prompt = String(localized: "Transcribe")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK { self.open(panel.urls) } else { AppActivation.update() }
            }
        }
    }

    /// Drag and drop, "Open With" and the open panel: one window per file, each queued.
    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let job = FileJob(url: url)
            present(job)
            start(job)
        }
    }

    /// Shows the window of `job` (the showcase presents jobs in a given state).
    func present(_ job: FileJob) {
        let view = FileJobView(job: job, controller: self)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = job.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 520))
        window.contentMinSize = NSSize(width: 460, height: 360)
        window.delegate = self
        // Each new window a little lower and to the right of the last.
        if let last = windows.keys.max(by: { $0.windowNumber < $1.windowNumber }), last.isVisible {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        windows[window] = job
        AppActivation.windowWillShow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Work, one piece at a time

    /// FIFO: each piece of file work starts once the previous one ended.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lane
        laneCount += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            self?.laneCount -= 1
        }
        lane = task
        return task
    }

    /// What a new piece of work of `job` waits for before it is its turn (its own transcription,
    /// restarted in another language, is not "the other file").
    private func queuedMessage(for job: FileJob) -> String {
        // Only a transcription of its own already in the lane counts as this job's (a new job has none).
        var ownQueued = false
        switch job.phase {
        case .waiting, .transcribing: ownQueued = job.task != nil
        default: break
        }
        return FileQueue.waitsForOtherFile(piecesInLane: laneCount, ownPieceQueued: ownQueued)
            ? String(localized: "Waiting for the other file…") : String(localized: "Waiting…")
    }

    /// Transcribes `job` (again, after a cancel, an error or a language change).
    func start(_ job: FileJob) {
        guard job.aiWork == nil else { return }
        let message = queuedMessage(for: job)
        job.task?.cancel()
        job.generation += 1
        let generation = job.generation
        job.phase = .waiting(message)
        job.progress = 0
        job.liveText = ""
        job.task = enqueue { [weak self] in await self?.transcribe(job, generation) }
    }

    func cancel(_ job: FileJob) {
        job.generation += 1
        job.task?.cancel()
        job.task = nil
        // A transcription started over (another language) falls back to the one already made.
        if job.phase != .done { job.phase = job.transcript != nil ? .done : .cancelled }
    }

    private func transcribe(_ job: FileJob, _ generation: Int) async {
        guard !Task.isCancelled, job.generation == generation else { return }
        do {
            try await runner.beginFileWork(waiting: { message in
                if job.generation == generation { job.phase = .waiting(message) }
            })
        } catch {
            if job.generation == generation { job.phase = Self.failure(error) }
            return
        }
        job.phase = .transcribing
        let start = Date()
        let language = job.language // read now: a change while waiting applies to this run
        let result: Result<FileTranscript, Error>
        do {
            result = .success(try await runner.transcribe(job.url, language: language.whisperCode, onProgress: { p in
                Task { @MainActor in if job.generation == generation, job.phase == .transcribing { job.progress = p } }
            }, onText: { text in
                Task { @MainActor in if job.generation == generation, job.phase == .transcribing { job.liveText = text } }
            }))
        } catch {
            result = .failure(error)
        }
        await runner.endFileWork()
        guard job.generation == generation else { return }
        switch result {
        case .failure(let error):
            job.phase = Self.failure(error)
        case .success(let transcript) where transcript.raw.isEmpty:
            job.phase = .failed(String(localized: "No speech found in the file."))
        case .success(let transcript):
            let seconds = Date().timeIntervalSince(start)
            appLog(String(format: "file transcribed: %.1f s of audio in %.1f s (%@)", transcript.seconds, seconds,
                          transcript.language ?? "?"))
            job.transcript = transcript
            job.transcribedLanguage = language
            job.organized = nil
            job.summary = nil
            job.tab = .transcript
            job.phase = .done
            var entry = DictationResult(
                date: start, raw: transcript.raw, final: transcript.text, aiEnabled: false, usedFallback: false,
                timings: StageTimings(transcribe: seconds, process: 0, total: seconds))
            entry.language = transcript.language
            entry.fileName = job.name
            entry.pasted = false
            job.entry = entry
            runner.recordFile(entry, update: false)
        }
    }

    static func failure(_ error: Error) -> FileJob.Phase {
        if error is CancellationError { return .cancelled }
        if let error = error as? FileJobError { return .failed(error.message) }
        if let error = error as? AudioFileError { return .failed(error.localizedDescription) }
        appLog("file transcription failed", error: error)
        return .failed(String(localized: "Transcription failed.", bundle: .main))
    }

    /// The window's language picker. While the file is transcribed, the transcription starts over
    /// in the new language; before it starts, the run uses it; once transcribed, the window offers
    /// to transcribe again (`FileJob.languageChanged`), and Organize/Summarize use it meanwhile.
    func setLanguage(_ language: DictationLanguage, for job: FileJob) {
        guard job.language != language else { return }
        job.language = language
        if job.phase == .transcribing { start(job) }
    }

    func organize(_ job: FileJob) { runAI(.organizing, on: job) }
    func summarize(_ job: FileJob) { runAI(.summarizing, on: job) }

    func cancelAI(_ job: FileJob) {
        job.aiGeneration += 1
        job.aiTask?.cancel()
        job.aiTask = nil
        job.aiWork = nil
        job.aiWaiting = nil
    }

    private func runAI(_ kind: FileJob.AIWork, on job: FileJob) {
        guard job.transcript != nil, job.aiWork == nil else { return }
        job.aiGeneration += 1
        let generation = job.aiGeneration
        job.aiWork = kind
        job.aiProgress = 0
        job.aiNote = nil
        job.aiWaiting = queuedMessage(for: job)
        job.aiTask = enqueue { [weak self] in await self?.performAI(kind, on: job, generation) }
    }

    private func performAI(_ kind: FileJob.AIWork, on job: FileJob, _ generation: Int) async {
        func current() -> Bool { job.aiGeneration == generation }
        guard !Task.isCancelled, current(), let transcript = job.transcript, let language = job.aiLanguage else { return }
        func noAI() {
            job.aiWork = nil
            job.aiWaiting = nil
            job.aiNote = Self.noAINote
        }
        refresh()
        guard runner.aiAvailable else { noAI(); return }
        do {
            try await runner.beginFileWork(waiting: { message in if current() { job.aiWaiting = message } })
        } catch {
            if current() {
                job.aiWork = nil
                job.aiWaiting = nil
                if case .failed(let message) = Self.failure(error) { job.aiNote = message }
            }
            return
        }
        // "No AI" may have been chosen while this waited: there is no model to run.
        refresh()
        guard runner.aiAvailable else {
            await runner.endFileWork()
            if current() { noAI() }
            return
        }
        if current() { job.aiWaiting = nil }
        let start = Date()
        let progress: @Sendable (Double) -> Void = { p in
            Task { @MainActor in if job.aiGeneration == generation { job.aiProgress = p } }
        }
        var organized: TranscriptTasks.Organized?
        var summary: String?
        var failure: Error?
        do {
            switch kind {
            case .organizing:
                organized = try await runner.organize(transcript.raw, language: language, onProgress: progress)
            case .summarizing:
                summary = try await runner.summarize(transcript.raw, language: language, onProgress: progress)
            }
        } catch {
            failure = error
        }
        await runner.endFileWork()
        guard current() else { return }
        job.aiWork = nil
        if let failure {
            if !(failure is CancellationError) {
                appLog("file \(kind == .organizing ? "organize" : "summary") failed", error: failure)
                job.aiNote = kind == .organizing ? String(localized: "Couldn't organize the text.")
                                                 : String(localized: "Couldn't summarize the text.")
            }
            return
        }
        let seconds = Date().timeIntervalSince(start)
        var entry = job.entry
        if let organized {
            appLog(String(format: "file organized: %d piece(s), %d kept as transcribed, %.1f s",
                          organized.pieces, organized.keptAsTranscribed, seconds))
            job.organized = organized
            job.tab = .organized
            if organized.keptAsTranscribed > 0 {
                job.aiNote = String(localized: "Parts kept as transcribed (the model couldn't organize them): \(organized.keptAsTranscribed) of \(organized.pieces).")
            }
            entry?.final = organized.text
            entry?.aiEnabled = true
            entry?.usedFallback = organized.keptAsTranscribed > 0
            entry?.timings.process = seconds
        }
        if let summary {
            appLog(String(format: "file summarized in %.1f s", seconds))
            job.summary = summary
            job.tab = .summary
            entry?.summary = summary
        }
        if let entry {
            job.entry = entry
            runner.recordFile(entry, update: true)
        }
    }

    static var noAINote: String {
        String(localized: "Organizing and summarizing need a text model: with “No AI” there is no model to do them. Choose a text model to use them.")
    }

    // MARK: Copy and save

    func copy(_ job: FileJob) { runner.copy(job.shownText) }

    func save(_ job: FileJob) {
        let base = job.url.deletingPathExtension().lastPathComponent
        let name: String
        switch job.tab {
        case .transcript: name = "\(base).txt"
        case .organized: name = String(localized: "\(base) (organized).txt")
        case .summary: name = String(localized: "\(base) (summary).txt")
        }
        runner.save(job.shownText, suggestedName: name)
    }

    // MARK: Windows

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let job = windows.removeValue(forKey: window) else { return }
        // A closed window stops its work (a queued one never starts).
        cancel(job)
        cancelAI(job)
        AppActivation.windowWillClose(window)
    }
}

/// The app lives in the menu bar; while one of its windows is open it is a regular app (Dock icon,
/// ⌘-Tab, menus), and goes back to the menu bar when the last one closes.
@MainActor
enum AppActivation {
    static func windowWillShow() { NSApp.setActivationPolicy(.regular) }

    /// Called as `closing` closes.
    static func windowWillClose(_ closing: NSWindow) { update(except: closing) }

    static func update(except closing: NSWindow? = nil) {
        let open = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        NSApp.setActivationPolicy(open ? .regular : .accessory)
    }
}

// MARK: - View

private struct FileJobView: View {
    @ObservedObject var job: FileJob
    @ObservedObject var controller: FileTranscriptionController
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch job.phase {
            case .waiting(let message):
                status(message.isEmpty ? String(localized: "Waiting…") : message, progress: nil) {
                    Button("Cancel") { controller.cancel(job) }
                }
                Spacer()
            case .transcribing:
                status(String(localized: "Transcribing… \(Int(job.progress * 100))%"), progress: job.progress) {
                    Button("Cancel") { controller.cancel(job) }
                }
                ReadOnlyTextView(text: job.liveText, followsEnd: true)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Transcribe again") { controller.start(job) }
                Spacer()
            case .cancelled:
                Text("Cancelled.").foregroundStyle(.secondary)
                Button("Transcribe again") { controller.start(job) }
                Spacer()
            case .done:
                result
            }
            Text("Drop audio or video files here to transcribe them too.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 360)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { controller.open($0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: job.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let subtitle = job.subtitle {
                        Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Picker("Language", selection: Binding(get: { job.language },
                                                      set: { controller.setLanguage($0, for: job) })) {
                    ForEach(DictationLanguage.allChoices, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .fixedSize()
                .disabled(job.aiWork != nil)
            }
            if job.languageChanged, job.phase == .done {
                HStack {
                    Text("Transcribe again in \(job.language.title)? Organize and Summarize already use it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Transcribe again") { controller.start(job) }
                        .controlSize(.small)
                        .disabled(job.aiWork != nil)
                }
            }
        }
    }

    private func status<Buttons: View>(_ text: String, progress: Double?,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: text).font(.callout).monospacedDigit()
            HStack {
                if let progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                buttons()
            }
        }
    }

    @ViewBuilder private var result: some View {
        if job.organized != nil || job.summary != nil {
            Picker(selection: $job.tab) {
                Text("Transcript").tag(FileJob.Tab.transcript)
                if job.organized != nil { Text("Organized").tag(FileJob.Tab.organized) }
                if job.summary != nil { Text("Summary").tag(FileJob.Tab.summary) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        ReadOnlyTextView(text: job.shownText, followsEnd: false)
        if let work = job.aiWork {
            status(job.aiWaiting ?? (work == .organizing
                                     ? String(localized: "Organizing… \(Int(job.aiProgress * 100))%")
                                     : String(localized: "Summarizing… \(Int(job.aiProgress * 100))%")),
                   progress: job.aiWaiting == nil ? job.aiProgress : nil) {
                Button("Cancel") { controller.cancelAI(job) }
            }
        }
        if let note = job.aiNote {
            Text(verbatim: note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Copy") { controller.copy(job) }
            Button("Save .txt…") { controller.save(job) }
            Spacer()
            // Off while one runs, and with "No AI" (no text model).
            Group {
                Button("Organize with AI") { controller.organize(job) }
                Button("Summarize") { controller.summarize(job) }
            }
            .disabled(job.aiWork != nil || !controller.aiAvailable)
        }
        if !controller.aiAvailable {
            Text(verbatim: FileTranscriptionController.noAINote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// File URLs from a drop (Finder items).
enum FileDrop {
    static func load(_ providers: [NSItemProvider], then open: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in open([url]) }
            }
        }
        return true
    }
}

/// Long text, selectable, scrolling (a SwiftUI Text of an hour's transcript would be slow).
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    /// Keeps the end in view as text arrives (the transcript while it is transcribed).
    let followsEnd: Bool
    /// Fixed-width font (license texts, laid out with spaces).
    var monospaced = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.systemFontSize + 1)
            view.textContainerInset = NSSize(width: 6, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        if followsEnd { view.scrollToEndOfDocument(nil) } else { view.scrollToBeginningOfDocument(nil) }
    }
}
