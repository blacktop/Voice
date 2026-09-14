// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoiceMLXRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VoiceMLXRuntime", targets: ["VoiceMLXRuntime"])
    ],
    dependencies: [
        // Pinned to a main commit rather than a tag: Breeze TTS 2 support
        // (#255, 2026-09-02) has not been tagged yet. Move back to `exact:`
        // at the next release that includes it.
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "d20cbd660424c9f202363306ef4ff4595a199356"
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
