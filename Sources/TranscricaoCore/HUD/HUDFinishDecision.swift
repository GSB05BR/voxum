// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the floating HUD should do when a clip finishes (AppEnvironment.onFinished).
/// onFinished can arrive while a NEWER recording is active or another clip is still processing,
/// so the decision depends on the current app status.
public enum HUDFinishDecision: Equatable {
    case ignore          // a newer recording is active: leave its pill alone
    case keepProcessing  // another clip is still in flight: keep the processing pill
    case flashError(String) // another clip is in flight: show the error briefly, then back to processing
    case hide
    case showError(String)

    public static func decide(isRecording: Bool, isProcessing: Bool, error: String?) -> HUDFinishDecision {
        if isRecording { return .ignore }
        if isProcessing { return error.map { .flashError($0) } ?? .keepProcessing }
        if let error { return .showError(error) }
        return .hide
    }
}

/// What the HUD shows around a short notice ("Wait for the file transcription to finish", "The
/// new language is used…") and when a clip finishes. The processing pill belongs to dictations and
/// questions only: file work shows its progress in its own window, so a file in flight never
/// brings the pill back (it would stay up for the rest of the file and after it).
public enum HUDNoticeDecision {
    /// After the notice, back to the processing pill? Only for a dictation or question still in
    /// flight whose answer panel isn't showing (the panel is that clip's feedback).
    public static func thenProcessing(clipsInFlight: Int, answerPanelVisible: Bool) -> Bool {
        clipsInFlight > 0 && !answerPanelVisible
    }

    /// `isProcessing` for `HUDFinishDecision.decide`: the status says processing *and* a clip
    /// (not only file work) is still in flight.
    public static func clipProcessing(statusIsProcessing: Bool, clipsInFlight: Int) -> Bool {
        statusIsProcessing && clipsInFlight > 0
    }
}
