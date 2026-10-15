// SPDX-License-Identifier: GPL-3.0-or-later
/// Whether the models are resident in memory, shown in the menu and the main window.
public enum ModelMemoryState: Equatable, Sendable {
    case loaded
    case loading
    case unloaded

    public init(_ event: ResidencyEvent) {
        switch event {
        case .loading: self = .loading
        case .loaded: self = .loaded
        case .unloaded, .failed: self = .unloaded
        }
    }

    public var title: String { title(voiceOnly: false) }

    /// `voiceOnly`: "Sem IA" — only the voice model (Whisper) is ever loaded.
    public func title(voiceOnly: Bool) -> String {
        switch (self, voiceOnly) {
        case (.loaded, false): return String(localized: "Models loaded in memory", bundle: .main)
        case (.loading, false): return String(localized: "Loading models…", bundle: .main)
        case (.unloaded, false): return String(localized: "Models inactive — they load when you dictate (~3 s)", bundle: .main)
        case (.loaded, true): return String(localized: "Voice model loaded in memory", bundle: .main)
        case (.loading, true): return String(localized: "Loading the voice model…", bundle: .main)
        case (.unloaded, true): return String(localized: "Voice model inactive — it loads when you dictate (~3 s)", bundle: .main)
        }
    }
}
