// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TranscricaoCore

@MainActor
final class AppState: ObservableObject {
    typealias Status = DictationStatus

    @Published var status: Status = .preparing(String(localized: "Preparing models…"))
    /// True while the models load in the background (e.g. reload after idle unload).
    @Published var modelsLoading = false
    /// Start of the launch load (`prepareModels`), nil otherwise: drives `ModelLoadNotice`.
    @Published var loadStartedAt: Date?
    /// The launch load follows a Whisper download, so it is a first-time compile for sure.
    @Published var loadIsKnownFirst = false
    /// Whether the models are resident in memory (menu and main window indicator).
    @Published var memory: ModelMemoryState = .unloaded
    /// First run: the model choice has not been confirmed yet (chooser window pending).
    @Published var setupPending = false
    /// "Delete unused models" is deleting files.
    @Published var deletingModels = false
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var history: [DictationResult] = []
    /// The question key was turned off because it became the dictation key (the window says so
    /// under the question-key picker until the user picks a question key again).
    @Published var questionKeyCleared = false
}

extension AppState {
    /// Memory line: with "Sem IA" only the voice model exists, so it is named alone.
    var memoryTitle: String { memory.title(voiceOnly: !Settings.shared.textModel.usesAI) }

    /// Human-readable status line, shared by the menu and the main window. `now`: the main window
    /// redraws it every second while the models load, so the clock of `ModelLoadNotice` runs.
    func statusText(now: Date = Date()) -> String {
        if DictationStatusLogic.showsReloading(status, modelsLoading: modelsLoading) {
            return String(localized: "Reloading models… (you can dictate)")
        }
        if case .preparing = status, let start = loadStartedAt,
           let notice = ModelLoadNotice.message(elapsed: now.timeIntervalSince(start), knownFirstLoad: loadIsKnownFirst) {
            return notice
        }
        return status.text(key: Settings.shared.dictationKey)
    }

    /// The models are loading: the main window shows a moving bar (CoreML reports no progress to
    /// measure). A download has its own bar with a percentage instead. Not while the first-run
    /// model choice is pending: nothing loads until the person chooses.
    var showsLoadingBar: Bool {
        if setupPending { return false }
        if case .preparing = status { return true }
        return modelsLoading
    }
}

extension DictationStatus {
    /// `key`: the dictation key, named in the hints.
    func text(key: TriggerKey) -> String {
        let name = key.name
        switch self {
        case .preparing(let msg): return msg
        case .ready: return String(localized: "Ready — hold \(name) to dictate")
        case .recording(let continuous):
            return continuous ? String(localized: "Recording (continuous) — tap \(name) to finish") : String(localized: "Recording…")
        case .processing: return String(localized: "Processing…")
        case .error(let msg): return String(localized: "Error: \(msg)")
        }
    }
}

extension ModelMemoryState {
    /// Small colored dot: green = loaded, orange = loading, gray = inactive.
    var dot: NSImage {
        let color: NSColor = switch self {
        case .loaded: .systemGreen
        case .loading: .systemOrange
        case .unloaded: .systemGray
        }
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let symbol = self == .unloaded ? "circle" : "circle.fill"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config) ?? NSImage()
    }
}
