// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class LocalModelFilesTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("LocalModelFilesTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ path: String, _ contents: String = "x", in base: URL) throws {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Hugging Face hub cache (MLX)

    private let repo = "mlx-community/Some-Model-4bit"
    private let sha = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
    private var repoDir: URL { root.appendingPathComponent("models--mlx-community--Some-Model-4bit") }
    private var snapshot: URL { repoDir.appendingPathComponent("snapshots/\(sha)") }

    /// Lays out a snapshot the way swift-huggingface does: blobs + symlinks + refs/main.
    private func makeSnapshot(index: [String]? = nil, weights: [String] = ["model.safetensors"],
                              tokenizer: Bool = true, ref: Bool = true) throws {
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        if ref { try write("refs/main", sha, in: repoDir) }
        try write("config.json", "{}", in: snapshot)
        if tokenizer { try write("tokenizer.json", "{}", in: snapshot) }
        if let index {
            let map = Dictionary(uniqueKeysWithValues: index.enumerated().map { ("w\($0.offset)", $0.element) })
            let data = try JSONSerialization.data(withJSONObject: ["weight_map": map])
            try data.write(to: snapshot.appendingPathComponent("model.safetensors.index.json"))
        }
        for (i, w) in weights.enumerated() {
            try write("blobs/blob\(i)", "weights", in: repoDir)
            try fm.createSymbolicLink(atPath: snapshot.appendingPathComponent(w).path,
                                      withDestinationPath: "../../blobs/blob\(i)")
        }
    }

    func testCompleteSnapshotIsFound() throws {
        try makeSnapshot()
        XCTAssertEqual(LocalModelFiles.hubSnapshot(repoID: repo, cache: root)?.standardizedFileURL,
                       snapshot.standardizedFileURL)
    }

    func testShardedSnapshotNeedsEveryShard() throws {
        try makeSnapshot(index: ["model-00001.safetensors", "model-00002.safetensors"],
                         weights: ["model-00001.safetensors"])
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: repo, cache: root))
    }

    func testShardedSnapshotComplete() throws {
        try makeSnapshot(index: ["model-00001.safetensors", "model-00002.safetensors", "model-00001.safetensors"],
                         weights: ["model-00001.safetensors", "model-00002.safetensors"])
        XCTAssertNotNil(LocalModelFiles.hubSnapshot(repoID: repo, cache: root))
    }

    func testMissingWeightsIsIncomplete() throws {
        try makeSnapshot(weights: [])
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: repo, cache: root))
    }

    func testDanglingWeightSymlinkIsIncomplete() throws {
        try makeSnapshot()
        try fm.removeItem(at: repoDir.appendingPathComponent("blobs/blob0"))
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: repo, cache: root))
    }

    func testMissingTokenizerIsIncomplete() throws {
        try makeSnapshot(tokenizer: false)
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: repo, cache: root))
    }

    func testMissingRefIsNotFound() throws {
        try makeSnapshot(ref: false)
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: repo, cache: root))
    }

    func testUnknownRepoIsNotFound() {
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: "nobody/nothing", cache: root))
        XCTAssertNil(LocalModelFiles.hubSnapshot(repoID: "not-a-repo-id", cache: root))
    }

    // MARK: WhisperKit download folder

    private let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private var whisperFolder: URL {
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
    }

    private func makeWhisper(skip: String? = nil) throws {
        for dir in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] where dir != skip {
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] where "\(dir)/\(file)" != skip {
                try write("\(dir)/\(file)", in: whisperFolder)
            }
        }
        if skip != "config.json" { try write("config.json", "{}", in: whisperFolder) }
    }

    private var whisperMetadata: URL {
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(variant)")
    }

    func testWhisperFolderMissingWeightsIsIncomplete() throws {
        // A cancelled download: the .mlmodelc folder exists but its weights never arrived.
        try makeWhisper(skip: "AudioEncoder.mlmodelc/weights/weight.bin")
        XCTAssertNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }

    func testWhisperFolderWithUnfinishedDownloadIsIncomplete() throws {
        // generation_config.json is not one of the files checked by name: only its .incomplete tells.
        try makeWhisper()
        try write("config.json.metadata", in: whisperMetadata)
        XCTAssertNotNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
        try write("generation_config.json.abc123.incomplete", in: whisperMetadata)
        XCTAssertNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }

    func testLeftoverIncompleteOfAFileThatArrivedDoesNotCount() throws {
        try makeWhisper()
        try write("AudioEncoder.mlmodelc/weights/weight.bin.abc123.incomplete", in: whisperMetadata)
        XCTAssertNotNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }

    // MARK: Whisper tokenizer

    private var tokenizer: URL { root.appendingPathComponent("models/openai/whisper-large-v3") }

    func testCompleteTokenizerIsFound() throws {
        try write("tokenizer.json", "{}", in: tokenizer)
        try write("tokenizer_config.json", "{}", in: tokenizer)
        XCTAssertEqual(LocalModelFiles.whisperTokenizer(name: "whisper-large-v3", downloadBase: root)?.standardizedFileURL,
                       tokenizer.standardizedFileURL)
    }

    func testTokenizerMissingAFileOrUnfinishedIsIncomplete() throws {
        try write("tokenizer.json", "{}", in: tokenizer)
        XCTAssertNil(LocalModelFiles.whisperTokenizer(name: "whisper-large-v3", downloadBase: root))
        try write(".cache/huggingface/download/tokenizer_config.json.e1.incomplete", in: tokenizer)
        XCTAssertNil(LocalModelFiles.whisperTokenizer(name: "whisper-large-v3", downloadBase: root))
        try write("tokenizer_config.json", "{}", in: tokenizer)
        XCTAssertNotNil(LocalModelFiles.whisperTokenizer(name: "whisper-large-v3", downloadBase: root))
    }

    func testIncompleteFileOfAnotherVariantDoesNotMatter() throws {
        try makeWhisper()
        try write("openai_whisper-small_216MB/config.json.e1.incomplete",
                  in: whisperMetadata.deletingLastPathComponent())
        XCTAssertNotNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }

    func testCompleteWhisperFolderIsFound() throws {
        try makeWhisper()
        XCTAssertEqual(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root)?.standardizedFileURL,
                       whisperFolder.standardizedFileURL)
    }

    func testWhisperFolderMissingAModelIsIncomplete() throws {
        try makeWhisper(skip: "AudioEncoder.mlmodelc")
        XCTAssertNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }

    func testWhisperFolderMissingConfigIsIncomplete() throws {
        try makeWhisper(skip: "config.json")
        XCTAssertNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }

    func testAbsentWhisperFolder() {
        XCTAssertNil(LocalModelFiles.whisperFolder(variant: variant, downloadBase: root))
    }
}
