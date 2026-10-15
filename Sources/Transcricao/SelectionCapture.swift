// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import TranscricaoCore

/// Reads the text selected in the frontmost app when a dictation starts and tells whether it is
/// editable (edit by voice: the result replaces it) or read-only (the answer goes to a panel).
/// Accessibility first (facts → `SelectionClassifier`); a synthetic ⌘C (pasteboard restored right
/// after) only when accessibility cannot tell. Runs concurrently with the recording, never on the
/// release → paste path. Logs only kinds and lengths, never the text.
enum SelectionCapture {
    /// AX calls into a hung app would otherwise block for seconds.
    static let axTimeout: Float = 0.1
    static let manualAccessibility = "AXManualAccessibility" as CFString

    /// Apps (by pid, i.e. per app run) where switching the accessibility tree on was attempted.
    @MainActor private static var accessibilitySwitchAttempted: Set<pid_t> = []
    /// Short: a hung Electron app must not hold anything up (this runs off the main thread anyway).
    static let switchTimeout: Float = 0.25

    /// Re-reads of the focused element after the tree was requested (~100 ms apart, ≈500 ms total).
    static let upgradeAttempts = 5
    static let upgradeInterval: UInt64 = 100_000_000

    /// Where a capture came from, to check before an edit is pasted that it still applies.
    struct Target: Sendable {
        let pid: pid_t
        /// Read through accessibility (else through ⌘C: the app may not expose its selection).
        let viaAccessibility: Bool
    }

    struct Result: Sendable {
        var selection: CapturedSelection
        var target: Target?
        static let none = Result(selection: .none, target: nil)
    }

    /// `trigger` is the key held for this recording: the ⌘C fallback is posted around it
    /// (`SyntheticEvent.postCommandWhileHolding`); `triggerHeld` says whether the user still holds
    /// it, from real events only (the hotkey monitor).
    /// `confirmCopy` is awaited before the ⌘C fallback; returning false skips it
    /// (e.g. the recording was cancelled: the key was used as a modifier).
    /// `userInputSince(t)`: the user pressed a key or clicked after uptime `t` (a late ⌘C copy then
    /// leaves the pasteboard alone: it may be the user's own copy).
    /// `onUpgrade` may be called later (main actor) with a better classification of the returned
    /// capture, once the Electron app's accessibility tree was switched on: a field first seen
    /// read-only that turned out editable, or an editable field with nothing selected (the ⌘C
    /// copied the current line: `.none`). The result is returned without waiting for that.
    @MainActor
    static func capture(trigger: TriggerKey,
                        triggerHeld: @escaping @MainActor () -> Bool,
                        copyAllowed: Bool = true,
                        confirmCopy: @escaping @MainActor () async -> Bool,
                        userInputSince: @escaping @MainActor (TimeInterval) -> Bool,
                        onUpgrade: @escaping @MainActor (CapturedSelection) -> Void = { _ in }) async -> Result {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .none }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let (facts, lookup) = await readFacts(pid)
        let kind: SelectionKind
        switch SelectionClassifier.classify(facts) {
        case .selected(let text, let kind):
            appLog("selection via accessibility (\(text.count) chars, \(kind), \(bundleID ?? "?"))")
            return Result(selection: .selected(text, kind), target: Target(pid: pid, viaAccessibility: true))
        case .none:
            return .none
        case .tryCopy(let copyKind):
            kind = copyKind
        }
        // Copy-line editors (VS Code, JetBrains…) copy the current line with nothing selected.
        guard CopyFallbackPolicy.allowsCopy(bundleID) else { return .none }
        // Another clip in flight: no ⌘C (`copyAllowed` false). See `selectionWhenCopyBlocked`.
        guard copyAllowed else {
            let selection = CopyFallbackPolicy.selectionWhenCopyBlocked(lookup: lookup)
            if selection == .unknown { appLog("selection unknown (another clip in flight, no ⌘C; focus lookup: \(lookup))") }
            return Result(selection: selection, target: nil)
        }
        guard await confirmCopy(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .none }
        // A fresh task: once ⌘C is posted, cancelling the recording must not skip the restore.
        let result = await Task { @MainActor in await copyViaCommandC(holding: trigger, isHeld: triggerHeld, userInputSince: userInputSince) }.value
        let captured = CommandCopy.selection(result, kind: kind)
        let what = switch result {
        case .copied(let text?): "\(text.count) chars, \(kind)"
        case .copied(nil): "not text"
        case .nothingCopied: "none"
        case .lateCopy: "late copy: selection unknown, clipboard restored unless the user typed or clicked"
        }
        appLog("selection via ⌘C (\(what); focus lookup: \(lookup), \(bundleID ?? "?"))")
        enableAccessibilityAndReclassify(pid: pid, bundleID: bundleID, lookup: lookup,
                                         captured: captured, onUpgrade: onUpgrade)
        return Result(selection: captured, target: Target(pid: pid, viaAccessibility: false))
    }

    /// Right before an edit is pasted: the same app is frontmost and its selection is still
    /// `text` (`EditTargetCheck`). One cheap AX read off the main thread (0.1 s messaging timeout
    /// per call, the whole check bounded); never a ⌘C. Anything not confirmed in time → false.
    @MainActor
    static func stillSelected(_ text: String, target: Target) async -> Bool {
        let sameApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        guard sameApp else {
            appLog("edit not pasted (another app is frontmost)")
            return false
        }
        let pid = target.pid
        let now = try? await withTimeout(seconds: verifyTimeout) {
            await Task.detached(priority: .userInitiated) { facts(pid: pid).0 }.value
        }
        let ok = EditTargetCheck.allowsPaste(of: text, capturedViaAccessibility: target.viaAccessibility,
                                             sameApp: true, now: now)
        if !ok { appLog("edit not pasted (selection changed or unreadable; captured via \(target.viaAccessibility ? "accessibility" : "⌘C"))") }
        return ok
    }
    static let verifyTimeout: Double = 0.6

    /// Electron/Chromium: with its accessibility tree off the app has no focused element, so an
    /// editable field was only reachable through ⌘C (classified read-only). Ask the app to build its
    /// tree (once per app run, off the main thread, short messaging timeout, only after ⌘C confirmed
    /// a real selection), then look at the focused element again a few times while the user is
    /// still speaking: an editable text field with that selection upgrades this capture to editable;
    /// one that positively reports an empty selection on two re-reads in a row turns it into `.none`
    /// (copy-line Electron editors such as Obsidian copy the current line). Not awaited.
    @MainActor
    private static func enableAccessibilityAndReclassify(pid: pid_t, bundleID: String?, lookup: FocusLookup,
                                                         captured: CapturedSelection,
                                                         onUpgrade: @escaping @MainActor (CapturedSelection) -> Void) {
        guard case .selected = captured,
              AccessibilitySwitchPolicy.shouldEnable(lookup: lookup, copiedSelection: true,
                                                     alreadyAttempted: accessibilitySwitchAttempted.contains(pid),
                                                     bundleID: bundleID) else { return }
        accessibilitySwitchAttempted.insert(pid)
        let timeout = switchTimeout
        Task.detached(priority: .utility) {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, timeout)
            let result = AXUIElementSetAttributeValue(element, manualAccessibility, kCFBooleanTrue)
            appLog("accessibility tree requested for \(bundleID ?? "?") (\(result == .success ? "ok" : "error \(result.rawValue)"))")
            guard result == .success else { return }
            var mismatch = false // diagnostics only: an editable field whose selection is not the copied text
            var previous: SelectionClassifier.Facts? // the re-read before: a downgrade needs two empty ones
            for attempt in 1...upgradeAttempts {
                try? await Task.sleep(nanoseconds: upgradeInterval)
                let (now, _) = SelectionCapture.facts(pid: pid) // each AX call: 0.1 s messaging timeout
                defer { previous = now }
                switch SelectionUpgrade.outcome(for: captured, with: now, previous: previous) {
                case .keep:
                    if case .selected(let copied, _) = captured, now.isEditableText,
                       let selected = now.selectedText, !selected.isEmpty,
                       !SelectionUpgrade.sameText(selected, copied) { mismatch = true }
                    continue
                case .upgradeToEditable:
                    appLog("selection reclassified editable after \(attempt) re-read(s)")
                case .downgradeToNone:
                    appLog("selection reclassified as none after \(attempt) re-read(s) (editable field, empty selection twice)")
                }
                let better = SelectionUpgrade.reclassified(captured, with: now, previous: previous)
                await MainActor.run { onUpgrade(better) }
                return
            }
            appLog("selection stays read-only (no editable field after the tree switch\(mismatch ? "; field selection differs from the copy" : ""))")
        }
    }

    /// Off the main actor: AX is a synchronous IPC round trip to the target app.
    private static func readFacts(_ pid: pid_t) async -> (SelectionClassifier.Facts, FocusLookup) {
        await Task.detached(priority: .userInitiated) { facts(pid: pid) }.value
    }

    nonisolated static func facts(pid: pid_t) -> (SelectionClassifier.Facts, FocusLookup) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusResult == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            let lookup: FocusLookup = switch focusResult {
            case .noValue: .noFocusedElement
            case .cannotComplete: .timedOut
            default: .failed
            }
            // Safari with a selection on the page but nothing focused: the page's web area still
            // reports it (Electron with its tree off has no web area: nothing found, ⌘C as before).
            var facts = SelectionClassifier.Facts(role: nil)
            if lookup == .noFocusedElement { facts.markerText = webAreaSelection(app) }
            return (facts, lookup)
        }
        let focused = focusedRef as! AXUIElement // CF type, checked above
        AXUIElementSetMessagingTimeout(focused, axTimeout)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        var facts = SelectionClassifier.Facts(role: roleRef as? String)

        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) {
        case .success:
            facts.selectedText = value as? String
            // The only place this is set: a real string answer, never kAXErrorNoValue or an error.
            facts.selectedTextReadSucceeded = facts.selectedText != nil
        case .noValue: facts.selectedText = "" // supported, nothing selected (e.g. an empty field)
        default: break
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success {
            facts.selectedTextSettable = settable.boolValue
        }
        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueSettable) == .success {
            facts.valueSettable = valueSettable.boolValue
        }
        if facts.selectedText?.isEmpty ?? true, !SelectionClassifier.textRoles.contains(facts.role ?? "") {
            facts.markerText = markerSelection(focused) // a tweet in Safari: AXGroup, text markers only
        }
        guard facts.selectedText == nil else { return (facts, .found) }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return (facts, .found) }
        let rangeValue = rangeRef as! AXValue // CF type, checked above
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return (facts, .found) }
        facts.rangeLength = range.length
        guard range.length > 0 else { return (facts, .found) }
        var stringRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                                     rangeValue, &stringRef) == .success {
            facts.rangeText = stringRef as? String
        }
        return (facts, .found)
    }

    /// WebKit/Chromium: the page's selection through text markers (AXSelectedTextMarkerRange,
    /// AXStringForTextMarkerRange); nil when unsupported.
    nonisolated private static func markerSelection(_ element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString,
                                                         range, &text) == .success else { return nil }
        return text as? String
    }

    /// The selection of the first AXWebArea in the focused window (breadth-first, bounded: a few
    /// levels and elements, each call under the messaging timeout).
    nonisolated private static func webAreaSelection(_ app: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        var queue: [(AXUIElement, Int)] = [(windowRef as! AXUIElement, 0)] // CF type, checked above
        var visited = 0
        while !queue.isEmpty, visited < webAreaSearchLimit {
            let (element, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, axTimeout)
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" { return markerSelection(element) }
            guard depth < webAreaSearchDepth else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        return nil
    }
    static let webAreaSearchDepth = 8
    static let webAreaSearchLimit = 80

    /// ⌘C, wait for the pasteboard to change, read the text, put the previous contents back
    /// (`CommandCopy`: a late copy is restored too, and makes the selection unknown).
    @MainActor
    static func copyViaCommandC(holding trigger: TriggerKey, isHeld: @escaping @MainActor () -> Bool,
                                userInputSince: (TimeInterval) -> Bool) async -> CommandCopy.Result {
        await CommandCopy.run(on: SystemPasteboard(), clock: .system, userInputSince: userInputSince) {
            // The user is holding the trigger (push-to-talk): the app must get ⌘C, not ⌥⌘C
            // (Chrome/Safari: the inspector) or ⇧⌘C, and the user's next key must keep its modifier.
            SyntheticEvent.postCommandWhileHolding(trigger, key: SyntheticEvent.cKey, isHeld: isHeld)
        }
    }
}

/// NSPasteboard.general for `CommandCopy`.
@MainActor
private final class SystemPasteboard: CopyPasteboard {
    private let pb = NSPasteboard.general
    var changeCount: Int { pb.changeCount }
    func snapshot() -> [NSPasteboardItem] { PasteboardSnapshot.take(pb) }
    func copiedText() -> String? {
        // Copied files (Finder) carry their names as text: that is not a text selection.
        if pb.types?.contains(.fileURL) == true { return nil }
        return pb.string(forType: .string)
    }
    func restore(_ snapshot: [NSPasteboardItem], ifChangeCount changeCount: Int) {
        PasteboardSnapshot.restore(snapshot, to: pb, ifChangeCount: changeCount)
    }
}

extension CopyClock {
    /// System uptime: the time base of NSEvent timestamps (`HotkeyMonitor.lastOtherInputAt`).
    static let system = CopyClock(now: { ProcessInfo.processInfo.systemUptime },
                                  sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
}

// MARK: - Manual paste checks ("Colar", "Desfazer")

extension SelectionCapture {
    /// Longest a "Colar" or "Desfazer" check waits for the target app's accessibility answers.
    static let manualCheckTimeout: Double = 0.6

    /// The focused element of `pid`: can it take pasted text? (role, settable selected text or
    /// value, inside editable web content). nil = no focused element or no answer in time.
    static func pasteTargetFacts(pid: pid_t) async -> SelectionClassifier.Facts? {
        let facts = try? await withTimeout(seconds: manualCheckTimeout) {
            await Task.detached(priority: .userInitiated) { pasteTargetFactsNow(pid: pid) }.value
        }
        return facts ?? nil
    }

    /// The text right before the insertion point of `pid`'s focused element, `utf16Length` long,
    /// and the current selection length; nils when unreadable in time.
    static func textBeforeCursor(pid: pid_t, utf16Length: Int) async -> (text: String?, selectionLength: Int?) {
        let read = try? await withTimeout(seconds: manualCheckTimeout) {
            await Task.detached(priority: .userInitiated) { textBeforeCursorNow(pid: pid, utf16Length: utf16Length) }.value
        }
        return read ?? (nil, nil)
    }

    nonisolated private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedRef as! AXUIElement // CF type, checked above
        AXUIElementSetMessagingTimeout(focused, axTimeout)
        return focused
    }

    nonisolated private static func pasteTargetFactsNow(pid: pid_t) -> SelectionClassifier.Facts? {
        guard let focused = focusedElement(pid) else { return nil }
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        var facts = SelectionClassifier.Facts(role: roleRef as? String)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success {
            facts.selectedTextSettable = settable.boolValue
        }
        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueSettable) == .success {
            facts.valueSettable = valueSettable.boolValue
        }
        if !facts.isEditableText {
            var ancestor: CFTypeRef?
            facts.insideEditableWebContent =
                AXUIElementCopyAttributeValue(focused, "AXEditableAncestor" as CFString, &ancestor) == .success
                && ancestor != nil
        }
        return facts
    }

    nonisolated private static func textBeforeCursorNow(pid: pid_t, utf16Length: Int) -> (text: String?, selectionLength: Int?) {
        guard utf16Length > 0, let focused = focusedElement(pid) else { return (nil, nil) }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return (nil, nil) }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection) else { return (nil, nil) } // CF type, checked
        // The cursor is closer to the start than the pasted text is long: it is not right after it.
        guard selection.location >= utf16Length else { return ("", selection.length) }
        var before = CFRange(location: selection.location - utf16Length, length: utf16Length)
        if let value = AXValueCreate(.cfRange, &before) {
            var stringRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &stringRef) == .success,
               let text = stringRef as? String {
                return (text, selection.length)
            }
        }
        // No string-for-range: cut it from the whole value.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let whole = valueRef as? String else { return (nil, nil) }
        let ns = whole as NSString
        guard selection.location <= ns.length else { return (nil, nil) }
        return (ns.substring(with: NSRange(location: before.location, length: before.length)), selection.length)
    }
}
