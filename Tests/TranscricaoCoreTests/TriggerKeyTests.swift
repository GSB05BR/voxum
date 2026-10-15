// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import TranscricaoCore

final class TriggerKeyTests: XCTestCase {
    // Device-dependent bits (IOLLEvent.h): set only while that physical key is down.
    private let leftShift: UInt64 = 0x02, rightShift: UInt64 = 0x04
    private let leftCommand: UInt64 = 0x08, rightCommand: UInt64 = 0x10
    private let leftOption: UInt64 = 0x20, rightOption: UInt64 = 0x40

    private func flags(_ generic: CGEventFlags, _ device: UInt64 = 0) -> CGEventFlags {
        CGEventFlags(rawValue: generic.rawValue | device)
    }

    // MARK: - Mapping

    func testKeyCodes() {
        XCTAssertEqual(TriggerKey.rightOption.keyCode, 61)
        XCTAssertEqual(TriggerKey.rightCommand.keyCode, 54)
        XCTAssertEqual(TriggerKey.rightShift.keyCode, 60)
        XCTAssertEqual(TriggerKey.fn.keyCode, 63)
    }

    func testFlags() {
        XCTAssertEqual(TriggerKey.rightOption.flag, .maskAlternate)
        XCTAssertEqual(TriggerKey.rightCommand.flag, .maskCommand)
        XCTAssertEqual(TriggerKey.rightShift.flag, .maskShift)
        XCTAssertEqual(TriggerKey.fn.flag, .maskSecondaryFn)
    }

    func testRawValuesAreStableForSettings() {
        XCTAssertEqual(TriggerKey.allCases.map(\.rawValue), ["rightOption", "rightCommand", "rightShift", "fn"])
    }

    func testDefaultIsRightOptionAndNothingSavedReadsAsIt() {
        XCTAssertEqual(TriggerKey.default, .rightOption)
        XCTAssertEqual(TriggerKey.saved(nil), .rightOption)
        XCTAssertEqual(TriggerKey.saved("rightCommand"), .rightCommand)
        XCTAssertEqual(TriggerKey.saved("leftHyper"), .rightOption) // unknown value: the default
    }

    func testTitlesAndNamesAreNotEmpty() {
        for key in TriggerKey.allCases {
            XCTAssertFalse(key.title.isEmpty)
            XCTAssertFalse(key.name.isEmpty)
        }
    }

    // MARK: - isDown

    func testRightOptionDownAndUp() {
        XCTAssertEqual(TriggerKey.rightOption.isDown(keyCode: 61, flags: flags(.maskAlternate, rightOption)), true)
        XCTAssertEqual(TriggerKey.rightOption.isDown(keyCode: 61, flags: []), false)
    }

    func testRightCommandDownAndUp() {
        XCTAssertEqual(TriggerKey.rightCommand.isDown(keyCode: 54, flags: flags(.maskCommand, rightCommand)), true)
        XCTAssertEqual(TriggerKey.rightCommand.isDown(keyCode: 54, flags: []), false)
    }

    func testRightShiftDownAndUp() {
        XCTAssertEqual(TriggerKey.rightShift.isDown(keyCode: 60, flags: flags(.maskShift, rightShift)), true)
        XCTAssertEqual(TriggerKey.rightShift.isDown(keyCode: 60, flags: []), false)
    }

    func testFnDownAndUp() {
        XCTAssertEqual(TriggerKey.fn.isDown(keyCode: 63, flags: .maskSecondaryFn), true)
        XCTAssertEqual(TriggerKey.fn.isDown(keyCode: 63, flags: []), false)
    }

    func testRightKeyReleasedWhileLeftOneHeldIsUp() {
        // The generic flag stays set (left ⌘ still down): only the device bit says right ⌘ went up.
        XCTAssertEqual(TriggerKey.rightCommand.isDown(keyCode: 54, flags: flags(.maskCommand, leftCommand)), false)
        XCTAssertEqual(TriggerKey.rightShift.isDown(keyCode: 60, flags: flags(.maskShift, leftShift)), false)
        XCTAssertEqual(TriggerKey.rightOption.isDown(keyCode: 61, flags: flags(.maskAlternate, leftOption)), false)
    }

    func testLeftKeysAreNotTheTrigger() {
        XCTAssertNil(TriggerKey.rightCommand.isDown(keyCode: 55, flags: flags(.maskCommand, leftCommand)))
        XCTAssertNil(TriggerKey.rightShift.isDown(keyCode: 56, flags: flags(.maskShift, leftShift)))
        XCTAssertNil(TriggerKey.rightOption.isDown(keyCode: 58, flags: flags(.maskAlternate, leftOption)))
    }

    func testAnotherKeysFlagsChangedIsNil() {
        for key in TriggerKey.allCases {
            for other in TriggerKey.allCases where other != key {
                XCTAssertNil(key.isDown(keyCode: other.keyCode, flags: flags(other.flag, 0x7E)),
                             "\(other) seen as \(key)")
            }
        }
    }

    // MARK: - HotkeyInput.classify

    func testFlagsChangedOfAWatchedKeyIsATrigger() {
        let keys: [TriggerKey] = [.rightCommand]
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 54, flags: flags(.maskCommand, rightCommand), watching: keys),
                       .trigger(.rightCommand, down: true))
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 54, flags: [], watching: keys),
                       .trigger(.rightCommand, down: false))
    }

    func testOtherModifiersAloneAreIgnored() {
        // Left ⌘ while right ⌘ is the key; right ⌥ while it is not watched; Caps Lock.
        for keyCode: UInt16 in [55, 61, 57, 56, 63] {
            XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: keyCode, flags: .maskCommand, watching: [.rightCommand]),
                           .ignored, "keyCode \(keyCode)")
        }
    }

    func testFnFlagsChanged() {
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 63, flags: .maskSecondaryFn, watching: [.fn]),
                       .trigger(.fn, down: true))
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 63, flags: [], watching: [.fn]),
                       .trigger(.fn, down: false))
    }

    func testArrowKeysCarryingTheFnFlagAreNeverFnDown() {
        // ← → ↓ ↑, Home, Page Down, forward delete: keyDowns flagged .maskSecondaryFn.
        for keyCode: UInt16 in [123, 124, 125, 126, 115, 121, 117] {
            XCTAssertEqual(HotkeyInput.classify(.keyDown, keyCode: keyCode, flags: .maskSecondaryFn, watching: [.fn]),
                           .otherKey, "keyCode \(keyCode)")
        }
        // Another modifier's flagsChanged while an arrow is held: still not Fn.
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 56, flags: [.maskSecondaryFn, .maskShift], watching: [.fn]),
                       .ignored)
    }

    func testFnKeyDownEchoIsNotAnotherKey() {
        // Some keyboards may also report the 🌐 key as a key press: it must not cancel its own hold.
        XCTAssertEqual(HotkeyInput.classify(.keyDown, keyCode: 63, flags: .maskSecondaryFn, watching: [.fn]), .ignored)
        XCTAssertEqual(HotkeyInput.classify(.keyDown, keyCode: 179, flags: .maskSecondaryFn, watching: [.fn]), .ignored)
        // …but only when Fn is the key: otherwise it is input like any other.
        XCTAssertEqual(HotkeyInput.classify(.keyDown, keyCode: 179, flags: [], watching: [.rightOption]), .otherKey)
    }

    func testEscapeAndKeys() {
        XCTAssertEqual(HotkeyInput.classify(.keyDown, keyCode: 53, flags: [], watching: [.rightOption]), .escape)
        XCTAssertEqual(HotkeyInput.classify(.keyDown, keyCode: 8, flags: .maskCommand, watching: [.rightCommand]), .otherKey)
    }

    func testClicks() {
        XCTAssertEqual(HotkeyInput.classify(.leftMouseDown, keyCode: 0, flags: [], watching: [.rightOption]), .otherKey)
        XCTAssertEqual(HotkeyInput.classify(.rightMouseDown, keyCode: 0, flags: [], watching: [.rightOption]), .otherKey)
        // A wheel/side button is input (undo pill) but does not cancel a hold.
        let other = HotkeyInput.classify(.otherMouseDown, keyCode: 0, flags: [], watching: [.rightOption])
        XCTAssertEqual(other, .otherButton)
        XCTAssertTrue(other.isUserInput)
        XCTAssertNil(other.machineEvent(at: 1))
    }

    func testMachineEventsAndUserInput() {
        XCTAssertEqual(HotkeyInput.trigger(.fn, down: true).machineEvent(at: 2), .keyDown(2))
        XCTAssertEqual(HotkeyInput.trigger(.fn, down: false).machineEvent(at: 3), .keyUp(3))
        XCTAssertEqual(HotkeyInput.otherKey.machineEvent(at: 0), .otherKey)
        XCTAssertEqual(HotkeyInput.escape.machineEvent(at: 0), .escape)
        XCTAssertNil(HotkeyInput.ignored.machineEvent(at: 0))
        XCTAssertFalse(HotkeyInput.trigger(.rightOption, down: true).isUserInput)
        XCTAssertFalse(HotkeyInput.ignored.isUserInput)
        XCTAssertTrue(HotkeyInput.otherKey.isUserInput)
        XCTAssertTrue(HotkeyInput.escape.isUserInput)
    }

    func testTwoWatchedKeysReportWhichOneFired() {
        let keys: [TriggerKey] = [.rightOption, .rightCommand]
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 61, flags: flags(.maskAlternate, rightOption), watching: keys),
                       .trigger(.rightOption, down: true))
        XCTAssertEqual(HotkeyInput.classify(.flagsChanged, keyCode: 54, flags: flags(.maskCommand, rightCommand), watching: keys),
                       .trigger(.rightCommand, down: true))
    }

    // MARK: - The key used as a modifier (spec §3)

    /// Right ⌘ held, then C (⌘C): the press reaches the state machine as another key and cancels.
    func testRightCommandPlusKeyCancels() {
        var m = HotkeyStateMachine()
        let keys: [TriggerKey] = [.rightCommand]
        let down = HotkeyInput.classify(.flagsChanged, keyCode: 54, flags: flags(.maskCommand, rightCommand), watching: keys)
        XCTAssertEqual(m.handle(down.machineEvent(at: 10)!), [.startCapture])
        let c = HotkeyInput.classify(.keyDown, keyCode: 8, flags: flags(.maskCommand, rightCommand), watching: keys)
        XCTAssertEqual(m.handle(c.machineEvent(at: 10.05)!), [.cancel])
        XCTAssertEqual(m.state, .idle)
        let up = HotkeyInput.classify(.flagsChanged, keyCode: 54, flags: [], watching: keys)
        XCTAssertEqual(m.handle(up.machineEvent(at: 10.6)!), []) // the release does nothing more
    }

    /// Right ⇧ held for a capital letter: same.
    func testRightShiftPlusLetterCancels() {
        var m = HotkeyStateMachine()
        let keys: [TriggerKey] = [.rightShift]
        let down = HotkeyInput.classify(.flagsChanged, keyCode: 60, flags: flags(.maskShift, rightShift), watching: keys)
        XCTAssertEqual(m.handle(down.machineEvent(at: 0)!), [.startCapture])
        let a = HotkeyInput.classify(.keyDown, keyCode: 0, flags: flags(.maskShift, rightShift), watching: keys)
        XCTAssertEqual(m.handle(a.machineEvent(at: 0.3)!), [.cancel])
        XCTAssertEqual(m.state, .idle)
    }

    /// Left ⌘ + C with right ⌘ as the key: nothing starts at all.
    func testLeftCommandShortcutNeverStarts() {
        var m = HotkeyStateMachine()
        let keys: [TriggerKey] = [.rightCommand]
        let down = HotkeyInput.classify(.flagsChanged, keyCode: 55, flags: flags(.maskCommand, leftCommand), watching: keys)
        XCTAssertNil(down.machineEvent(at: 0))
        let c = HotkeyInput.classify(.keyDown, keyCode: 8, flags: flags(.maskCommand, leftCommand), watching: keys)
        XCTAssertEqual(m.handle(c.machineEvent(at: 0.1)!), [])
        XCTAssertEqual(m.state, .idle)
    }

    /// Fn alone: hold to dictate, double tap for continuous.
    func testFnAloneWorks() {
        var m = HotkeyStateMachine()
        let keys: [TriggerKey] = [.fn]
        func fn(_ down: Bool, _ t: TimeInterval) -> [HotkeyAction] {
            let input = HotkeyInput.classify(.flagsChanged, keyCode: 63, flags: down ? .maskSecondaryFn : [], watching: keys)
            return m.handle(input.machineEvent(at: t)!)
        }
        XCTAssertEqual(fn(true, 0), [.startCapture])
        XCTAssertEqual(fn(false, 1), [.stopAndProcess])
        XCTAssertEqual(fn(true, 5), [.startCapture])
        XCTAssertEqual(fn(false, 5.1), [])
        XCTAssertEqual(fn(true, 5.3), [])
        XCTAssertTrue(m.isContinuous)
    }
}

// MARK: - Fix round 1: ⌘C capture while the key is held, and the start delay

final class TriggerKeyCommandCopyTests: XCTestCase {
    private let leftOption: UInt64 = 0x20, rightOption: UInt64 = 0x40
    private let leftShift: UInt64 = 0x02, rightShift: UInt64 = 0x04, rightCommand: UInt64 = 0x10

    private func flags(_ generic: CGEventFlags, _ device: UInt64 = 0) -> CGEventFlags {
        CGEventFlags(rawValue: generic.rawValue | device)
    }

    /// Right ⌘ is already the shortcut's modifier: no synthetic up, so the user's own slow ⌘C/⌘V
    /// keeps its ⌘. Fn doesn't change ⌘C and a synthetic Fn up would count as a 🌐 press.
    func testWhichKeysAreReleasedForCommandC() {
        XCTAssertTrue(TriggerKey.rightOption.releasedForCommandC)   // ⌥⌘C opens the inspector
        XCTAssertTrue(TriggerKey.rightShift.releasedForCommandC)    // ⇧⌘C: inspect element, Finder: Computer
        XCTAssertFalse(TriggerKey.rightCommand.releasedForCommandC)
        XCTAssertFalse(TriggerKey.fn.releasedForCommandC)
    }

    func testRepressOnlyWhenReleasedAndStillDown() {
        for key in TriggerKey.allCases {
            XCTAssertEqual(key.repressAfterCommandC(stillDown: true), key.releasedForCommandC, "\(key)")
            XCTAssertFalse(key.repressAfterCommandC(stillDown: false), "\(key): let go meanwhile")
        }
    }

    // "Held" below is the hotkey monitor's state, built from real (unmarked) events only: our own
    // synthetic release can't make it read "up", so it can't suppress the re-press.

    func testStepsForKeysThatStayDown() {
        for key in [TriggerKey.rightCommand, .fn] {
            XCTAssertEqual(key.commandCopySteps(heldAtCheck: true), [.commandC])
            XCTAssertEqual(key.commandCopySteps(heldAtCheck: false), [.commandC])
        }
    }

    func testStillHeld() {
        for key in [TriggerKey.rightOption, .rightShift] {
            let steps = key.commandCopySteps(heldAtCheck: true)
            XCTAssertEqual(steps, [.release, .commandC, .repress])
            // Re-check once pending events are delivered: still held = leave it pressed.
            XCTAssertFalse(key.releaseOnRecheck(after: steps, heldNow: true))
        }
    }

    func testReleasedBeforeTheCheck() {
        for key in [TriggerKey.rightOption, .rightShift] {
            let steps = key.commandCopySteps(heldAtCheck: false)
            XCTAssertEqual(steps, [.release, .commandC]) // no re-press: nothing can stay stuck
            XCTAssertFalse(key.releaseOnRecheck(after: steps, heldNow: false))
        }
    }

    /// The real key-up was already queued (or came right after the check): the monitor still said
    /// held, so the key was re-pressed; once the up is delivered the re-check releases it.
    func testReleasedBetweenCheckAndRecheck() {
        for key in [TriggerKey.rightOption, .rightShift] {
            let steps = key.commandCopySteps(heldAtCheck: true)
            XCTAssertEqual(steps.last, .repress)
            XCTAssertTrue(key.releaseOnRecheck(after: steps, heldNow: false))
        }
    }

    func testRecheckNeverReleasesWhatWasNotRepressed() {
        for key in TriggerKey.allCases {
            XCTAssertFalse(key.releaseOnRecheck(after: [.commandC], heldNow: false))
        }
    }

    func testCommandCFlagsAreExactlyCommand() {
        XCTAssertEqual(SyntheticShortcut.commandFlags, .maskCommand)
        XCTAssertFalse(SyntheticShortcut.commandFlags.contains(.maskShift))
        XCTAssertFalse(SyntheticShortcut.commandFlags.contains(.maskAlternate))
        XCTAssertFalse(SyntheticShortcut.commandFlags.contains(.maskSecondaryFn))
    }

    func testReleaseClearsOnlyThisKey() {
        // Right ⇧ alone: nothing left.
        XCTAssertEqual(TriggerKey.rightShift.flagsAfterRelease(flags(.maskShift, rightShift)).rawValue, 0)
        // Right ⇧ with left ⇧ also down: ⇧ stays (left twin), only the right device bit goes.
        XCTAssertEqual(TriggerKey.rightShift.flagsAfterRelease(flags(.maskShift, rightShift | leftShift)),
                       flags(.maskShift, leftShift))
        // Right ⌥ with left ⌘ held: ⌘ stays.
        XCTAssertEqual(TriggerKey.rightOption.flagsAfterRelease(flags([.maskAlternate, .maskCommand], rightOption | 0x08)),
                       flags(.maskCommand, 0x08))
    }

    func testRepressRestoresTheKeyWithWhatIsHeld() {
        XCTAssertEqual(TriggerKey.rightOption.flagsForRepress([]), flags(.maskAlternate, rightOption))
        XCTAssertEqual(TriggerKey.rightShift.flagsForRepress(flags(.maskCommand, 0x08)),
                       flags([.maskShift, .maskCommand], rightShift | 0x08))
        // Already in the held state: unchanged.
        XCTAssertEqual(TriggerKey.rightShift.flagsForRepress(flags(.maskShift, rightShift)), flags(.maskShift, rightShift))
    }

    /// The re-press is an ordinary flagsChanged of the key: the monitor must drop it by its marker,
    /// since unmarked it would read as the key going down.
    func testAnUnmarkedRepressWouldReadAsDown() {
        for key in TriggerKey.allCases where key.releasedForCommandC {
            XCTAssertEqual(key.isDown(keyCode: key.keyCode, flags: key.flagsForRepress([])), true)
            XCTAssertEqual(key.isDown(keyCode: key.keyCode, flags: key.flagsAfterRelease(key.flagsForRepress([]))), false)
        }
    }

    /// A hold released before the start was announced (right ⌘/⇧: 0.25–0.35 s) is shorter than
    /// any clip the speech gate keeps: it is cancelled, never shown as processing.
    func testReleaseBeforeTheAnnouncementIsCancelled() {
        for key in TriggerKey.allCases {
            XCTAssertLessThan(key.startDelay, SpeechGate().minDuration, "\(key)")
            XCTAssertTrue(key.cancelsStop(heldFor: key.startDelay - 0.01))
            XCTAssertFalse(key.cancelsStop(heldFor: key.startDelay))
        }
        XCTAssertTrue(TriggerKey.rightCommand.cancelsStop(heldFor: 0.3))
        XCTAssertFalse(TriggerKey.rightOption.cancelsStop(heldFor: 0.3))
    }

    func testStartDelayIsLongerForEverydayModifiers() {
        XCTAssertEqual(TriggerKey.rightOption.startDelay, 0.2)
        XCTAssertEqual(TriggerKey.fn.startDelay, 0.2)
        XCTAssertEqual(TriggerKey.rightCommand.startDelay, 0.35)
        XCTAssertEqual(TriggerKey.rightShift.startDelay, 0.35)
    }
}
