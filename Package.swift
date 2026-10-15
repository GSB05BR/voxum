// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transcricao",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // The app's executable (= CFBundleExecutable in Resources/Info.plist, AppIdentity.fallbackName);
        // the target keeps its internal name and folder.
        .executable(name: "Voxum", targets: ["Transcricao"]),
        .executable(name: "tcli", targets: ["tcli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        // Automatic updates (spec §6): scripts/build-app.sh embeds Sparkle.framework in Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "TranscricaoCore"),
        .target(
            name: "TranscricaoEngines",
            dependencies: [
                "TranscricaoCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]),
        // Resources/<lang>.lproj: the UI strings (scripts/build-app.sh copies them into the app's
        // Contents/Resources, where Bundle.main and InfoPlist.strings look for them).
        .executableTarget(
            name: "Transcricao",
            dependencies: ["TranscricaoCore", "TranscricaoEngines", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework: scripts/build-app.sh embeds it in Contents/Frameworks and adds the rpath.
            resources: [.process("Resources")]),
        .executableTarget(name: "tcli", dependencies: ["TranscricaoCore", "TranscricaoEngines"]),
        .testTarget(name: "TranscricaoCoreTests", dependencies: ["TranscricaoCore"]),
        .testTarget(name: "TranscricaoEnginesTests", dependencies: ["TranscricaoEngines"]),
    ]
)
