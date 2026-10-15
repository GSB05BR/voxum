// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A model on disk that the current configuration does not use ("Apagar modelos não usados").
public struct UnusedModelFolder: Equatable, Sendable {
    /// Shown in the confirmation ("mlx-community/gemma-4-e4b-it-4bit", "Whisper openai_whisper-small_216MB").
    public let name: String
    /// Everything removed for this model (model folder + its download metadata).
    public let urls: [URL]
    public let bytes: Int64
}

/// Finds model folders under the app's model roots that are not the models in use. Only the
/// layouts the app itself writes are considered; anything else is left alone.
///
///  - hub cache: `<hub>/models--org--name` (MLX text models) plus its `<hub>/.locks/models--org--name`.
///  - WhisperKit: `<whisperBase>/models/argmaxinc/whisperkit-coreml/<variant>` plus its metadata
///    in `.cache/huggingface/download/<variant>`, and tokenizers in `<whisperBase>/models/openai/<name>`.
public enum UnusedModels {
    static let whisperRepo = "models/argmaxinc/whisperkit-coreml"
    static let tokenizerRepo = "models/openai"

    /// `keepRepoID` nil = no text model in use ("Sem IA"): every text model is unused.
    public static func find(hub: URL, whisperBase: URL,
                            keepRepoID: String?,
                            keepWhisperVariant: String = ModelCatalog.whisperVariant,
                            keepTokenizer: String = ModelCatalog.whisperTokenizerFolder) -> [UnusedModelFolder] {
        var result: [UnusedModelFolder] = []

        for dir in subdirectories(of: hub) {
            let name = dir.lastPathComponent
            guard let repoID = repoID(fromCacheFolder: name), repoID != keepRepoID else { continue }
            var urls = [dir]
            let locks = hub.appendingPathComponent(".locks/\(name)", isDirectory: true)
            if isDirectory(locks) { urls.append(locks) } // the hub's lock files for this repo only
            result.append(UnusedModelFolder(name: repoID, urls: urls, bytes: urls.reduce(0) { $0 + size(of: $1) }))
        }

        let whisperRoot = whisperBase.appendingPathComponent(whisperRepo, isDirectory: true)
        let metadataRoot = whisperRoot.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        for dir in subdirectories(of: whisperRoot) {
            let variant = dir.lastPathComponent
            guard variant != keepWhisperVariant else { continue }
            var urls = [dir]
            let metadata = metadataRoot.appendingPathComponent(variant, isDirectory: true)
            if isDirectory(metadata) { urls.append(metadata) }
            result.append(UnusedModelFolder(name: "Whisper \(variant)", urls: urls,
                                            bytes: urls.reduce(0) { $0 + size(of: $1) }))
        }

        let tokenizerRoot = whisperBase.appendingPathComponent(tokenizerRepo, isDirectory: true)
        for dir in subdirectories(of: tokenizerRoot) where dir.lastPathComponent != keepTokenizer {
            result.append(UnusedModelFolder(name: String(localized: "Tokenizer \(dir.lastPathComponent)", bundle: .main), urls: [dir],
                                            bytes: size(of: dir)))
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// "models--mlx-community--Qwen3-4B-Instruct-2507-4bit" → "mlx-community/Qwen3-4B-Instruct-2507-4bit".
    /// Hub cache folders use "--" between org and name; org names cannot contain "--".
    static func repoID(fromCacheFolder name: String) -> String? {
        let prefix = "models--"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let sep = rest.range(of: "--") else { return nil }
        let org = rest[..<sep.lowerBound], model = rest[sep.upperBound...]
        guard !org.isEmpty, !model.isEmpty else { return nil }
        return "\(org)/\(model)"
    }

    /// Total size of the regular files under `url` (symlinks are not followed, so a hub snapshot's
    /// links to its blobs are not counted twice).
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Visible (non-dot) subdirectories; symlinks are skipped.
    private static func subdirectories(of url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { url.appendingPathComponent($0, isDirectory: true) }
            .filter(isDirectory)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
}
