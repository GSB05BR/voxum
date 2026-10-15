// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TranscricaoCore
import TranscricaoEngines

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var mainWindow: MainWindowController?
    private var modelSetup: ModelSetupWindowController?
    private let hud = RecordingHUD()

    /// True when macOS started us as a login item (captured here: the Apple event is gone later).
    private var launchedAsLoginItem = false

    /// The launch Apple event, captured the first time it is available (nil if none yet).
    private var launchEvent: NSAppleEventDescriptor?

    /// Files opened ("Open With") before the environment exists (a launch by opening a file).
    private var pendingFiles: [URL] = []

    /// Sparkle, created once at launch (it does not start in development runs; see `Updater`).
    private var updater: Updater?

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchEvent = NSAppleEventManager.shared().currentAppleEvent
    }

    private static func isLoginItemLaunch(_ ev: NSAppleEventDescriptor?) -> Bool {
        ev?.eventID == AEEventID(kAEOpenApplication)
            && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The event may only be current in one of the two callbacks: use whichever has it.
        launchedAsLoginItem = Self.isLoginItemLaunch(launchEvent ?? NSAppleEventManager.shared().currentAppleEvent)
        // Screenshots of the panel/pill only: nothing else starts (see DebugShowcase).
        if let mode = DebugShowcase.requestedMode {
            DebugShowcase.run(mode)
            return
        }
        installMainMenu()
        let updater = Updater.forThisRun()
        self.updater = updater
        let env = AppEnvironment(updater: updater)
        updater.isBusy = { [weak env] in env?.hasTakeInProgress ?? false }
        env.onRecordingStarted = { [hud] continuous, isStart in
            if isStart { Sounds.start() }
            hud.showRecording(continuous: continuous)
        }
        env.onLevel = { [hud] level in hud.push(level: level) }
        env.onEditModeChange = { [hud] editing in hud.setEditing(editing) }
        env.onTakeKindChange = { [hud] kind in hud.setQuestion(kind == .question) }
        // The panel itself shows "Pensando…", so the processing pill goes; a recording pill (a newer
        // dictation already started) stays.
        env.answerPanel.onShow = { [hud, weak env] in
            if case .recording = env?.state.status { return }
            hud.hide()
        }
        env.onProcessing = { [hud] in
            Sounds.stop()
            hud.showProcessing()
        }
        env.onFinished = { [hud, weak env] error in
            guard let env else { return }
            var isRecording = false, isProcessing = false
            switch env.state.status {
            case .recording: isRecording = true
            case .processing: isProcessing = true
            default: break
            }
            // File work alone (status .processing for a file) has no pill: hide it.
            isProcessing = HUDNoticeDecision.clipProcessing(statusIsProcessing: isProcessing, clipsInFlight: env.clipsInFlight)
            switch HUDFinishDecision.decide(isRecording: isRecording, isProcessing: isProcessing, error: error) {
            case .ignore: break
            case .keepProcessing: hud.showProcessing() // e.g. Esc on clip B while clip A is in flight
            case .flashError(let message): hud.showError(message, thenProcessing: true)
            case .hide: hud.hide()
            case .showError(let message): hud.showError(message)
            }
        }
        let window = MainWindowController(state: env.state, settings: env.settings, actions: env)
        env.onShowMainWindow = { [weak window] in window?.show() }
        env.onYieldFocus = { [weak window] in window?.yieldFocus() }
        let setup = ModelSetupWindowController(env: env)
        // Models downloaded: continue as a normal start (main window while they load).
        setup.onFinished = { [weak setup, weak window] in
            setup?.close()
            window?.show()
        }
        env.onShowModelSetup = { [weak setup] in setup?.show() }
        env.onNotice = { [hud, weak env] message in
            guard let env else { return }
            env.undoPill.dismiss() // same spot as the HUD
            // A dictation or question still processing (its answer not shown yet) gets its
            // processing pill back; file work does not (its window shows the progress).
            hud.showError(message, thenProcessing: HUDNoticeDecision.thenProcessing(
                clipsInFlight: env.clipsInFlight, answerPanelVisible: env.answerPanel.isVisible))
        }
        env.onModelFilesChanged = { [weak window] in window?.refreshUnusedModels() }
        mainWindow = window
        modelSetup = setup
        environment = env
        env.start()
        defer {
            // A launch by "Open With": the files' windows come after (above) the main window.
            if !pendingFiles.isEmpty { env.transcribeFiles(pendingFiles) }
            pendingFiles = []
        }
        if env.state.setupPending {
            setup.show() // first run: choose the models before anything is downloaded
        } else if MainWindowController.shouldShowAtLaunch(loginItem: launchedAsLoginItem) {
            window.show()
        }
    }

    /// "Open With" from the Finder (and files dropped on the Dock icon): one window per file.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard DebugShowcase.requestedMode == nil else { return } // screenshots only
        if let environment { environment.transcribeFiles(urls) } else { pendingFiles += urls }
    }

    /// Quitting while a file is transcribed (or organized, summarized, or queued) loses that work:
    /// ask first, with "Cancel" as the default. A dictation or question still processing or pasting
    /// finishes first (Sparkle's "Install and Relaunch" quits through here too), at most `WhenIdle`'s cap.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        if environment.files.hasWork {
            AppActivation.windowWillShow()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "A file is being transcribed. Quit anyway?")
            alert.informativeText = String(localized: "The work in progress is lost; files already transcribed are in the History.")
            // The safe choice is the default (Return, and Esc): keep working.
            alert.addButton(withTitle: String(localized: "Cancel"))
            let quitButton = alert.addButton(withTitle: String(localized: "Quit"))
            quitButton.hasDestructiveAction = true
            let quit = alert.runModal() == .alertSecondButtonReturn
            guard quit else { AppActivation.update(); return .terminateCancel }
        }
        guard environment.hasTakeInProgress else { return .terminateNow }
        appLog("quit waits for the dictation in progress")
        WhenIdle.run(isBusy: { [weak environment] in environment?.hasTakeInProgress ?? false }) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Clicking the app in Finder/Launchpad/Spotlight while it runs (the chooser until models are chosen).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.showMainWindow()
        return true
    }

    @objc private func showCredits(_ sender: Any?) { CreditsWindowController.show() }

    /// Only used while the window is open (regular activation policy): gives ⌘W and ⌘Q.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About \(AppIdentity.name)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let credits = NSMenuItem(title: String(localized: "Credits…"), action: #selector(showCredits(_:)), keyEquivalent: "")
        credits.target = self
        appMenu.addItem(credits)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide \(AppIdentity.name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit \(AppIdentity.name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
