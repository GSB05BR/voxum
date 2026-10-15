// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import ServiceManagement
import TranscricaoCore
import TranscricaoEngines

@MainActor
protocol StatusMenuActions: AnyObject {
    func toggleAI()
    func setTextModel(_ choice: TextModelChoice)
    func setIdleUnload(_ policy: IdleUnloadPolicy)
    func setAppLanguage(_ language: AppLanguage)
    func setDictationLanguage(_ language: DictationLanguage)
    func setDictationKey(_ key: TriggerKey)
    func setQuestionKey(_ key: TriggerKey?)
    func toggleSounds()
    func toggleLaunchAtLogin()
    func copyHistory(_ entry: DictationResult, raw: Bool)
    func retryPreparation()
    func requestPermissions()
    func refreshPermissions()
    func showMainWindow()
    func cancelDownload()
    func retryDownload()
    func deleteUnusedModels()
    func unusedModels() -> [UnusedModelFolder]
    /// "Transcribe file…": the open panel.
    func transcribeFile()
    /// Files dropped on the main window.
    func transcribeFiles(_ urls: [URL])
    var downloads: ModelDownloads { get }
    /// Automatic updates (Sparkle): the toggle and "Check now".
    var updater: Updater { get }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let state: AppState
    private let settings: Settings
    private weak var actions: StatusMenuActions?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, settings: Settings, actions: StatusMenuActions) {
        self.state = state
        self.settings = settings
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false // items set isEnabled themselves (e.g. no model switch mid-dictation)
        item.menu = menu
        state.$status.combineLatest(state.$modelsLoading, actions.updater.$pendingUpdateVersion).receive(on: RunLoop.main)
            .sink { [weak self] status, loading, update in
                self?.updateIcon(status, modelsLoading: loading, updatePending: update != nil)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(_ status: AppState.Status, modelsLoading: Bool, updatePending: Bool) {
        let (symbol, tint): (String, NSColor?) = {
            if DictationStatusLogic.showsReloading(status, modelsLoading: modelsLoading) { return ("hourglass", nil) }
            switch status {
            case .preparing: return ("hourglass", nil)
            // A gentle update reminder: a badge on the idle icon (and an item atop the menu).
            case .ready: return (updatePending ? "waveform.badge.exclamationmark" : "waveform", nil)
            case .recording: return ("record.circle.fill", .systemRed)
            case .processing: return ("ellipsis.circle", nil)
            case .error: return ("exclamationmark.triangle", .systemOrange)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppIdentity.name)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: AppIdentity.name)
        image?.isTemplate = true            // contentTintColor only tints template images
        item.button?.image = image
        item.button?.contentTintColor = tint // nil restores the default menu bar color
    }

    // Rebuilt every time so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        actions?.refreshPermissions()
        menu.removeAllItems()
        if let updater = actions?.updater, let version = updater.pendingUpdateVersion {
            menu.addItem(action(Updater.updateAvailableTitle(version)) { [weak updater] in updater?.checkForUpdates() })
            menu.addItem(.separator())
        }
        let openTitle = state.setupPending ? String(localized: "Choose models…") : String(localized: "Open \(AppIdentity.name)…")
        menu.addItem(action(openTitle) { [weak self] in self?.actions?.showMainWindow() })
        let file = action(String(localized: "Transcribe file…")) { [weak self] in self?.actions?.transcribeFile() }
        file.isEnabled = !state.setupPending
        menu.addItem(file)
        menu.addItem(.separator())
        menu.addItem(disabled(state.statusText))
        let memory = disabled(state.memoryTitle)
        memory.image = state.memory.dot
        menu.addItem(memory)

        if !state.micGranted || !state.accessibilityGranted {
            menu.addItem(.separator())
            if !state.micGranted {
                menu.addItem(action(String(localized: "⚠︎ Allow Microphone access…")) { Permissions.openMicrophoneSettings() })
            }
            if !state.accessibilityGranted {
                menu.addItem(action(String(localized: "⚠︎ Allow Accessibility…")) { [weak self] in
                    self?.actions?.requestPermissions()
                    Permissions.openAccessibilitySettings()
                })
            }
        }
        if case .error = state.status {
            menu.addItem(action(String(localized: "Try again")) { [weak self] in self?.actions?.retryPreparation() })
        }
        if let downloads = actions?.downloads {
            if let progress = downloads.progress {
                menu.addItem(.separator())
                menu.addItem(disabled(progress.statusLine))
                menu.addItem(action(String(localized: "Cancel download")) { [weak self] in self?.actions?.cancelDownload() })
            } else if let failure = downloads.failure {
                menu.addItem(.separator())
                menu.addItem(disabled(failure))
                menu.addItem(action(String(localized: "Retry the download")) { [weak self] in self?.actions?.retryDownload() })
            }
        }

        menu.addItem(.separator())
        let hasTextModel = settings.textModel.usesAI
        let ai = toggle(String(localized: "Organize with AI"), settings.aiActive) { [weak self] in self?.actions?.toggleAI() }
        ai.isEnabled = hasTextModel // "Sem IA": no model to switch on
        menu.addItem(ai)

        // Same gating as the switch itself: no change while recording/processing/preparing/downloading.
        let canSwitch = state.status == .ready && actions?.downloads.isRunning != true && !state.deletingModels
        let models = NSMenu()
        models.autoenablesItems = false
        for choice in TextModelChoice.allCases {
            let item = toggle(choice.title, settings.textModel == choice) { [weak self] in
                self?.actions?.setTextModel(choice)
            }
            item.isEnabled = canSwitch
            models.addItem(item)
        }
        menu.addItem(submenu(String(localized: "Text model"), models))

        let idle = NSMenu()
        for policy in IdleUnloadPolicy.allCases {
            idle.addItem(toggle(policy.title, settings.idleUnload == policy) { [weak self] in
                self?.actions?.setIdleUnload(policy)
            })
        }
        menu.addItem(submenu(String(localized: "Free memory after inactivity"), idle))

        let keys = NSMenu()
        let currentKey = settings.dictationKey
        for key in TriggerKey.allCases {
            let item = toggle(key.title, currentKey == key) { [weak self] in self?.actions?.setDictationKey(key) }
            if key == .fn { item.toolTip = TriggerKey.fnNote } // the window shows it under its picker
            keys.addItem(item)
        }
        menu.addItem(submenu(String(localized: "Dictation key"), keys))

        // Question key: Off or any key but the dictation key; "No AI" has no model to answer.
        let questions = NSMenu()
        questions.autoenablesItems = false
        let available = settings.questionAvailable
        if !available { questions.addItem(disabled(TriggerKey.questionUnavailableNote)) }
        let currentQuestion = settings.questionKey
        let off = toggle(String(localized: "Off"), currentQuestion == nil) { [weak self] in self?.actions?.setQuestionKey(nil) }
        off.isEnabled = available
        questions.addItem(off)
        for key in TriggerKeyValidation.questionChoices(dictation: currentKey) {
            let item = toggle(key.title, currentQuestion == key) { [weak self] in self?.actions?.setQuestionKey(key) }
            item.isEnabled = available
            if key == .fn { item.toolTip = TriggerKey.fnNote }
            questions.addItem(item)
        }
        menu.addItem(submenu(String(localized: "Question key"), questions))

        let dictation = NSMenu()
        let currentDictation = settings.dictationLanguage
        for choice in DictationLanguage.allChoices {
            dictation.addItem(toggle(choice.title, currentDictation == choice) { [weak self] in
                self?.actions?.setDictationLanguage(choice)
            })
        }
        menu.addItem(submenu(String(localized: "Dictation language"), dictation))

        let appLanguages = NSMenu()
        let currentApp = settings.appLanguage
        for language in AppLanguage.allCases {
            appLanguages.addItem(toggle(language.nativeName, currentApp == language) { [weak self] in
                self?.actions?.setAppLanguage(language)
            })
        }
        menu.addItem(submenu(String(localized: "App language"), appLanguages))

        let unused = actions?.unusedModels() ?? []
        if !unused.isEmpty {
            let total = unused.reduce(Int64(0)) { $0 + $1.bytes }
            let clean = action(String(localized: "Delete unused models (\(ByteText.approx(total)))…")) { [weak self] in
                self?.actions?.deleteUnusedModels()
            }
            clean.isEnabled = canSwitch
            menu.addItem(clean)
        }

        menu.addItem(toggle(String(localized: "Sounds"), settings.soundsEnabled) { [weak self] in self?.actions?.toggleSounds() })
        menu.addItem(toggle(String(localized: "Open at login"), SMAppService.mainApp.status == .enabled) { [weak self] in
            self?.actions?.toggleLaunchAtLogin()
        })

        // Updates (Sparkle): disabled where the updater does not run (development builds, no key).
        if let updater = actions?.updater {
            let auto = toggle(String(localized: "Check for updates automatically"), updater.automaticallyChecks) { [weak updater] in
                updater?.automaticallyChecks.toggle()
            }
            auto.isEnabled = updater.isEnabled
            menu.addItem(auto)
            let check = action(String(localized: "Check for updates now…")) { [weak updater] in updater?.checkForUpdates() }
            check.isEnabled = updater.isEnabled && updater.canCheckForUpdates
            menu.addItem(check)
        }

        menu.addItem(.separator())
        let history = NSMenu()
        if state.history.isEmpty {
            history.addItem(disabled(String(localized: "Empty")))
        }
        for entry in state.history.prefix(10) {
            let title = String(entry.final.replacingOccurrences(of: "\n", with: " ").prefix(60))
            history.addItem(action(title) { [weak self] in self?.actions?.copyHistory(entry, raw: false) })
            let raw = action(String(localized: "Raw: \(String(entry.raw.prefix(55)))")) { [weak self] in
                self?.actions?.copyHistory(entry, raw: true)
            }
            raw.isAlternate = true
            raw.keyEquivalentModifierMask = .option
            history.addItem(raw)
        }
        menu.addItem(submenu(String(localized: "History (click copies, ⌥ = raw)"), history))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Menu item helpers (closure-based targets)

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ handler: @escaping () -> Void) -> NSMenuItem {
        let i = action(title, handler)
        i.state = on ? .on : .off
        return i
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
        let target = ClosureTarget(handler)
        i.target = target
        i.representedObject = target // keep the target alive with the item
        return i
    }
}

final class ClosureTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
