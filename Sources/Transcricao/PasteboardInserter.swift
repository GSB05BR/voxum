// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox // IsSecureEventInputEnabled
import TranscricaoCore

/// Marks key events posted by this app so the hotkey monitor can ignore them.
enum SyntheticEvent { static let marker: Int64 = 0x5052_4F53_41 }

/// Pasteboard items only ever touched on the main actor; wrapped to cross the await.
struct SavedClipboard: @unchecked Sendable {
    let items: [NSPasteboardItem]
    /// changeCount right after we wrote our text; if it moved, the user copied something meanwhile.
    let changeCount: Int
}

/// Pastes text into the focused field: stash clipboard → write text → ⌘V → restore.
struct PasteboardInserter: TextInserter {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let restoreDelay: UInt64 = 250_000_000

    /// Called (on the main actor) when the app itself is frontmost at paste time: the text is left
    /// on the clipboard instead of pasting ⌘V into our own window.
    var onCopiedOnly: @MainActor @Sendable () -> Void = {}
    /// Called (on the main actor) right before deciding where the paste goes, e.g. so the answer
    /// panel, if the user clicked into it meanwhile, gives the keyboard back to their app.
    var beforePaste: @MainActor @Sendable () -> Void = {}
    /// Called (on the main actor) right after the ⌘V was posted.
    var onPasted: @MainActor @Sendable () -> Void = {}

    func insert(_ text: String) async {
        let copiedOnly = await MainActor.run { () -> Bool in
            beforePaste()
            guard NSApp.isActive else { return false }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            onCopiedOnly()
            return true
        }
        if copiedOnly { return }
        let saved = await MainActor.run { () -> SavedClipboard in
            let saved = Self.writeAndPaste(text)
            onPasted()
            return saved
        }
        try? await Task.sleep(nanoseconds: Self.restoreDelay)
        await MainActor.run { Self.restore(saved) }
    }

    @MainActor
    private static func writeAndPaste(_ text: String) -> SavedClipboard {
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot.take(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType) // clipboard managers skip it
        pb.writeObjects([item])
        let count = pb.changeCount
        SyntheticEvent.postCommand(key: SyntheticEvent.vKey)
        return SavedClipboard(items: saved, changeCount: count)
    }

    @MainActor
    private static func restore(_ saved: SavedClipboard) {
        PasteboardSnapshot.restore(saved.items, to: .general, ifChangeCount: saved.changeCount)
    }
}

/// Copies of the pasteboard contents, so a synthetic ⌘V/⌘C can be undone.
enum PasteboardSnapshot {
    /// Every item with all its eagerly available types (dyn.* = lazy/promised types are skipped).
    @MainActor
    static func take(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types where !type.rawValue.hasPrefix("dyn.") {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Puts `items` back unless the pasteboard changed since `changeCount` (the user copied
    /// something meanwhile: theirs wins).
    @MainActor
    static func restore(_ items: [NSPasteboardItem], to pb: NSPasteboard, ifChangeCount changeCount: Int) {
        guard pb.changeCount == changeCount else { return }
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

extension SyntheticEvent {
    static let vKey: CGKeyCode = 9 // kVK_ANSI_V
    static let cKey: CGKeyCode = 8 // kVK_ANSI_C

    /// Posts ⌘<key> (the selection capture's ⌘C) while the user physically holds `trigger` for
    /// push-to-talk, following `TriggerKey.commandCopySteps`: right ⌘ and Fn stay down (⌘C is
    /// still ⌘C). Right ⌥/⇧ are released for the system first (a held one would make it ⌥⌘C or
    /// ⇧⌘C even with explicit flags: apps read the system's modifier state), then pressed again
    /// right after if the user still holds them, so their next key keeps its modifier.
    /// `isHeld` is the hotkey monitor's state, built from real events only: the system's key-state
    /// table may already show our own release, so it is never asked. Every event is tagged with
    /// `marker`: the monitor ignores them all (no start, stop or cancel, no change to `isHeld`).
    /// Under Secure Event Input the monitor sees no events, so it would never see the user let go
    /// of a re-pressed key: no re-press then (see `commandCopySteps`).
    @MainActor
    static func postCommandWhileHolding(_ trigger: TriggerKey, key: CGKeyCode, isHeld: @escaping @MainActor () -> Bool) {
        let steps = trigger.commandCopySteps(heldAtCheck: isHeld(), secureInput: IsSecureEventInputEnabled())
        for step in steps {
            switch step {
            case .release: postModifier(trigger, down: false, flags: trigger.flagsAfterRelease(CGEventSource.flagsState(.hidSystemState)))
            case .commandC: postCommand(key: key)
            case .repress: postModifier(trigger, down: true, flags: trigger.flagsForRepress(CGEventSource.flagsState(.hidSystemState)))
            }
        }
        guard steps.contains(.repress) else { return }
        // A real key-up may have been queued but not yet delivered to the monitor when it said
        // "held" (or come right after): once the run loop has delivered pending events, look again
        // and release the key if the user let go, or the system would keep it down. Several times
        // (`recheckDelays`), in case the main thread was busy.
        for delay in recheckDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard trigger.releaseOnRecheck(after: steps, heldNow: isHeld()) else { return }
                    postModifier(trigger, down: false, flags: trigger.flagsAfterRelease(CGEventSource.flagsState(.hidSystemState)))
                }
            }
        }
    }

    /// Re-checks after a re-press (seconds). A second release when the key is already up is harmless.
    /// The last one covers a main thread stalled past 0.3 s (Task 4 review M1).
    static let recheckDelays: [TimeInterval] = [0.05, 0.3, 1.0]

    /// A flagsChanged of `trigger` (the modifier itself, as the keyboard sends it), tagged with `marker`.
    private static func postModifier(_ trigger: TriggerKey, down: Bool, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(trigger.keyCode), keyDown: down)
        else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    /// Posts ⌘<key> tagged with `marker` (the hotkey monitor ignores it).
    static func postCommand(key: CGKeyCode) {
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        for event in [down, up] {
            event?.flags = SyntheticShortcut.commandFlags // exactly ⌘, whatever physical modifiers are held
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
