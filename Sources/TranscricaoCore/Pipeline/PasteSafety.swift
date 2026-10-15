// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Fail-closed checks for the two pastes the user triggers by hand: "Colar" in the answer panel and
/// "Desfazer" (⌘Z) after an edit. Pure: the app reads the facts over Accessibility.
public enum PasteSafety {
    /// "Colar" pastes only into an element that takes typed text: an editable text element (a text
    /// role with settable selected text or value, as for edits) or one inside editable web content
    /// (a contenteditable box: AXEditableAncestor). nil facts (unreadable in time) → no paste.
    public static func acceptsPaste(_ facts: SelectionClassifier.Facts?) -> Bool {
        guard let facts else { return false }
        return facts.isEditableText || facts.insideEditableWebContent
    }

    /// "Desfazer" is offered and sent only if the user did nothing since the edit was pasted: any
    /// key press or click after it (except on the pill itself) means ⌘Z could undo their own work.
    public static func undoAllowedByInput(lastOtherInputAt: TimeInterval, pastedAt: TimeInterval) -> Bool {
        lastOtherInputAt <= pastedAt
    }

    public enum UndoCheck: Equatable, Sendable {
        /// The pasted text sits right before the insertion point and nothing is selected.
        case confirmed
        /// The text around the cursor is something else (typed, undone, moved…).
        case changed
        /// Accessibility could not tell in time.
        case unreadable
    }

    /// `textBeforeCursor` = the text immediately before the insertion point, as long (UTF-16) as
    /// the pasted text; `selectionLength` = the current selection's length. Either nil = unreadable.
    public static func undoCheck(pasted: String, textBeforeCursor: String?, selectionLength: Int?) -> UndoCheck {
        guard let textBeforeCursor, let selectionLength else { return .unreadable }
        guard selectionLength == 0, !pasted.isEmpty else { return .changed }
        return normalized(textBeforeCursor) == normalized(pasted) ? .confirmed : .changed
    }

    /// Line endings and Unicode composition may be normalized by the target app.
    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }
}
