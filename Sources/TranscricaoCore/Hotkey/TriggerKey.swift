// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// A key held to dictate (spec §3): the right-hand modifiers, whose left twins stay free for
/// shortcuts, or Fn/🌐. The raw value is what Settings saves.
public enum TriggerKey: String, CaseIterable, Sendable {
    case rightOption, rightCommand, rightShift, fn

    /// Existing installs saved no key: they keep right ⌥.
    public static let `default`: TriggerKey = .rightOption

    /// The saved choice; nothing saved (or a value this version doesn't know) reads as the default.
    public static func saved(_ rawValue: String?) -> TriggerKey {
        rawValue.flatMap(TriggerKey.init(rawValue:)) ?? .default
    }

    /// Virtual key code of its flagsChanged events (kVK_RightOption, kVK_RightCommand,
    /// kVK_RightShift, kVK_Function).
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightShift: 60
        case .fn: 63
        }
    }

    /// The device-independent modifier flag (shared with the left-hand twin).
    public var flag: CGEventFlags {
        switch self {
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightShift: .maskShift
        case .fn: .maskSecondaryFn
        }
    }

    /// The bit set only while this physical key is down (IOLLEvent.h `NX_DEVICER*KEYMASK`). The
    /// generic flag stays set while the left twin is held, so it can't tell right ⌘ released from
    /// left ⌘ still down. Fn has one key: its flag.
    public var deviceMask: UInt64 {
        switch self {
        case .rightOption: 0x40   // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10  // NX_DEVICERCMDKEYMASK
        case .rightShift: 0x04    // NX_DEVICERSHIFTKEYMASK
        case .fn: CGEventFlags.maskSecondaryFn.rawValue // NX_SECONDARYFNMASK
        }
    }

    /// For a flagsChanged event: whether this key is now down, or nil when the event is about
    /// another key (left ⌘ for right ⌘, another modifier, Caps Lock…). Only flagsChanged events
    /// may be passed: arrow and other keys carry `.maskSecondaryFn` on their key presses.
    public func isDown(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        guard keyCode == self.keyCode else { return nil }
        return flags.rawValue & deviceMask != 0
    }

    /// The left-hand twin's device bit (nil for Fn): while it is down the generic flag stays.
    var twinDeviceMask: UInt64? {
        switch self {
        case .rightOption: 0x20   // NX_DEVICELALTKEYMASK
        case .rightCommand: 0x08  // NX_DEVICELCMDKEYMASK
        case .rightShift: 0x02    // NX_DEVICELSHIFTKEYMASK
        case .fn: nil
        }
    }

    /// Delay before the start sound/HUD and before a ⌘C selection capture: the time a use of the
    /// key as a modifier has to show itself (another key or a click cancels first, with no
    /// feedback). ⌘ and ⇧ are everyday modifiers, often held a moment before the letter.
    public var startDelay: TimeInterval {
        switch self {
        case .rightOption, .fn: 0.2
        case .rightCommand, .rightShift: 0.35
        }
    }

    /// A hold that ends before `startDelay` had no start sound/HUD and is shorter than any clip
    /// the speech gate keeps (`SpeechGate.minDuration`): cancel it instead of processing it, so no
    /// processing pill flashes for an abandoned shortcut (right ⌘ held 0.3 s, then let go).
    public func cancelsStop(heldFor duration: TimeInterval) -> Bool {
        duration < startDelay
    }

    // MARK: ⌘C selection capture while the key is held

    /// Whether this key is released for the system before the synthetic ⌘C. Only right ⌥ and
    /// right ⇧ are: held, they would make it ⌥⌘C (inspector) or ⇧⌘C. Right ⌘ is not (it is the
    /// shortcut's own modifier, and the user's own slow ⌘C/⌘V keeps its ⌘), and neither is Fn (it
    /// doesn't change ⌘C, and a synthetic Fn up/down would count as a 🌐 press for macOS).
    public var releasedForCommandC: Bool {
        switch self {
        case .rightOption, .rightShift: true
        case .rightCommand, .fn: false
        }
    }

    /// After the ⌘C: press the key again (for the system) only if it was released for the copy
    /// and the user still holds it; otherwise their next key would arrive without the modifier
    /// (a lowercase letter with ⇧). Let go meanwhile = nothing, so nothing stays stuck.
    /// `stillDown` must come from real events only (the hotkey monitor's held keys): the system's
    /// key-state table may already reflect our own synthetic release.
    public func repressAfterCommandC(stillDown: Bool) -> Bool {
        releasedForCommandC && stillDown
    }

    /// What is posted, in order, for the selection capture's ⌘C while this key is held.
    /// `heldAtCheck`: the monitor's state when the ⌘C is sent (a real key-up still queued reads as
    /// held: `releaseOnRecheck` corrects it).
    /// `secureInput`: Secure Event Input is on (a password field somewhere). Global monitors then
    /// get no events, so the monitor would never see the user let go of a re-pressed key and the
    /// system would keep it down: no re-press (the modifier may be lost, but never stuck).
    public func commandCopySteps(heldAtCheck: Bool, secureInput: Bool = false) -> [CommandCopyStep] {
        guard releasedForCommandC else { return [.commandC] }
        let repress = repressAfterCommandC(stillDown: heldAtCheck) && !secureInput
        return repress ? [.release, .commandC, .repress] : [.release, .commandC]
    }

    /// Re-check once pending events were delivered: a re-pressed key the monitor now sees up
    /// (released just before or after the re-press) must be released, or the system would keep
    /// it down.
    public func releaseOnRecheck(after steps: [CommandCopyStep], heldNow: Bool) -> Bool {
        steps.contains(.repress) && !heldNow
    }

    /// Flags of the synthetic release: what is held (`held`, the hardware state) without this
    /// key; the generic flag stays if the left twin is down too.
    public func flagsAfterRelease(_ held: CGEventFlags) -> CGEventFlags {
        var raw = held.rawValue & ~deviceMask
        if twinDeviceMask.map({ raw & $0 == 0 }) ?? true { raw &= ~flag.rawValue }
        return CGEventFlags(rawValue: raw)
    }

    /// Flags of the synthetic re-press: what is held plus this key.
    public func flagsForRepress(_ held: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: held.rawValue | flag.rawValue | deviceMask)
    }

    /// Picker label (window and menu).
    public var title: String {
        switch self {
        case .rightOption: String(localized: "Right ⌥ Option", bundle: .main)
        case .rightCommand: String(localized: "Right ⌘ Command", bundle: .main)
        case .rightShift: String(localized: "Right ⇧ Shift", bundle: .main)
        case .fn: String(localized: "Fn / 🌐 Globe", bundle: .main)
        }
    }

    /// Short name inside a sentence ("Hold right ⌥ to speak…").
    public var name: String {
        switch self {
        case .rightOption: String(localized: "right ⌥", bundle: .main)
        case .rightCommand: String(localized: "right ⌘", bundle: .main)
        case .rightShift: String(localized: "right ⇧", bundle: .main)
        case .fn: String(localized: "Fn/🌐", bundle: .main)
        }
    }
}

// MARK: - Question key (spec §4)

/// The question key (spec §4): Off (nil, the default) or one of the trigger keys, never the
/// dictation key. Pure rules, so Settings, the window and the menu agree.
public enum TriggerKeyValidation {
    /// What Settings saves for Off (any value that isn't a key also reads as Off).
    public static let offValue = "off"

    /// The saved question key: nothing saved, "off" or an unknown value is Off (nil).
    public static func savedQuestion(_ rawValue: String?) -> TriggerKey? {
        rawValue.flatMap(TriggerKey.init(rawValue:))
    }

    /// False when the question key is the dictation key (Off is always allowed).
    public static func allowed(dictation: TriggerKey, question: TriggerKey?) -> Bool {
        question != dictation
    }

    /// The question key in effect: a saved value equal to the dictation key reads as Off.
    public static func effectiveQuestion(saved: TriggerKey?, dictation: TriggerKey) -> TriggerKey? {
        allowed(dictation: dictation, question: saved) ? saved : nil
    }

    /// The keys the question picker offers (besides Off): every key but the dictation key.
    public static func questionChoices(dictation: TriggerKey) -> [TriggerKey] {
        TriggerKey.allCases.filter { $0 != dictation }
    }

    /// The dictation key changed to `newDictation`: the question key becomes Off when it is the new
    /// dictation key (the UI says so).
    public static func clearsQuestion(_ newDictation: TriggerKey, question: TriggerKey?) -> Bool {
        question == newDictation
    }

    /// The keys the hotkey monitor watches: the dictation key, plus the question key when one is
    /// set and a text model can answer (`questionAvailable`: not "No AI").
    public static func watchedKeys(dictation: TriggerKey, question: TriggerKey?, questionAvailable: Bool) -> [TriggerKey] {
        guard questionAvailable, let question = effectiveQuestion(saved: question, dictation: dictation) else {
            return [dictation]
        }
        return [dictation, question]
    }
}

/// One synthetic event around the selection capture's ⌘C (all tagged with the app's marker).
public enum CommandCopyStep: Equatable, Sendable {
    /// The trigger released for the system (flagsChanged up).
    case release
    case commandC
    /// The trigger pressed again for the system (flagsChanged down).
    case repress
}

/// Shortcuts this app posts (⌘V, ⌘C, ⌘Z).
public enum SyntheticShortcut {
    /// Exactly ⌘, whatever modifiers the user physically holds: never ⇧⌘C or ⌥⌘C.
    public static let commandFlags: CGEventFlags = .maskCommand
}

/// One keyboard or mouse event, as the hotkey state machines and the "other input" trackers see
/// it. Pure, so the routing (which key fired, what counts as another key) is testable without
/// real events; synthetic events are filtered out before this by the monitor.
public enum HotkeyInput: Equatable, Sendable {
    /// A watched key went down or up.
    case trigger(TriggerKey, down: Bool)
    case escape
    /// A key press or a left/right click: the trigger is being used as a modifier (⌘C, ⇧A, ⌥E,
    /// ⌥+click): cancels a hold.
    case otherKey
    /// A wheel or side button: the user's input (the undo pill goes), but a hold goes on.
    case otherButton
    /// Another modifier alone, or the 🌐 key's own key press: nothing.
    case ignored

    public enum Kind: Sendable { case flagsChanged, keyDown, leftMouseDown, rightMouseDown, otherMouseDown }

    public static let escapeKeyCode: UInt16 = 53
    /// Possible key presses of the 🌐 key itself (kVK_Function, and the Globe usage some
    /// keyboards report): never "another key" while Fn is held.
    static let fnKeyDownCodes: Set<UInt16> = [63, 179]

    public static func classify(_ kind: Kind, keyCode: UInt16, flags: CGEventFlags,
                                watching keys: [TriggerKey]) -> HotkeyInput {
        switch kind {
        case .flagsChanged:
            for key in keys {
                if let down = key.isDown(keyCode: keyCode, flags: flags) { return .trigger(key, down: down) }
            }
            return .ignored // other modifiers alone do not cancel
        case .keyDown:
            if keyCode == escapeKeyCode { return .escape }
            if keys.contains(.fn), fnKeyDownCodes.contains(keyCode) { return .ignored }
            return .otherKey
        case .leftMouseDown, .rightMouseDown:
            return .otherKey
        case .otherMouseDown:
            return .otherButton
        }
    }

    /// Counts as the user typing or clicking (undo pill, late ⌘C copies): everything but the
    /// watched keys themselves and lone modifiers.
    public var isUserInput: Bool {
        switch self {
        case .escape, .otherKey, .otherButton: true
        case .trigger, .ignored: false
        }
    }

    /// What every watched key's state machine receives (the `.trigger` only its own key's).
    public func machineEvent(at timestamp: TimeInterval) -> HotkeyEvent? {
        switch self {
        case .trigger(_, let down): down ? .keyDown(timestamp) : .keyUp(timestamp)
        case .escape: .escape
        case .otherKey: .otherKey
        case .otherButton, .ignored: nil
        }
    }
}
