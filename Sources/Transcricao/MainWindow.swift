// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TranscricaoCore
import TranscricaoEngines

/// Settings are UserDefaults-backed (not observable): this mirrors them for SwiftUI and is
/// re-read after every change, when the window becomes key and on the refresh tick.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var aiEnabled = true
    @Published var soundsEnabled = true
    @Published var textModel: TextModelChoice = .qwen3_4b
    @Published var idleUnload: IdleUnloadPolicy = .never
    @Published var launchAtLogin = false
    @Published var appLanguage: AppLanguage = .system
    @Published var dictationLanguage: DictationLanguage = .automatic
    @Published var dictationKey: TriggerKey = .default
    @Published var questionKey: TriggerKey?
    /// Models on disk that the current configuration does not use (refreshed with the window).
    @Published var unused: [UnusedModelFolder] = []
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        reload()
    }

    func reload() {
        aiEnabled = settings.aiEnabled
        soundsEnabled = settings.soundsEnabled
        textModel = settings.textModel
        idleUnload = settings.idleUnload
        launchAtLogin = SMAppService.mainApp.status == .enabled
        appLanguage = settings.appLanguage
        dictationLanguage = settings.dictationLanguage
        dictationKey = settings.dictationKey
        questionKey = settings.questionKey
    }
}

extension TriggerKey {
    /// Shown with the Fn choice. Text only: the app never changes system settings.
    static var fnNote: String {
        String(localized: "If macOS uses 🌐 for dictation or emoji, set “Press 🌐 key to” to “Do Nothing” in System Settings › Keyboard. In Keyboard › Dictation, also change the Shortcut if it is “Press 🌐 Twice”: it clashes with double-tapping Fn. On keyboards with an fn key, the settings say “fn” instead of 🌐.")
    }

    /// Under the question-key picker (and atop its menu) with "No AI".
    static var questionUnavailableNote: String {
        String(localized: "Questions need a text model: with “No AI” there is no model to answer. Choose a text model to use them.")
    }

}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    nonisolated static let shownKey = "mainWindowShownOnce"
    private let state: AppState
    private let actions: StatusMenuActions
    private let model: SettingsModel
    private var window: NSWindow?
    private var timer: Timer?
    /// The last other app that was active: focus goes back to it when a dictation starts
    /// while our window is frontmost.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(state: AppState, settings: Settings, actions: StatusMenuActions) {
        self.state = state
        self.actions = actions
        self.model = SettingsModel(settings: settings)
        super.init()
        rememberIfOther(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.rememberIfOther(app) }
        }
    }

    private func rememberIfOther(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = app
    }

    /// A dictation started while the app is active: close our window (back to menu-bar-only) and
    /// re-activate the previous app so the paste lands there. Unlike NSApp.hide, this keeps the
    /// HUD panel on screen.
    func yieldFocus() {
        if let window, window.isVisible { window.close() } // windowWillClose → .accessory
        if let previous = previousApp, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        } else {
            NSApp.deactivate()
        }
    }

    /// Every user launch shows the window; a login-item launch only on first run or missing permissions.
    static func shouldShowAtLaunch(loginItem: Bool) -> Bool {
        guard loginItem else { return true }
        let first = !Settings.store.bool(forKey: shownKey)
        return first || !Permissions.microphoneGranted || !Permissions.accessibilityGranted
    }

    func show() {
        rememberIfOther(NSWorkspace.shared.frontmostApplication)
        Settings.store.set(true, forKey: Self.shownKey)
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        startTimer()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = MainWindowView(state: state, model: model, downloads: actions.downloads, updater: actions.updater,
                                  actions: actions, onRefresh: { [weak self] in self?.refresh() })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = AppIdentity.name
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 480, height: 720))
        w.contentMinSize = NSSize(width: 480, height: 420)
        w.contentMaxSize = NSSize(width: 480, height: 10_000)
        w.center()
        w.delegate = self
        return w
    }

    private func refresh() {
        actions.refreshPermissions()
        model.reload()
        refreshUnusedModels()
    }

    /// Also called when the background scan of unused models changed its result (e.g. after a
    /// deletion), so the list does not wait for the next tick.
    func refreshUnusedModels() {
        let unused = actions.unusedModels()
        if unused != model.unused { model.unused = unused }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        refresh()
        startTimer()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        // Back to menu-bar only, unless a file window is still open.
        if let window = notification.object as? NSWindow { AppActivation.windowWillClose(window) }
        else { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - View

private struct MainWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SettingsModel
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var updater: Updater
    let actions: StatusMenuActions
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("How to use") {
                    usage("Hold \(model.dictationKey.name) to speak and release to insert the text.", "hand.tap")
                    usage("Double-tap for continuous mode; tap again to finish.", "repeat")
                    usage("Esc cancels the recording; afterwards, it stops an edit or answer and closes the panel.", "escape")
                    usage("Commands like “write a message…” generate the text for you.", "wand.and.stars")
                    if let question = model.questionKey, model.textModel.usesAI {
                        usage("Hold \(question.name) and ask a question: the local model's answer appears in a panel, with “Paste” and “Copy”. Selected text goes along as context.", "questionmark.bubble")
                    }
                    usage("With text selected in an editable field, say what to do (“make it more formal”): the result replaces the selection. Don't like it? “Undo” on the pill (or ⌘Z).", "pencil")
                    usage("Text selected on a page or in read-only text opens the answer in a panel, which stays open when you click outside: click in a text box and tap “Paste”, or “Copy”. A forgotten selection opens it too: click elsewhere before dictating.", "text.bubble")
                }
                Section("Transcribe a file") {
                    LabeledContent {
                        Button("Transcribe file…") { actions.transcribeFile() }
                            .disabled(state.setupPending)
                    } label: {
                        Text("Audio or video")
                        Text("m4a, mp3, wav, mp4, mov… Or drop files on this window, or use “Open With” in the Finder.")
                    }
                }
                Section("Permissions") {
                    permissionRow("Microphone", granted: state.micGranted) {
                        Task {
                            if Permissions.microphoneNotDetermined {
                                _ = await Permissions.requestMicrophone()
                            } else {
                                Permissions.openMicrophoneSettings()
                            }
                            onRefresh()
                        }
                    }
                    permissionRow("Accessibility", granted: state.accessibilityGranted) {
                        actions.requestPermissions()
                        Permissions.openAccessibilitySettings()
                    }
                }
                Section("Settings") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Dictation key", selection: Binding(
                            get: { model.dictationKey },
                            set: { actions.setDictationKey($0); model.reload() })) {
                            ForEach(TriggerKey.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                        }
                        if model.dictationKey == .fn {
                            Text(verbatim: TriggerKey.fnNote)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    questionKeyRow
                    Picker("App language", selection: Binding(
                        get: { model.appLanguage },
                        set: { actions.setAppLanguage($0); model.reload() })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text(verbatim: $0.nativeName).tag($0) }
                    }
                    Picker("Dictation language", selection: Binding(
                        get: { model.dictationLanguage },
                        set: { actions.setDictationLanguage($0); model.reload() })) {
                        ForEach(DictationLanguage.allChoices, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }
                    Picker("Text model", selection: Binding(
                        get: { model.textModel },
                        set: { choice in actions.setTextModel(choice); model.reload() })) {
                        ForEach(TextModelChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(state.status != .ready || downloads.isRunning || state.deletingModels)
                    downloadRow
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Organize with AI", isOn: Binding(
                            get: { model.aiEnabled && model.textModel.usesAI },
                            set: { _ in actions.toggleAI(); model.reload() }))
                        .disabled(!model.textModel.usesAI)
                        if !model.textModel.usesAI {
                            Text("No AI: the text is pasted as spoken (not organized, no editing of the selection) and the text model is not even loaded. Choose a model above to use the AI.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Free memory after inactivity", selection: Binding(
                            get: { model.idleUnload },
                            set: { actions.setIdleUnload($0); model.reload() })) {
                            ForEach(IdleUnloadPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text(model.idleUnload == .afterUse
                             ? String(localized: "The models stay in memory only while you dictate: they load when you press \(model.dictationKey.name) (about 3 s, while you speak) and leave right after.")
                             : String(localized: "Reloading the models after they are freed takes about 3 s."))
                            .fixedSize(horizontal: false, vertical: true)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    unusedRow
                    Toggle("Sounds", isOn: Binding(
                        get: { model.soundsEnabled },
                        set: { _ in actions.toggleSounds(); model.reload() }))
                    Toggle("Open at login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { _ in actions.toggleLaunchAtLogin(); model.reload() }))
                }
                updatesSection
                aboutSection
                Section("History") {
                    if state.history.isEmpty {
                        Text("No dictations yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(state.history.prefix(10).enumerated()), id: \.offset) { _, entry in
                        historyRow(entry)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 480, maxWidth: 480)
        .onChange(of: state.status) { model.reload() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { actions.transcribeFiles($0) }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text(AppIdentity.name).font(.title.weight(.semibold))
            Text(state.statusText).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label {
                Text(state.memoryTitle)
            } icon: {
                Image(nsImage: state.memory.dot)
            }
            .font(.caption).foregroundStyle(.secondary)
            if case .error = state.status {
                Button("Try again") { actions.retryPreparation() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20).padding(.horizontal, 20)
    }

    /// Automatic updates (Sparkle). Development builds and builds without the update key show the
    /// controls disabled, with a note.
    private var updatesSection: some View {
        Section("Updates") {
            if let version = updater.pendingUpdateVersion {
                Button(Updater.updateAvailableTitle(version)) { updater.checkForUpdates() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }))
                .disabled(!updater.isEnabled)
                if !updater.isEnabled {
                    Text("Updates are off in this build.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent {
                Button("Check now") { updater.checkForUpdates() }
                    .disabled(!updater.isEnabled || !updater.canCheckForUpdates)
            } label: {
                Text(verbatim: Updater.versionText)
            }
        }
    }

    /// The app's license, its source code and the third-party credits.
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("License") {
                Link(destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) {
                    Text(verbatim: ThirdPartyNotices.projectLicense)
                }
            }
            LabeledContent("Source code") {
                Link(destination: URL(string: ThirdPartyNotices.repositoryURL)!) {
                    Text(verbatim: ThirdPartyNotices.repositoryURL.replacingOccurrences(of: "https://", with: ""))
                }
            }
            LabeledContent {
                Button("Credits…") { CreditsWindowController.show() }
            } label: {
                Text("Third-party models and libraries")
            }
        }
    }

    /// Off, or any key but the dictation key (excluded from the list). Disabled with "No AI".
    private var questionKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Question key", selection: Binding(
                get: { model.questionKey },
                set: { actions.setQuestionKey($0); model.reload() })) {
                Text("Off").tag(TriggerKey?.none)
                ForEach(TriggerKeyValidation.questionChoices(dictation: model.dictationKey), id: \.self) {
                    Text(verbatim: $0.title).tag(TriggerKey?.some($0))
                }
            }
            .disabled(!model.textModel.usesAI)
            Group {
                if !model.textModel.usesAI {
                    Text(verbatim: TriggerKey.questionUnavailableNote)
                } else if state.questionKeyCleared, model.questionKey == nil {
                    Text(verbatim: AppEnvironment.questionKeyClearedMessage)
                } else if model.questionKey == .fn {
                    Text(verbatim: TriggerKey.fnNote)
                } else {
                    Text("Hold it and ask: the answer comes from the local model and is never pasted on its own.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Download of a text model chosen here (or of missing files while preparing).
    @ViewBuilder private var downloadRow: some View {
        if let progress = downloads.progress {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.statusLine).font(.callout).monospacedDigit()
                HStack {
                    ProgressView(value: progress.fraction)
                    Button("Cancel") { actions.cancelDownload() }
                }
            }
        } else if let failure = downloads.failure {
            HStack {
                Text(failure).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try again") { actions.retryDownload() }
            }
        }
    }

    private var unusedRow: some View {
        let total = model.unused.reduce(Int64(0)) { $0 + $1.bytes }
        return LabeledContent {
            Button(state.deletingModels ? String(localized: "Deleting…") : String(localized: "Delete…")) {
                actions.deleteUnusedModels()
            }
                .disabled(model.unused.isEmpty || state.status != .ready || downloads.isRunning
                          || state.deletingModels)
        } label: {
            Text("Unused models")
            Text(model.unused.isEmpty
                 ? String(localized: "None — only the models in use are on disk.")
                 : String(localized: "\(model.unused.count) on disk, freeing \(ByteText.approx(total)). The models in use are never deleted."))
        }
    }

    private func usage(_ text: LocalizedStringKey, _ symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }

    private func permissionRow(_ title: LocalizedStringKey, granted: Bool, request: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: request)
            }
        }
    }

    /// Edit by voice / answers: say what happened, since these were not (or not simply) pasted.
    private func historyTag(_ entry: DictationResult) -> String? {
        if let name = entry.fileName { return String(localized: "· file: \(name)") }
        if entry.answeredQuestion == true {
            return entry.usedFallback ? String(localized: "· question (no answer)") : String(localized: "· answer (not pasted)")
        }
        if entry.answeredSelection == true {
            return entry.usedFallback ? String(localized: "· answer failed") : String(localized: "· answer (not pasted)")
        }
        if entry.fallbackReason == .selectionChanged { return String(localized: "· edit not pasted (selection changed)") }
        if entry.pasted == false { return String(localized: "· not pasted") }
        if entry.editedSelection == true { return String(localized: "· selection edited") }
        return nil
    }

    private func historyRow(_ entry: DictationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: String(entry.final.prefix(300))).lineLimit(2) // a file entry can be 50k characters
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if let tag = historyTag(entry) {
                    Text(tag).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy text") { actions.copyHistory(entry, raw: false) }
                Button("Copy raw") { actions.copyHistory(entry, raw: true) }
            }
            .buttonStyle(.link).font(.caption)
        }
    }
}
