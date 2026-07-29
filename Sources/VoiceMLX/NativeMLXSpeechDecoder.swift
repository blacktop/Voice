import Foundation
import VoiceMLXRuntime

struct MLXDecodingResult: Sendable {
    let text: String
    let inferenceDuration: TimeInterval
    let peakMemoryGB: Double
}

protocol MLXSpeechDecoding: Sendable {
    func prepare() async throws
    func transcribe(
        samples: [Float],
        contextualStrings: [String]
    ) async throws -> MLXDecodingResult
    func unload() async
}

actor NativeMLXSpeechDecoder: MLXSpeechDecoding {
    private let runtime: MLXASRRuntime

    init(
        model: MLXSpeechModel,
        accessPolicy: MLXASRModelAccessPolicy = .downloadIfNeeded,
        onPreparation: @escaping @Sendable (MLXModelPreparationStage) -> Void
    ) {
        runtime = MLXASRRuntime(
            configuration: Self.configuration(
                for: model,
                accessPolicy: accessPolicy
            )
        ) { stage in
            switch stage {
            case .downloading(let fraction):
                onPreparation(.downloading(fraction: fraction))
            case .loading:
                onPreparation(.loading)
            case .ready:
                onPreparation(.ready)
            @unknown default:
                break
            }
        }
    }

    static func isModelAvailableLocally(_ model: MLXSpeechModel) async -> Bool {
        await MLXASRRuntime.isModelAvailableLocally(
            configuration: configuration(
                for: model,
                accessPolicy: .localOnly
            )
        )
    }

    func prepare() async throws {
        try await runtime.prepare()
    }

    func transcribe(
        samples: [Float],
        contextualStrings: [String]
    ) async throws -> MLXDecodingResult {
        guard !samples.isEmpty else {
            throw MLXSpeechRecognizerError.emptyAudio
        }
        let result = try await runtime.transcribe(
            samples: samples,
            contextualStrings: contextualStrings
        )
        return MLXDecodingResult(
            text: result.text,
            inferenceDuration: result.inferenceDuration,
            peakMemoryGB: result.peakMemoryGB
        )
    }

    func unload() async {
        await runtime.unload()
    }

    private static func configuration(
        for model: MLXSpeechModel,
        accessPolicy: MLXASRModelAccessPolicy
    ) -> MLXASRConfiguration {
        MLXASRConfiguration(
            architecture: model.runtimeArchitecture,
            repositoryID: model.repositoryID,
            revision: model.revision,
            modelStoreURL: modelStoreURL,
            accessPolicy: accessPolicy
        )
    }

    private static var modelStoreURL: URL { MLXSpeechRecognizer.modelStoreURL }
}
