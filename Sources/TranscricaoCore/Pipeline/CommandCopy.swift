// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The pasteboard as the ⌘C fallback needs it (NSPasteboard in the app, a fake in tests).
@MainActor
public protocol CopyPasteboard: AnyObject {
    associatedtype Snapshot
    var changeCount: Int { get }
    func snapshot() -> Snapshot
    /// The text now on the pasteboard; nil when there is none (copied files count as none: their
    /// names are not a text selection).
    func copiedText() -> String?
    /// Puts `snapshot` back unless the pasteboard changed since `changeCount`.
    func restore(_ snapshot: Snapshot, ifChangeCount changeCount: Int)
}

/// Time source for `CommandCopy.run` (system uptime in the app, a fake in tests).
public struct CopyClock: Sendable {
    public var now: @Sendable () -> TimeInterval
    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(now: @escaping @Sendable () -> TimeInterval, sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.now = now
        self.sleep = sleep
    }
}

/// The ⌘C fallback of the selection capture: post ⌘C, wait for the pasteboard to change, read the
/// text, put the user's clipboard back. It runs while the user speaks (off the release → paste
/// path), so it can afford to wait. Three outcomes:
/// - the copy lands within `answerWindow` → that is the selection;
/// - nothing changes during the whole `watchWindow` → nothing was selected (plain dictation);
/// - the copy lands later than `answerWindow` (the app was slow, e.g. models reloading) → the
///   clipboard is still restored and the selection is unknown: nothing is pasted over it.
/// The pipeline awaits the capture, so a late copy can never turn into "no selection".
public enum CommandCopy {
    /// A copy landing within this time after ⌘C is the selection (measured: 54–135 ms idle).
    public static let answerWindow: TimeInterval = 0.5
    /// How long a change is watched for after ⌘C. Ends well within `SelectionEdit.captureWait`
    /// after transcription; only a capture where nothing was copied waits this long.
    public static let watchWindow: TimeInterval = 1.0
    /// After the change, how long the app may take to put the text there (it may clear first).
    public static let textSettle: TimeInterval = 0.15
    static let pollInterval: TimeInterval = 0.01
    static let latePollInterval: TimeInterval = 0.03

    public enum Result: Equatable, Sendable {
        /// Landed within `answerWindow`; nil = something that is not text (files, an image).
        case copied(String?)
        /// No change during `watchWindow`.
        case nothingCopied
        /// Landed after `answerWindow`.
        case lateCopy
    }

    /// The capture a ⌘C result stands for (`kind`: editable or read-only, from the focused role).
    public static func selection(_ result: Result, kind: SelectionKind) -> CapturedSelection {
        switch result {
        case .copied(let text?): return .selected(text, kind)
        case .copied(nil), .nothingCopied: return .none
        case .lateCopy: return .unknown
        }
    }

    /// `movedAfter`: seconds between ⌘C and the first pasteboard change seen; nil = none.
    public static func result(movedAfter: TimeInterval?, text: String?) -> Result {
        guard let movedAfter else { return .nothingCopied }
        return movedAfter <= answerWindow ? .copied(text) : .lateCopy
    }

    /// A copy within the window is ours (the user is holding the dictation key; any other key would have cancelled
    /// the recording before the ⌘C). A late one may follow a key or click of the user's own (e.g. a
    /// real copy after cancelling): then theirs wins and nothing is put back.
    public static func shouldRestore(_ result: Result, userInputSinceCopy: Bool) -> Bool {
        switch result {
        case .copied: return true
        case .lateCopy: return !userInputSinceCopy
        case .nothingCopied: return false // nothing to undo
        }
    }

    /// Posts ⌘C through `post` and waits as described above. `userInputSince(t)`: did the user
    /// press a key or click after `clock.now()` == t. Run it in a task of its own: once ⌘C is
    /// posted, cancelling the caller must not skip the restore.
    @MainActor
    public static func run<P: CopyPasteboard>(on pasteboard: P, clock: CopyClock,
                                              userInputSince: (TimeInterval) -> Bool,
                                              post: () -> Void) async -> Result {
        let saved = pasteboard.snapshot()
        let before = pasteboard.changeCount
        let postedAt = clock.now()
        post()
        var movedAfter: TimeInterval?
        while true {
            let elapsed = clock.now() - postedAt
            if pasteboard.changeCount != before { movedAfter = elapsed; break }
            if elapsed >= watchWindow { break }
            await clock.sleep(elapsed < answerWindow ? pollInterval : latePollInterval)
        }
        guard movedAfter != nil else { return .nothingCopied }
        // The copying app may clear the pasteboard a moment before it writes the text: restoring
        // before that write would be undone by it.
        let settleEnd = clock.now() + textSettle
        var text = pasteboard.copiedText()
        while text == nil && clock.now() < settleEnd {
            await clock.sleep(pollInterval)
            text = pasteboard.copiedText()
        }
        let outcome = result(movedAfter: movedAfter, text: text)
        if shouldRestore(outcome, userInputSinceCopy: userInputSince(postedAt)) {
            pasteboard.restore(saved, ifChangeCount: pasteboard.changeCount)
        }
        return outcome
    }
}
