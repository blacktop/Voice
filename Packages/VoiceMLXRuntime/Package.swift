// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoiceMLXRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceMLXRuntime", targets: ["VoiceMLXRuntime"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.8.1"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.2.1"
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
                .unsafeFlags(["-enable-library-evolution"])
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
