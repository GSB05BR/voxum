// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Finds already-downloaded model files so the engines can load them without touching the
/// network (the app must work offline after the first download). Only complete copies count:
/// anything partial returns nil and the engine falls back to its normal download path.
public enum LocalModelFiles {
    /// Complete snapshot of `repoID` (e.g. "mlx-community/Qwen3-4B-Instruct-2507-4bit") in a
    /// Hugging Face hub cache (`models--org--name/{refs,snapshots,blobs}`), at `revision`.
    /// Complete = config.json, tokenizer.json and every weight file (all shards listed in
    /// model.safetensors.index.json, or at least one *.safetensors) resolve to real files.
    public static func hubSnapshot(repoID: String, revision: String = "main", cache: URL) -> URL? {
        let parts = repoID.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let repoDir = cache.appendingPathComponent("models--\(parts[0])--\(parts[1])", isDirectory: true)
        guard let commit = try? String(contentsOf: repoDir.appendingPathComponent("refs/\(revision)"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !commit.isEmpty, !commit.contains("/")
        else { return nil }
        let snapshot = repoDir.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        guard exists(snapshot, "config.json"), exists(snapshot, "tokenizer.json") else { return nil }

        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = json["weight_map"] as? [String: String], !map.isEmpty
            else { return nil }
            return Set(map.values).allSatisfy { exists(snapshot, $0) } ? snapshot : nil
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)) ?? []
        let weights = files.filter { $0.hasSuffix(".safetensors") }
        return !weights.isEmpty && weights.allSatisfy { exists(snapshot, $0) } ? snapshot : nil
    }

    /// Complete WhisperKit model folder for `variant` under WhisperKit's `downloadBase`
    /// (`models/argmaxinc/whisperkit-coreml/<variant>`).
    /// Complete = config.json plus, for each of the three CoreML models, its `coremldata.bin`,
    /// `model.mil` and `weights/weight.bin`, and no unfinished download: WhisperKit writes each file
    /// to `.cache/huggingface/download/<variant>/<file>.<etag>.incomplete` and moves it into place
    /// when done, so a cancelled download leaves a `.incomplete` behind (and a `.mlmodelc` folder
    /// exists as soon as its first file lands, so its presence alone proves nothing).
    public static func whisperFolder(variant: String, downloadBase: URL,
                                     repo: String = "argmaxinc/whisperkit-coreml") -> URL? {
        let repoDir = downloadBase.appendingPathComponent("models/\(repo)", isDirectory: true)
        let folder = repoDir.appendingPathComponent(variant, isDirectory: true)
        let models = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let required = ["config.json"] + models.flatMap {
            ["\($0)/coremldata.bin", "\($0)/model.mil", "\($0)/weights/weight.bin"]
        }
        guard required.allSatisfy({ exists(folder, $0) }) else { return nil }
        let metadata = repoDir.appendingPathComponent(".cache/huggingface/download/\(variant)", isDirectory: true)
        return hasUnfinishedDownload(metadata: metadata, target: folder) ? nil : folder
    }

    /// Complete Whisper tokenizer as WhisperKit stores it (`<downloadBase>/models/openai/<name>`,
    /// e.g. "whisper-large-v3"): tokenizer.json and tokenizer_config.json, nothing unfinished.
    /// Without it the first load would have to reach huggingface.co.
    public static func whisperTokenizer(name: String, downloadBase: URL) -> URL? {
        let folder = downloadBase.appendingPathComponent("models/openai/\(name)", isDirectory: true)
        guard exists(folder, "tokenizer.json"), exists(folder, "tokenizer_config.json") else { return nil }
        let metadata = folder.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        return hasUnfinishedDownload(metadata: metadata, target: folder) ? nil : folder
    }

    /// True if some `<file>.<etag>.incomplete` below `metadata` belongs to a file still missing
    /// from `target` (a download in progress or cut short). A leftover `.incomplete` whose file
    /// did arrive (e.g. finished by a later attempt) does not count.
    static func hasUnfinishedDownload(metadata: URL, target: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: metadata.path) else { return false }
        for case let path as String in enumerator where path.hasSuffix(".incomplete") {
            // "<relative file>.<etag>.incomplete" → "<relative file>"
            let relative = ((path as NSString).deletingPathExtension as NSString).deletingPathExtension
            if !exists(target, relative) { return true }
        }
        return false
    }

    /// True if `name` inside `dir` resolves (following symlinks) to an existing item.
    private static func exists(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }
}
