import Foundation
import VoiceMLXRuntime

public enum MLXSpeechModel: String, CaseIterable, Identifiable, Sendable {
    case qwenSmall
    case qwenLarge
    case graniteCoding
    case cohereAccuracy
    case parakeetFast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwenSmall:
            "Qwen3 ASR 0.6B · 8-bit"
        case .qwenLarge:
            "Qwen3 ASR 1.7B · 8-bit"
        case .graniteCoding:
            "Granite 4.0 Speech 1B · 5-bit"
        case .cohereAccuracy:
            "Cohere Transcribe 2B · 8-bit"
        case .parakeetFast:
            "Parakeet TDT 0.6B v3"
        }
    }

    public var repositoryID: String {
        switch self {
        case .qwenSmall:
            "mlx-community/Qwen3-ASR-0.6B-8bit"
        case .qwenLarge:
            "mlx-community/Qwen3-ASR-1.7B-8bit"
        case .graniteCoding:
            "mlx-community/granite-4.0-1b-speech-5bit"
        case .cohereAccuracy:
            "beshkenadze/cohere-transcribe-03-2026-mlx-8bit"
        case .parakeetFast:
            "mlx-community/parakeet-tdt-0.6b-v3"
        }
    }

    /// An immutable Hugging Face snapshot, rather than a moving `main` branch.
    public var revision: String {
        switch self {
        case .qwenSmall:
            "89e96d92ba34aca20b3e29fb10cc284097d1219f"
        case .qwenLarge:
            "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
        case .graniteCoding:
            "371e6922faffba916e983e9c083049ad44536e94"
        case .cohereAccuracy:
            "d1f843476f84846e6fe7aa58a6033f17882f0ec9"
        case .parakeetFast:
            "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
        }
    }

    public var approximateDownload: String {
        switch self {
        case .qwenSmall:
            "about 1.0 GB"
        case .qwenLarge:
            "about 2.5 GB"
        case .graniteCoding:
            "about 2.1 GiB"
        case .cohereAccuracy:
            "about 2.3 GiB"
        case .parakeetFast:
            "about 2.3 GiB"
        }
    }

    public var detail: String {
        switch self {
        case .qwenSmall:
            "Smaller model and download; a practical place to start."
        case .qwenLarge:
            "Larger comparison candidate; compare both models on your own speech."
        case .graniteCoding:
            "Accuracy candidate with explicit keyword biasing for project identifiers."
        case .cohereAccuracy:
            "Highest published English accuracy candidate; verify speed on this Mac."
        case .parakeetFast:
            "Fast multilingual transcription with automatic detection for 25 languages."
        }
    }

    var runtimeArchitecture: MLXASRArchitecture {
        switch self {
        case .qwenSmall, .qwenLarge:
            .qwen3
        case .graniteCoding:
            .granite4
        case .cohereAccuracy:
            .cohereTranscribe
        case .parakeetFast:
            .parakeetTDT
        }
    }
}

public enum MLXModelPreparationStage: Sendable {
    case downloading(fraction: Double)
    case loading
    case ready
}

public struct MLXTranscriptionMetrics: Sendable {
    public let model: MLXSpeechModel
    public let audioDuration: TimeInterval
    public let inferenceDuration: TimeInterval
    public let peakMemoryGB: Double

    public init(
        model: MLXSpeechModel,
        audioDuration: TimeInterval,
        inferenceDuration: TimeInterval,
        peakMemoryGB: Double
    ) {
        self.model = model
        self.audioDuration = audioDuration
        self.inferenceDuration = inferenceDuration
        self.peakMemoryGB = peakMemoryGB
    }

    public var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return inferenceDuration / audioDuration
    }
}

public enum MLXSpeechRecognizerError: LocalizedError, Sendable {
    case alreadyRunning
    case audioDeviceChanged
    case audioDurationLimit(TimeInterval)
    case audioEngineUnavailable
    case emptyAudio
    case invalidAudioFormat
    case modelOutputMissing
    case notPrepared
    case notRunning
    case unsupportedHardware
    case unsupportedModel(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "MLX speech recognition is already capturing audio."
        case .audioDeviceChanged:
            "The audio input device changed mid-capture. Hold the hotkey to try again."
        case .audioDurationLimit(let seconds):
            "MLX dictation is limited to \(Int(seconds)) seconds per turn."
        case .audioEngineUnavailable:
            "Voice could not start the selected microphone. Check or reconnect the input "
                + "device in System Settings, then hold Right Option again."
        case .emptyAudio:
            "The microphone did not capture enough audio to transcribe."
        case .invalidAudioFormat:
            "The microphone did not provide audio MLX could convert to 16 kHz mono."
        case .modelOutputMissing:
            "The MLX model finished without producing a transcript."
        case .notPrepared:
            "The selected MLX speech model has not finished loading."
        case .notRunning:
            "MLX speech recognition is not currently capturing audio."
        case .unsupportedHardware:
            "MLX speech recognition requires an Apple Silicon Mac."
        case .unsupportedModel(let repository):
            "The MLX speech package could not load the selected model: \(repository)."
        }
    }
}
