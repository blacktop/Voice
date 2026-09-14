# MLX third-party software and models

Voice's optional MLX recognizer uses the following direct Swift packages. The
manifest pins each direct dependency exactly, and the checked-in Xcode
`Package.resolved` pins the complete transitive graph. `just build`, `just test`,
and `just release` reject resolution that differs from that lock file.

| Component | Pin | License |
| --- | --- | --- |
| [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift) | main `d20cbd660424c9f202363306ef4ff4595a199356` (2026-09-02, untagged; first commit with Breeze TTS 2) | [MIT](https://github.com/Blaizzy/mlx-audio-swift/blob/d20cbd660424c9f202363306ef4ff4595a199356/LICENSE) |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) | 0.31.6 (`0bb916c67f4b9e5c682cbe02a42c701c93ab5021`) | [MIT](https://github.com/ml-explore/mlx-swift/blob/0bb916c67f4b9e5c682cbe02a42c701c93ab5021/LICENSE) |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | 3.31.4 (`bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`) | [MIT](https://github.com/ml-explore/mlx-swift-lm/blob/bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57/LICENSE) |
| [Swift Hugging Face](https://github.com/huggingface/swift-huggingface) | 0.10.1 (`b5403ed09403f674601fd1123e07c5b32914d16f`) | [Apache-2.0](https://github.com/huggingface/swift-huggingface/blob/b5403ed09403f674601fd1123e07c5b32914d16f/LICENSE) |
| [Swift Transformers](https://github.com/huggingface/swift-transformers) | 1.3.4 (`c21fdcde390313a6d98d8e33a346f2c3486c3ab0`) | [Apache-2.0](https://github.com/huggingface/swift-transformers/blob/c21fdcde390313a6d98d8e33a346f2c3486c3ab0/LICENSE) |

The optional model weights are downloaded only after the user selects a model;
they are not bundled with Voice. Every runtime download is pinned to the exact
snapshot listed below:

| Model snapshot | Immutable Hugging Face revision | Approximate download | License |
| --- | --- | --- | --- |
| [Qwen3-ASR-0.6B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit/tree/89e96d92ba34aca20b3e29fb10cc284097d1219f) | `89e96d92ba34aca20b3e29fb10cc284097d1219f` | 1.01 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit/blob/89e96d92ba34aca20b3e29fb10cc284097d1219f/README.md) |
| [Qwen3-ASR-1.7B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55) | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | 2.46 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/blob/a8379a2e2f9e313c9292cdf1af4055ab56d50d55/README.md) |
| [Granite 4.0 1B Speech 5-bit](https://huggingface.co/mlx-community/granite-4.0-1b-speech-5bit/tree/371e6922faffba916e983e9c083049ad44536e94) | `371e6922faffba916e983e9c083049ad44536e94` | 2.07 GiB (2,225,217,762 selected bytes) | [Apache-2.0](https://huggingface.co/mlx-community/granite-4.0-1b-speech-5bit/blob/371e6922faffba916e983e9c083049ad44536e94/README.md) |
| [Cohere Transcribe 2B 8-bit](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-8bit/tree/d1f843476f84846e6fe7aa58a6033f17882f0ec9) | `d1f843476f84846e6fe7aa58a6033f17882f0ec9` | 2.25 GiB (2,418,766,535 selected bytes) | [Apache-2.0](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-8bit/blob/d1f843476f84846e6fe7aa58a6033f17882f0ec9/README.md) |
| [Parakeet TDT 0.6B v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/tree/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15) | `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15` | 2.34 GiB (2,508,579,601 selected bytes) | [CC-BY-4.0](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/blob/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15/README.md) |
| [Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit/tree/049ef77fe8816b536193c0c25f9a214d17921282) | `049ef77fe8816b536193c0c25f9a214d17921282` | about 1.1 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit/blob/049ef77fe8816b536193c0c25f9a214d17921282/README.md) |
| [Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/tree/41d3337e8b7f2843a75841595fc14e4b9a7a4b96) | `41d3337e8b7f2843a75841595fc14e4b9a7a4b96` | about 2.4 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/blob/41d3337e8b7f2843a75841595fc14e4b9a7a4b96/README.md) |
| [Qwen3-TTS-12Hz-0.6B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit/tree/50f45ef0047cde7e84c2ef04326acb8ada2436a7) | `50f45ef0047cde7e84c2ef04326acb8ada2436a7` | about 1.1 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit/blob/50f45ef0047cde7e84c2ef04326acb8ada2436a7/README.md) |
| [Qwen3-TTS-12Hz-1.7B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit/tree/e7dd0585652209fa0d7783659aad4e8a324de11c) | `e7dd0585652209fa0d7783659aad4e8a324de11c` | about 2.4 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit/blob/e7dd0585652209fa0d7783659aad4e8a324de11c/README.md) |
| [Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit/tree/f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee) | `f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee` | about 2.4 GB | [Apache-2.0](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit/blob/f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee/README.md) |
| [Breeze-TTS-2-mlx-4bit](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-4bit/tree/3a06d26b172ea4ae1da2f42d708383e9c79d5526) | `3a06d26b172ea4ae1da2f42d708383e9c79d5526` | about 3.0 GB | [BreezeBlue Research and Non-Commercial License](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-4bit/blob/3a06d26b172ea4ae1da2f42d708383e9c79d5526/LICENSE) (weights; the inference code is Apache-2.0) |

The source package lock and model revisions serve different purposes: the lock
freezes build inputs, while the model revisions freeze runtime downloads. Model
size is not treated as an accuracy claim. Published WER, real-time factor, and
throughput values across these model cards use different corpora, hardware,
precision, and decoding implementations. They are not directly comparable to
Voice's microphone path; every candidate must be measured from the same local
audio on the same Mac before drawing a speed or accuracy conclusion.

Breeze TTS 2 is the one checkpoint whose weights are not under an open-source
license: BreezeBlue permits research and non-commercial use only, and commercial
use needs written authorization from RESONIA, INC. Voice never redistributes
weights, so the obligation falls on whoever downloads and uses the checkpoint.

Before distributing Voice, include the license notices required by the complete
resolved dependency graph in the app bundle and release materials. This file is
an inventory, not a replacement for those notices.
