// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Sparkle
import TranscricaoCore
import TranscricaoEngines

/// Automatic updates with Sparkle (spec §6): one `SPUStandardUpdaterController`, created at launch
/// only when `UpdateConfiguration.decide` allows it. Development runs (`VOXUM_DATA_DIR`, `swift run`)
/// and builds whose `SUPublicEDKey` is still the placeholder never start it: nothing is checked,
/// downloaded or written, and the window and menu show the controls disabled.
///
/// Gentle reminders (Sparkle's guidance for background apps): a scheduled check that finds an
/// update while the app is not in focus does not put Sparkle's alert behind other windows; the
/// menu (and its icon) and the main window show "Update available" instead, until the user
/// looks at the update or the update session ends.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    /// Sparkle keeps its delegates weakly: held here.
    private let reminders: GentleReminders?
    private let relaunchGuard = RelaunchGuard()
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check or an update is in progress).
    @Published private(set) var canCheckForUpdates = false
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (also changed by Sparkle or `defaults`).
    @Published private(set) var automaticallyChecksMirror = false
    /// The version of an update found by a scheduled check and not shown yet (the gentle reminder).
    @Published private(set) var pendingUpdateVersion: String?
    private var observations: [NSKeyValueObservation] = []

    /// True when the updater runs in this process.
    var isEnabled: Bool { controller != nil }

    /// A dictation or question in flight: "Install and Relaunch" waits for it (see `WhenIdle`).
    var isBusy: () -> Bool {
        get { relaunchGuard.isBusy }
        set { relaunchGuard.isBusy = newValue }
    }

    /// The updater of this run, decided from the environment and the bundle's Info.plist.
    static func forThisRun() -> Updater {
        let decision = UpdateConfiguration.decide(
            dataDirOverride: ModelLocations.dataDirOverride != nil,
            bundleURL: Bundle.main.bundleURL,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        return Updater(decision: decision)
    }

    /// An updater that never starts (the debug showcase).
    static func disabled() -> Updater { Updater(decision: .developmentRun) }

    private init(decision: UpdateConfiguration.StartDecision) {
        guard decision == .start else {
            controller = nil
            reminders = nil
            appLog("updates off (\(decision))")
            return
        }
        let reminders = GentleReminders()
        self.reminders = reminders
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: relaunchGuard,
                                                      userDriverDelegate: reminders)
        self.controller = controller
        reminders.onChange = { [weak self] version in self?.pendingUpdateVersion = version }
        let updater = controller.updater
        // Sparkle changes these on the main thread today; hop there explicitly all the same.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                DispatchQueue.main.async { self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.automaticallyChecksForUpdates
                DispatchQueue.main.async { self?.automaticallyChecksMirror = value }
            },
        ]
    }

    /// "Check for updates automatically" (Sparkle keeps it in the app's preferences; on by
    /// default through `SUEnableAutomaticChecks`). Off when the updater does not run.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard let controller else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            automaticallyChecksMirror = newValue
        }
    }

    /// "Check now", and the "Update available" reminder: Sparkle's own window shows the result (or
    /// brings the update found in the background into focus).
    func checkForUpdates() {
        guard let controller, canCheckForUpdates || pendingUpdateVersion != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// "Version 1.0.0 (1)" for the window.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(version) (\(build))")
    }

    /// "Update available: Voxum 1.2.0…" (menu item and window button).
    static func updateAvailableTitle(_ version: String) -> String {
        String(localized: "Update available: \(AppIdentity.name) \(version)…")
    }
}

/// Sparkle's standard user driver delegate for gentle scheduled-update reminders.
@MainActor
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
    /// The pending version, or nil when the reminder goes away.
    var onChange: ((String?) -> Void)?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when it would come up in focus (e.g. right
    /// after launch); otherwise the app shows the reminder. No side effects here (Sparkle's rule).
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        DispatchQueue.main.async { [weak self] in self?.onChange?(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async { [weak self] in self?.onChange?(nil) }
    }
}

/// Sparkle's updater delegate: "Install and Relaunch" (or an install at quit) waits while a dictation or
/// question is still processing or pasting, so its text (and the clipboard restore) is not lost.
/// The quit itself is guarded too (`AppDelegate.applicationShouldTerminate`).
@MainActor
private final class RelaunchGuard: NSObject, SPUUpdaterDelegate {
    var isBusy: () -> Bool = { false }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls its delegate on the main thread.
        MainActor.assumeIsolated {
            guard isBusy() else { return false }
            appLog("update: relaunch waits for the dictation in progress")
            WhenIdle.run(isBusy: isBusy, installHandler)
            return true
        }
    }
}

/// Runs `action` once `isBusy` turns false (checked every 0.1 s), or after `cap` seconds at most, so a
/// stuck take never blocks a quit or an update for good.
@MainActor
enum WhenIdle {
    static func run(cap: TimeInterval = 15, isBusy: @escaping () -> Bool, _ action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(cap)
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !isBusy() || Date() >= deadline else { return }
                timer.invalidate()
                action()
            }
        }
        // Common modes: after `.terminateLater` AppKit runs the run loop in the modal panel mode.
        RunLoop.main.add(timer, forMode: .common)
    }
}
