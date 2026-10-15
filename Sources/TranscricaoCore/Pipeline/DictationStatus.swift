// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the app is doing, as shown by the menu bar icon, the menu and the main window.
public enum DictationStatus: Equatable, Sendable {
    case preparing(String)
    case ready
    case recording(continuous: Bool)
    case processing
    case error(String)
}

/// Pure status transitions for the dictation flow (the app wires them to hotkey/pipeline events).
///
/// Invariants:
///  - only an explicit start/stop/cancel moves into or out of `.recording`;
///  - when nothing is recording, `.processing` means clips are in flight and `.ready` means idle;
///  - `.preparing` belongs to the explicit model preparation, `.error` waits for "Tentar de novo".
public enum DictationStatusLogic {
    /// Shown with "Tentar de novo" when the models could not be loaded.
    public static let prepareFailedMessage = String(localized: "couldn't prepare the models", bundle: .main)

    /// Models must be prepared (not preparing/switching/failed); a clip may still be processing.
    public static func canStartCapture(_ status: DictationStatus) -> Bool {
        switch status {
        case .ready, .processing: return true
        case .preparing, .recording, .error: return false
        }
    }

    /// Status when nothing is recording.
    public static func settled(inFlight: Int) -> DictationStatus {
        inFlight > 0 ? .processing : .ready
    }

    /// The double-tap latch only upgrades a recording that really started.
    public static func afterContinuousChange(_ status: DictationStatus, continuous: Bool) -> DictationStatus {
        guard continuous, case .recording = status else { return status }
        return .recording(continuous: true)
    }

    /// The microphone failed to start (transient): no lasting change.
    public static func afterMicFailure(_ status: DictationStatus) -> DictationStatus { status }

    public static func afterCancel(_ status: DictationStatus, inFlight: Int) -> DictationStatus {
        guard case .recording = status else { return status }
        return settled(inFlight: inFlight)
    }

    /// A clip left the pipeline. `inFlight` is the count after it left; `modelsLost` is true when it
    /// failed because the models are not loaded (e.g. a reload after idle unload failed).
    public static func afterClipFinished(_ status: DictationStatus, inFlight: Int, modelsLost: Bool) -> DictationStatus {
        switch status {
        case .recording, .preparing, .error:
            return status
        case .processing, .ready:
            return modelsLost ? .error(prepareFailedMessage) : settled(inFlight: inFlight)
        }
    }

    /// End of an explicit model preparation (launch, retry, model switch).
    public static func afterPreparation(succeeded: Bool, inFlight: Int) -> DictationStatus {
        succeeded ? settled(inFlight: inFlight) : .error(prepareFailedMessage)
    }

    /// Residency events never interrupt a recording/processing or an explicit preparation; only a
    /// failed background reload while idle surfaces as an error (so "Tentar de novo" appears).
    public static func afterResidencyEvent(_ status: DictationStatus, _ event: ResidencyEvent) -> DictationStatus {
        if event == .failed, status == .ready { return .error(prepareFailedMessage) }
        return status
    }

    /// The idle icon shows "loading" while evicted models reload (dictation stays allowed).
    public static func showsReloading(_ status: DictationStatus, modelsLoading: Bool) -> Bool {
        status == .ready && modelsLoading
    }

    /// Start sound/HUD are delayed so the dictation key used as a modifier (⌥+E, ⌥+arrow) gives no feedback:
    /// announce only if the same recording is still running.
    public static func shouldAnnounceStart(recording id: Int, current: Int, status: DictationStatus) -> Bool {
        guard id == current, case .recording = status else { return false }
        return true
    }
}
