// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import TranscricaoCore
import WhisperKit

public enum ModelDownloadError: LocalizedError {
    /// The downloader returned but the files on disk are not a complete model.
    case incomplete(String)

    public var errorDescription: String? {
        switch self {
        case .incomplete(let name): return String(localized: "the download of \(name) is incomplete")
        }
    }
}

/// Downloads models into `ModelLocations` without loading them, with progress. Cancelling the
/// calling Task stops the download; partial files stay as `.incomplete` (resumed by the next
/// attempt) and never count as a complete model (`LocalModelFiles`).
public enum ModelDownloader {
    /// Model folder and its tokenizer both complete: the first load then needs no network.
    /// (Only the app's Turbo; tcli variants keep using `LocalModelFiles.whisperFolder` alone.)
    public static var whisperOnDisk: Bool {
        LocalModelFiles.whisperFolder(variant: ModelCatalog.whisperVariant, downloadBase: ModelLocations.whisper) != nil
            && LocalModelFiles.whisperTokenizer(name: ModelCatalog.whisperTokenizerFolder,
                                                downloadBase: ModelLocations.whisper) != nil
    }

    /// True for "Sem IA" (nothing to download).
    public static func isOnDisk(text choice: TextModelChoice) -> Bool {
        guard let repoID = choice.repoID else { return true }
        return LocalModelFiles.hubSnapshot(repoID: repoID, cache: ModelLocations.hub) != nil
    }

    public static func isOnDisk(_ item: ModelDownloadItem) -> Bool {
        switch item {
        case .whisper: return whisperOnDisk
        case .text(let choice): return isOnDisk(text: choice)
        }
    }

    public static func plan(for choice: TextModelChoice) -> ModelDownloadPlan {
        ModelDownloadPlan(text: choice, whisperOnDisk: whisperOnDisk, textOnDisk: isOnDisk(text: choice))
    }

    /// Free space on the volume that holds the models (nil if unknown).
    public static var freeBytes: Int64? {
        let values = try? ModelLocations.appSupport
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// `progress` gets the fraction (0…1) of this item, from any thread.
    public static func download(_ item: ModelDownloadItem,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        switch item {
        case .whisper: try await downloadWhisper(progress: progress)
        case .text(let choice):
            guard let repoID = choice.repoID else { return }
            try await downloadText(repoID: repoID, progress: progress)
        }
    }

    /// WhisperKit's own progress counts files, not bytes (a 400 MB weight file weighs as much as a
    /// 1 KB JSON), so the bytes already on disk are sampled instead: WhisperKit writes each file
    /// incrementally to its `.incomplete` under `.cache`, then moves it into the variant folder.
    private static func downloadWhisper(progress: @escaping @Sendable (Double) -> Void) async throws {
        let variant = ModelCatalog.whisperVariant
        let repoDir = ModelLocations.whisper.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let watched = [repoDir.appendingPathComponent(variant),
                       repoDir.appendingPathComponent(".cache/huggingface/download/\(variant)"),
                       ModelLocations.whisper.appendingPathComponent("models/openai/\(ModelCatalog.whisperTokenizerFolder)")]
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let bytes = watched.reduce(Int64(0)) { $0 + UnusedModels.size(of: $1) }
                progress(min(0.99, Double(bytes) / Double(ModelCatalog.whisperBytes)))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { sampler.cancel() }
        engineLog("downloading whisper \(variant)")
        if LocalModelFiles.whisperFolder(variant: variant, downloadBase: ModelLocations.whisper) == nil {
            _ = try await WhisperKit.download(variant: variant, downloadBase: ModelLocations.whisper)
            try Task.checkCancellation()
        }
        // The tokenizer is not part of the CoreML repo: WhisperKit would otherwise fetch it from
        // huggingface.co on the first load. Same call and folder WhisperKit uses
        // (`<downloadBase>/models/openai/whisper-large-v3`; the Turbo is detected as large-v3).
        if LocalModelFiles.whisperTokenizer(name: ModelCatalog.whisperTokenizerFolder,
                                            downloadBase: ModelLocations.whisper) == nil {
            _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: ModelLocations.whisper)
            try Task.checkCancellation()
        }
        guard whisperOnDisk else { throw ModelDownloadError.incomplete(ModelCatalog.whisperTitle) }
        progress(1)
        engineLog("whisper downloaded")
    }

    /// Same files the MLX loader would fetch (`MLXLMCommon.resolve` uses mlx-swift-lm's own
    /// download patterns), without loading the model into memory. Progress is byte-weighted.
    private static func downloadText(repoID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        engineLog("downloading text model \(repoID)")
        let hub = HubClient(cache: HubCache(cacheDirectory: ModelLocations.hub))
        _ = try await MLXLMCommon.resolve(
            configuration: ModelConfiguration(id: repoID),
            from: #hubDownloader(hub),
            useLatest: false,
            progressHandler: { p in progress(p.fractionCompleted) })
        try Task.checkCancellation()
        guard LocalModelFiles.hubSnapshot(repoID: repoID, cache: ModelLocations.hub) != nil else {
            throw ModelDownloadError.incomplete(repoID)
        }
        progress(1)
        engineLog("text model downloaded")
    }
}
