// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Text model used to organize the dictation. The catalog is decided in
/// docs/superpowers/specs/2026-10-13-model-choice-design.md ("Decisão após a avaliação"):
/// Qwen3 4B or no AI at all. `rawValue` is the value persisted in UserDefaults (for Qwen it is
/// the repo id, as stored by earlier versions).
public enum TextModelChoice: String, CaseIterable, Sendable {
    case qwen3_4b = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    /// "Sem IA": transcription only. The text model is never downloaded nor loaded.
    case transcriptionOnly = "sem-ia"

    public static let recommended: TextModelChoice = .qwen3_4b

    /// Hugging Face repo of the MLX model; nil when there is no text model.
    public var repoID: String? {
        switch self {
        case .qwen3_4b: return rawValue
        case .transcriptionOnly: return nil
        }
    }

    public var usesAI: Bool { repoID != nil }

    public var title: String {
        switch self {
        case .qwen3_4b: return String(localized: "Qwen3 4B (recommended)", bundle: .main)
        case .transcriptionOnly: return String(localized: "No AI (transcription only)", bundle: .main)
        }
    }

    /// Short name used in progress lines ("Downloading Qwen3 4B…").
    public var shortName: String {
        switch self {
        case .qwen3_4b: return "Qwen3 4B"
        case .transcriptionOnly: return String(localized: "No AI", bundle: .main)
        }
    }

    /// Approximate memory while loaded (docs/model-eval.md: Qwen3 4B RSS ~2,4 GB in `tcli eval`).
    public var memoryText: String? {
        switch self {
        case .qwen3_4b: return String(localized: "~2.4 GB of memory (approximate)", bundle: .main)
        case .transcriptionOnly: return nil
        }
    }

    /// Download size (measured on disk: blobs of the hub snapshot). 0 for no model.
    public var downloadBytes: Int64 {
        switch self {
        case .qwen3_4b: return 2_277_297_884
        case .transcriptionOnly: return 0
        }
    }

    /// Persisted value → choice. Anything unknown (e.g. the removed Gemma 4 E4B,
    /// "mlx-community/gemma-4-e4b-it-4bit") or missing migrates to the recommended model.
    public static func migrated(from stored: String?) -> TextModelChoice {
        stored.flatMap(TextModelChoice.init(rawValue:)) ?? .recommended
    }
}

/// Fixed parts of the model catalog and the pure decisions around it.
public enum ModelCatalog {
    /// WhisperKit CoreML variant (the only transcription model offered; no picker).
    public static let whisperVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// Tokenizer folder WhisperKit uses for this variant (`<downloadBase>/models/openai/<folder>`).
    public static let whisperTokenizerFolder = "whisper-large-v3"
    public static let whisperTitle = "Whisper Turbo"
    /// Approximate memory of Whisper Turbo while loaded (docs/model-eval.md: RSS ~0,3 GB in
    /// `tcli wer`, plus CoreML memory outside the process, not measured).
    public static let whisperMemoryText = String(localized: "~0.3–0.6 GB of memory (approximate)", bundle: .main)
    /// Model folder (645,668,913 B) + tokenizer (2,765,033 B), measured on disk; both are
    /// downloaded before the first load.
    public static let whisperBytes: Int64 = 645_668_913 + 2_765_033

    /// Below this, the first-run screen preselects "Liberar memória após 5 min".
    public static let lowMemoryThreshold: UInt64 = 16 * 1024 * 1024 * 1024

    public static func isLowMemory(physicalMemory: UInt64) -> Bool {
        physicalMemory < lowMemoryThreshold
    }

    /// Idle-unload preset for the first-run screen (editable there).
    public static func recommendedIdleUnload(physicalMemory: UInt64) -> IdleUnloadPolicy {
        isLowMemory(physicalMemory: physicalMemory) ? .five : .never
    }
}

/// One model to download.
public enum ModelDownloadItem: Equatable, Sendable {
    case whisper
    case text(TextModelChoice)

    public var bytes: Int64 {
        switch self {
        case .whisper: return ModelCatalog.whisperBytes
        case .text(let choice): return choice.downloadBytes
        }
    }

    public var title: String {
        switch self {
        case .whisper: return ModelCatalog.whisperTitle
        case .text(let choice): return choice.shortName
        }
    }
}

/// What has to be downloaded for a choice, given what is already complete on disk.
public struct ModelDownloadPlan: Equatable, Sendable {
    public let items: [ModelDownloadItem]

    public init(text: TextModelChoice, whisperOnDisk: Bool, textOnDisk: Bool) {
        var items: [ModelDownloadItem] = []
        if !whisperOnDisk { items.append(.whisper) }
        if text.usesAI, !textOnDisk { items.append(.text(text)) }
        self.items = items
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { items.isEmpty }

    /// Minimum free space kept after the download (the models also need room to load/compile).
    public static let headroomBytes: Int64 = 500 * 1024 * 1024

    public func fits(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return true } // unknown: let the download try
        return isEmpty || freeBytes >= totalBytes + Self.headroomBytes
    }
}

/// Progress of a sequence of downloads, in bytes. `fraction` of the current item comes from the
/// downloader; finished items count in full.
public struct DownloadProgress: Equatable, Sendable {
    public let items: [ModelDownloadItem]
    public private(set) var currentIndex = 0
    public private(set) var currentFraction = 0.0

    public init(items: [ModelDownloadItem]) { self.items = items }

    public var current: ModelDownloadItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public var completedBytes: Int64 {
        let done = items.prefix(currentIndex).reduce(0) { $0 + $1.bytes }
        let partial = current.map { Int64(Double($0.bytes) * currentFraction) } ?? 0
        return min(totalBytes, done + partial)
    }

    public var fraction: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }

    /// Progress never goes backwards within an item (resumed downloads report from the start).
    public mutating func update(fraction: Double) {
        currentFraction = max(currentFraction, min(1, max(0, fraction)))
    }

    public mutating func finishCurrent() {
        currentIndex += 1
        currentFraction = 0
    }

    /// "312 MB of 2.7 GB"
    public var text: String {
        String(localized: "\(ByteText.approx(completedBytes)) of \(ByteText.approx(totalBytes))", bundle: .main)
    }
}

/// Sizes as shown in the UI: binary units (like `du -h`, so the spec's "~620 MB" / "~2,1 GB"
/// come out), MB rounded to tens from 100 MB up (618 MiB → "620 MB"). The decimal separator and
/// the unit names follow the UI language, like the localized strings next to them ("~2.4 GB of
/// memory" in English, "~2,4 Go de mémoire" in French), whatever the region.
public enum ByteText {
    /// The locale of the language the app's interface runs in (its `.lproj`), not the region's.
    public static var uiLocale: Locale { locale(forLocalizations: Bundle.main.preferredLocalizations) }

    static func locale(forLocalizations localizations: [String]) -> Locale {
        Locale(identifier: localizations.first ?? "en")
    }

    public static func approx(_ bytes: Int64, locale: Locale = ByteText.uiLocale) -> String {
        let mb = String(localized: "MB", bundle: .main), gb = String(localized: "GB", bundle: .main)
        let mib = Double(max(0, bytes)) / 1_048_576
        if mib < 100 { return "\(Int(mib.rounded())) \(mb)" }
        let tens = Int((mib / 10).rounded()) * 10
        if tens < 1000 { return "\(tens) \(mb)" }
        let gib = mib / 1024
        let tenths = Int((gib * 10).rounded())
        let separator = locale.decimalSeparator ?? "."
        return tenths % 10 == 0 ? "\(tenths / 10) \(gb)" : "\(tenths / 10)\(separator)\(tenths % 10) \(gb)"
    }
}

/// Whether the first-run model chooser is shown.
public enum FirstRunDecision: Equatable, Sendable {
    /// No confirmed configuration and the chosen models are missing.
    case showChooser
    /// An existing install (models already on disk): mark the configuration as confirmed, no chooser.
    case confirmSilently
    /// Already confirmed: start normally (missing models are downloaded with progress).
    case proceed

    public static func decide(confirmed: Bool, chosenModelsOnDisk: Bool) -> FirstRunDecision {
        if confirmed { return .proceed }
        return chosenModelsOnDisk ? .confirmSilently : .showChooser
    }
}
