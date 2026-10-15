// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TranscricaoCore

/// Feeds the watched trigger keys (Settings: the dictation key, and the question key when one is
/// set and a text model can answer), other key presses and clicks into one state machine per key,
/// and reports which key an action belongs to. Listens only (events are never swallowed).
/// Requires Accessibility.
@MainActor
final class HotkeyMonitor {
    /// The keys watched, each with its own gesture (hold, double tap, continuous).
    private(set) var keys: [TriggerKey] = [.default]
    private var machines: [TriggerKey: HotkeyStateMachine] = [.default: HotkeyStateMachine()]
    private var tickTimers: [TriggerKey: Timer] = [:]
    private var monitors: [Any] = []
    var onAction: ((HotkeyAction, TriggerKey) -> Void)?
    var onContinuousChange: ((Bool, TriggerKey) -> Void)?
    /// Every real Esc press, whatever the gesture state (cancels an edit/answer in flight).
    var onEscape: (() -> Void)?
    /// Watched keys physically down (last real event seen).
    private(set) var heldKeys: Set<TriggerKey> = []
    /// Uptime of the last real key press or click other than a watched key (the key used as a
    /// modifier, e.g. right ⌘ + C).
    private(set) var lastOtherInputAt: TimeInterval = 0
    /// Every real key press or click other than a watched key, anywhere (`event.window` is set only
    /// for clicks in the app's own windows). Lets the undo pill ignore the click on itself.
    var onOtherInput: ((NSEvent) -> Void)?
    /// A click that is not the user's input in their app (a click on the undo pill): it neither
    /// counts in `lastOtherInputAt` nor reaches `onOtherInput`.
    var isPassiveClick: ((NSEvent) -> Bool)?

    /// Watches `keys` from now on (duplicates dropped). A key that stays watched keeps its gesture
    /// and held state (turning the question key on or off never disturbs a dictation hold); the
    /// gesture of a key no longer watched is dropped, so the caller must end a recording held
    /// with it.
    func setKeys(_ keys: [TriggerKey]) {
        var unique: [TriggerKey] = []
        for key in keys where !unique.contains(key) { unique.append(key) }
        for key in self.keys where !unique.contains(key) {
            reset(key)
            heldKeys.remove(key)
        }
        self.keys = unique
        var kept: [TriggerKey: HotkeyStateMachine] = [:]
        for key in unique { kept[key] = machines[key] ?? HotkeyStateMachine() }
        machines = kept
    }

    /// Safe to call again (e.g. after Accessibility is granted, or the key changed): replaces old monitors.
    func start() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(local) }
    }

    /// Drops any in-progress gesture of every key (used when capture is stopped without the key,
    /// e.g. the 5-minute limit, or when the keys change).
    func reset() {
        for key in keys { reset(key) }
    }

    /// Drops `key`'s gesture only (a start refused for that key; another key's hold goes on).
    func reset(_ key: TriggerKey) {
        let wasContinuous = machines[key]?.isContinuous == true
        machines[key]?.reset()
        tickTimers[key]?.invalidate()
        tickTimers[key] = nil
        if wasContinuous { onContinuousChange?(false, key) }
    }

    private func handle(_ event: NSEvent) {
        // Our own synthetic events (⌘V, ⌘C, ⌘Z, and the trigger release/re-press around a ⌘C capture
        // while the key is held) must not count as the user: checked first, the release and the
        // re-press carry the key's code and would end, or start, a take.
        if event.type == .keyDown || event.type == .flagsChanged,
           event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker { return }
        let kind: HotkeyInput.Kind
        switch event.type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .leftMouseDown: kind = .leftMouseDown
        case .rightMouseDown: kind = .rightMouseDown
        case .otherMouseDown: kind = .otherMouseDown
        default: return
        }
        // NSEvent's modifier flags carry the device-dependent bits too (same layout as CGEventFlags).
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        let keyCode = kind == .flagsChanged || kind == .keyDown ? event.keyCode : 0
        let input = HotkeyInput.classify(kind, keyCode: keyCode, flags: flags, watching: keys)

        if input.isUserInput {
            let passive = event.type != .keyDown && isPassiveClick?(event) == true
            if !passive {
                lastOtherInputAt = event.timestamp
                onOtherInput?(event)
            }
        }
        if input == .escape { onEscape?() }
        guard let machineEvent = input.machineEvent(at: event.timestamp) else { return }
        if case .trigger(let key, let down) = input {
            if down { heldKeys.insert(key) } else { heldKeys.remove(key) }
            feed(machineEvent, to: key)
        } else {
            // Another key, a click or Esc: every watched key's gesture sees it.
            for key in keys { feed(machineEvent, to: key) }
        }
    }

    private func feed(_ event: HotkeyEvent, to key: TriggerKey) {
        guard let wasContinuous = machines[key]?.isContinuous else { return }
        let actions = machines[key]?.handle(event) ?? []
        for action in actions { onAction?(action, key) }
        // Read again: an action may have reset the machine (a refused start) or changed the keys.
        guard let machine = machines[key] else { return }
        if machine.isContinuous != wasContinuous { onContinuousChange?(machine.isContinuous, key) }

        tickTimers[key]?.invalidate()
        tickTimers[key] = nil
        if case .awaitingSecondTap = machine.state {
            tickTimers[key] = Timer.scheduledTimer(withTimeInterval: HotkeyStateMachine.doubleTapWindow + 0.02,
                                                   repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.feed(.tick(ProcessInfo.processInfo.systemUptime), to: key)
                }
            }
        }
    }
}
