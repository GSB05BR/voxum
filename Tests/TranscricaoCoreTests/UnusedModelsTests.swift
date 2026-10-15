// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class UnusedModelsTests: XCTestCase {
    var root: URL!
    var hub: URL { root.appendingPathComponent("hub") }
    var whisper: URL { root.appendingPathComponent("whisperkit") }
    let fm = FileManager.default
    let qwen = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    let turbo = ModelCatalog.whisperVariant

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("UnusedModelsTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ path: String, bytes: Int = 10, in base: URL) throws {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    /// Mirrors this Mac: Qwen 4B (in use), Gemma, two evaluated light Qwens, four Whisper variants.
    private func makeLayout() throws {
        for repo in ["Qwen3-4B-Instruct-2507-4bit", "gemma-4-e4b-it-4bit", "Qwen3-1.7B-4bit", "Qwen3.5-2B-MLX-4bit"] {
            try write("models--mlx-community--\(repo)/blobs/abc", bytes: 1000, in: hub)
            try write("models--mlx-community--\(repo)/refs/main", in: hub)
        }
        try write(".locks/models--mlx-community--gemma-4-e4b-it-4bit/x.lock", in: hub)
        let coreml = "models/argmaxinc/whisperkit-coreml"
        for v in [turbo, "openai_whisper-small_216MB", "openai_whisper-base"] {
            try write("\(coreml)/\(v)/AudioEncoder.mlmodelc/weights/weight.bin", bytes: 500, in: whisper)
            try write("\(coreml)/.cache/huggingface/download/\(v)/config.json.metadata", in: whisper)
        }
        for t in ["whisper-large-v3", "whisper-small", "whisper-base"] {
            try write("models/openai/\(t)/tokenizer.json", bytes: 20, in: whisper)
        }
    }

    private func names(_ folders: [UnusedModelFolder]) -> Set<String> { Set(folders.map(\.name)) }

    func testListsEverythingButTheModelsInUse() throws {
        try makeLayout()
        let unused = UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: qwen)
        XCTAssertEqual(names(unused), [
            "mlx-community/gemma-4-e4b-it-4bit", "mlx-community/Qwen3-1.7B-4bit", "mlx-community/Qwen3.5-2B-MLX-4bit",
            "Whisper openai_whisper-small_216MB", "Whisper openai_whisper-base",
            "Tokenizer whisper-small", "Tokenizer whisper-base",
        ])
    }

    func testNeverListsTheModelsInUse() throws {
        try makeLayout()
        let unused = UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: qwen)
        let paths = unused.flatMap(\.urls).map(\.path)
        XCTAssertFalse(paths.contains { $0.contains("Qwen3-4B-Instruct-2507-4bit") })
        XCTAssertFalse(paths.contains { $0.contains(turbo) })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/whisper-large-v3") })
        XCTAssertFalse(paths.contains { $0.contains("/.locks/models--mlx-community--Qwen3-4B") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/.locks") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/.cache") })
    }

    func testNoAIMakesTheTextModelUnusedButKeepsWhisper() throws {
        try makeLayout()
        let unused = UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: nil)
        XCTAssertTrue(names(unused).contains(qwen))
        XCTAssertFalse(unused.flatMap(\.urls).contains { $0.path.contains(turbo) })
    }

    func testHubModelIncludesItsLockFolder() throws {
        try makeLayout()
        let gemma = UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: qwen)
            .first { $0.name == "mlx-community/gemma-4-e4b-it-4bit" }
        XCTAssertEqual(gemma?.urls.map(\.lastPathComponent), ["models--mlx-community--gemma-4-e4b-it-4bit",
                                                             "models--mlx-community--gemma-4-e4b-it-4bit"])
        XCTAssertTrue(gemma?.urls.last?.path.contains("/.locks/") == true)
    }

    func testWhisperVariantIncludesItsDownloadMetadata() throws {
        try makeLayout()
        let small = UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: qwen)
            .first { $0.name == "Whisper openai_whisper-small_216MB" }
        XCTAssertEqual(small?.urls.count, 2)
        XCTAssertTrue(small?.urls.last?.path.hasSuffix(".cache/huggingface/download/openai_whisper-small_216MB") == true)
    }

    func testSizesAreMeasuredAndSortedLargestFirst() throws {
        try makeLayout()
        try write("models--mlx-community--gemma-4-e4b-it-4bit/blobs/big", bytes: 50_000, in: hub)
        let unused = UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: qwen)
        XCTAssertEqual(unused.first?.name, "mlx-community/gemma-4-e4b-it-4bit")
        XCTAssertEqual(unused.map(\.bytes), unused.map(\.bytes).sorted(by: >))
        XCTAssertTrue(unused.allSatisfy { $0.bytes > 0 })
    }

    func testSymlinksAreNotCountedTwice() throws {
        let repo = hub.appendingPathComponent("models--org--m")
        try write("blobs/b1", bytes: 40_000, in: repo)
        try fm.createDirectory(at: repo.appendingPathComponent("snapshots/c"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: repo.appendingPathComponent("snapshots/c/model.safetensors"),
                                  withDestinationURL: repo.appendingPathComponent("blobs/b1"))
        XCTAssertEqual(UnusedModels.size(of: repo), UnusedModels.size(of: repo.appendingPathComponent("blobs")))
    }

    func testEmptyOrMissingRootsFindNothing() {
        XCTAssertEqual(UnusedModels.find(hub: hub, whisperBase: whisper, keepRepoID: qwen), [])
    }

    func testRepoIDFromCacheFolder() {
        XCTAssertEqual(UnusedModels.repoID(fromCacheFolder: "models--mlx-community--Qwen3.5-2B-OptiQ-4bit"),
                       "mlx-community/Qwen3.5-2B-OptiQ-4bit")
        XCTAssertNil(UnusedModels.repoID(fromCacheFolder: "datasets--a--b"))
        XCTAssertNil(UnusedModels.repoID(fromCacheFolder: "models--nope"))
    }
}
