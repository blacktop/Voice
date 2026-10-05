// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoiceMLXRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VoiceMLXRuntime", targets: ["VoiceMLXRuntime"])
    ],
    dependencies: [
        // A fork of upstream main at d20cbd66 (Breeze TTS 2, #255, untagged)
        // plus one commit: the official non-streaming prompt layout for
        // Qwen3-TTS CustomVoice / VoiceDesign, which keeps the speaking rate
        // flat across a long utterance. Move back to upstream `exact:` at the
        // next release that includes both.
        .package(
            url: "https://github.com/blacktop/mlx-audio-swift.git",
            revision: "c1b0cbf21cc105a1a6e81509f9dfa2df9ea0500d"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.6"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.10.1"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.4"
        ),
    ],
    targets: [
        .target(
            name: "VoiceMLXRuntime",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"]),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "VoiceMLXRuntimeTests",
            dependencies: [
                "VoiceMLXRuntime",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]
        ),
    ]
)
