import AVFAudio
import Foundation
import VoiceMLXRuntime

public struct MLXCorpusClip: Sendable {
    public let name: String
    public let audioURL: URL

    public init(name: String, audioURL: URL) {
        self.name = name
        self.audioURL = audioURL
    }
}

public struct MLXCorpusClipResult: Sendable {
    public let clipName: String
    public let transcript: String?
    public let errorDescription: String?
    public let audioDuration: TimeInterval
    public let inferenceDuration: TimeInterval?

    public var realTimeFactor: Double? {
        guard let inferenceDuration, audioDuration > 0 else { return nil }
        return inferenceDuration / audioDuration
    }
}

public struct MLXCorpusModelResult: Sendable {
    public let model: MLXSpeechModel
    public let clips: [MLXCorpusClipResult]
}

public enum MLXCorpusBenchmarkError: LocalizedError, Sendable {
    case noClips
    case noModels

    public var errorDescription: String? {
        switch self {
        case .noClips:
            "The corpus directory contains no audio clips with reference transcripts."
        case .noModels:
            "No MLX models are downloaded. Download one in Settings › Speech first."
        }
    }
}

/// Batch transcription of a fixed clip corpus across locally downloaded
/// models. Unlike the live same-audio comparison, each model loads once and
/// transcribes every clip before unloading, so wall-clock time scales with
/// model count rather than model count times clip count.
public enum MLXCorpusBenchmark {
    public static func downloadedModels() async -> [MLXSpeechModel] {
        var models: [MLXSpeechModel] = []
        for model in MLXSpeechModel.allCases
        where await NativeMLXSpeechDecoder.isModelAvailableLocally(model) {
            models.append(model)
        }
        return models
    }

    public static func run(
        clips: [MLXCorpusClip],
        models: [MLXSpeechModel],
        contextualStrings: [String] = [],
        onProgress: @Sendable (String) -> Void = { _ in }
    ) async throws -> [MLXCorpusModelResult] {
        guard !clips.isEmpty else { throw MLXCorpusBenchmarkError.noClips }
        guard !models.isEmpty else { throw MLXCorpusBenchmarkError.noModels }
        let context = Array(contextualStrings.prefix(100))

        var results: [MLXCorpusModelResult] = []
        for model in models {
            try Task.checkCancellation()
            onProgress("Loading \(model.displayName)…")
            let decoder = NativeMLXSpeechDecoder(
                model: model,
                accessPolicy: .localOnly,
                onPreparation: { _ in }
            )
            do {
                try await decoder.prepare()
            } catch {
                await decoder.unload()
                results.append(
                    MLXCorpusModelResult(
                        model: model,
                        clips: clips.map {
                            MLXCorpusClipResult(
                                clipName: $0.name,
                                transcript: nil,
                                errorDescription: error.localizedDescription,
                                audioDuration: 0,
                                inferenceDuration: nil
                            )
                        }
                    )
                )
                continue
            }
            let clipResults = await transcribeAll(
                clips: clips,
                model: model,
                decoder: decoder,
                contextualStrings: context,
                onProgress: onProgress
            )
            await decoder.unload()
            try Task.checkCancellation()
            results.append(MLXCorpusModelResult(model: model, clips: clipResults))
        }
        return results
    }

    private static func transcribeAll(
        clips: [MLXCorpusClip],
        model: MLXSpeechModel,
        decoder: any MLXSpeechDecoding,
        contextualStrings: [String],
        onProgress: @Sendable (String) -> Void
    ) async -> [MLXCorpusClipResult] {
        var clipResults: [MLXCorpusClipResult] = []
        for (offset, clip) in clips.enumerated() {
            onProgress("\(model.displayName) · \(clip.name) (\(offset + 1)/\(clips.count))")
            do {
                let audio = try MLXAudioFileLoader.load(url: clip.audioURL)
                let started = ContinuousClock.now
                let decoded = try await decoder.transcribe(
                    samples: audio.samples,
                    contextualStrings: contextualStrings
                )
                let elapsed = ContinuousClock.now - started
                let seconds =
                    Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                clipResults.append(
                    MLXCorpusClipResult(
                        clipName: clip.name,
                        transcript: decoded.text,
                        errorDescription: nil,
                        audioDuration: audio.duration,
                        inferenceDuration: seconds
                    )
                )
            } catch {
                clipResults.append(
                    MLXCorpusClipResult(
                        clipName: clip.name,
                        transcript: nil,
                        errorDescription: error.localizedDescription,
                        audioDuration: 0,
                        inferenceDuration: nil
                    )
                )
            }
        }
        return clipResults
    }
}
