// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What one take does (a hold of a key, from the press to the end of its processing).
public enum TakeKind: Equatable, Sendable {
    case dictation
    case question
    /// A file being transcribed, organized or summarized (spec §5): not from a key.
    case file
}

/// One take at a time across the two keys (spec §4, plan Review Focus 5). Dictations may overlap
/// each other as before (a new one records while the last is still processing; the pipeline runs
/// them in order). A question needs everything else finished, and nothing else starts while a
/// question records, is transcribed or streams its answer: the other key is refused.
public enum TakeArbiter {
    /// The kind of take `key` starts: the dictation key dictates, the question key asks.
    public static func kind(of key: TriggerKey, dictation: TriggerKey, question: TriggerKey?) -> TakeKind? {
        if key == dictation { return .dictation }
        if let question, key == question { return .question }
        return nil
    }

    /// A file job (transcribing, organizing or summarizing a file) holds Whisper or the text model
    /// for minutes: while one runs, both keys are refused (with a message, never a freeze), and a
    /// file job starts only once nothing else runs, models ready (it waits for that).
    public static func canStart(_ kind: TakeKind, status: DictationStatus,
                                dictationsInFlight: Int, questionsInFlight: Int, filesInFlight: Int = 0) -> Bool {
        guard DictationStatusLogic.canStartCapture(status), filesInFlight == 0 else { return false }
        switch kind {
        case .dictation: return questionsInFlight == 0
        case .question: return dictationsInFlight == 0 && questionsInFlight == 0
        case .file: return status == .ready && dictationsInFlight == 0 && questionsInFlight == 0
        }
    }

    /// Esc and other keys reach every watched key's machine: a stop or cancel only applies to the
    /// take its own key started (nil = not from a key, e.g. the 5-minute limit: the current take).
    public static func applies(actionFrom key: TriggerKey?, toTakeOf takeKey: TriggerKey) -> Bool {
        key == nil || key == takeKey
    }
}
