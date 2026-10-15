// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Edit-by-voice rules: what counts as a usable selection, how long the model may take, and the
/// messages when nothing is pasted (a failed edit never pastes the speech over the selection).
public enum SelectionEdit {
    /// Longer selections are ignored (plain dictation) to bound latency and context.
    public static let maxCharacters = 3000
    /// HUD message when the model could not edit; the selection is left untouched.
    public static let failureMessage = String(localized: "Couldn't edit the text", bundle: .main)
    /// HUD message when the selection capture never finished: nothing is pasted (there may be a
    /// selection the speech would overwrite); the speech is kept in the history.
    public static let unknownSelectionMessage = String(localized: "Couldn't read the selection — speech saved in History", bundle: .main)
    /// HUD message when the edit was ready but the selection changed meanwhile (other app, other
    /// text selected): nothing is pasted; the edited text is kept in the history.
    public static let selectionChangedMessage = String(localized: "Selection changed — result in History", bundle: .main)
    /// Panel message when the answer about a read-only selection failed.
    public static let answerFailureMessage = String(localized: "Couldn't answer right now. Try again.", bundle: .main)
    /// Longest the pipeline waits, after transcription, for the capture to finish (it runs during
    /// the recording and normally finished long before). The cap only bites when the capture
    /// itself is stuck (a target app hanging AX calls); past it the selection is `.unknown` and
    /// nothing is pasted (the speech goes to the history).
    public static let captureWait: Double = 1.5

    /// Captured text → selection to edit, or nil: nothing selected, only whitespace, or too long.
    /// The text itself is passed on unchanged.
    public static func usable(_ captured: String?) -> String? {
        guard let captured, captured.count <= maxCharacters,
              !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return captured
    }

    /// The model rewrites the whole selection, so its time grows with the selection length.
    /// Without a selection this is exactly `base`.
    public static func processingTimeout(base: Double, selectionCharacters: Int) -> Double {
        guard selectionCharacters > 0 else { return base }
        return min(maxProcessingTimeout, base + Double(selectionCharacters) * secondsPerSelectionCharacter)
    }
    /// Nobody waits longer than this for an edit or an answer (~4 ms/char measured: 3000 chars ≈ 12 s).
    public static let maxProcessingTimeout: Double = 20
    /// Generous margin over the measured decode speed (see docs/model-eval.md, edit-by-voice).
    static let secondsPerSelectionCharacter = 0.01

    /// The pasted text replaces the selection; keep the selection's leading/trailing whitespace
    /// (e.g. the newline of a triple-clicked paragraph) so surrounding text does not merge.
    public static func preservingEdges(of selection: String, _ output: String) -> String {
        let leading = selection.prefix { $0.isWhitespace || $0.isNewline }
        guard leading.count < selection.count else { return output }
        let trailing = String(selection.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leading) + output + trailing
    }
}
