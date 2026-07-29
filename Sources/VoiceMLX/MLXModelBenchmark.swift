import Foundation
import VoiceMLXRuntime

public struct MLXBenchmarkResult: Identifiable, Sendable {
    public let model: MLXSpeechModel
    public let transcript: String?
    public let errorDescription: String?
    public let audioDuration: TimeInterval
    public let inferenceDuration: TimeInterval?
    public let peakMemoryGB: Double?

    public var id: String { model.id }

    public var realTimeFactor: Double? {
        guard let inferenceDuration, audioDuration > 0 else { return nil }
        return inferenceDuration / audioDuration
    }
}

public struct MLXBenchmarkProgress: Sendable {
    public let model: MLXSpeechModel
    /// One-based position in this comparison.
    public let index: Int
    public let total: Int
}

public enum MLXModelBenchmarkError: LocalizedError, Sendable {
    case alreadyRunning
    case insufficientDownloadedModels
    case invalidModelSelection
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "An MLX model comparison is already running."
        case .insufficientDownloadedModels:
            "Download at least two MLX models before recording a comparison."
        case .invalidModelSelection:
            "The comparison must use at least two models that were available when recording began."
        case .notRecording:
            "No MLX model comparison is recording."
        }
    }
}

public actor MLXModelBenchmark {
    public typealias FailureHandler = @Sendable (String) -> Void
    public typealias ProgressHandler = @Sendable (MLXBenchmarkProgress) -> Void

    typealias ModelProvider = @Sendable () async -> [MLXSpeechModel]
    typealias DecoderFactory =
        @Sendable (
            MLXSpeechModel, MLXASRModelAccessPolicy
        ) -> any MLXSpeechDecoding

    private let capture: any MLXAudioCapturing
    private let modelProvider: ModelProvider
    private let decoderFactory: DecoderFactory
    private var startID: UUID?
    private var recordingModels: [MLXSpeechModel]?
    private var comparisonID: UUID?
    private var comparisonTask: Task<[MLXBenchmarkResult], Error>?

    public init() {
        capture = MLXAudioCapture()
        modelProvider = {
            var models: [MLXSpeechModel] = []
            for model in MLXSpeechModel.allCases
            where await NativeMLXSpeechDecoder.isModelAvailableLocally(model) {
                models.append(model)
            }
            return models
        }
        decoderFactory = { model, accessPolicy in
            NativeMLXSpeechDecoder(
                model: model,
                accessPolicy: accessPolicy,
                onPreparation: { _ in }
            )
        }
    }

    init(
        capture: any MLXAudioCapturing,
        modelProvider: @escaping ModelProvider,
        decoderFactory: @escaping DecoderFactory
    ) {
        self.capture = capture
        self.modelProvider = modelProvider
        self.decoderFactory = decoderFactory
    }

    public func downloadedModels() async -> [MLXSpeechModel] {
        let identifiers = Set(await modelProvider().map(\.rawValue))
        return MLXSpeechModel.allCases.filter { identifiers.contains($0.rawValue) }
    }

    @discardableResult
    public func startRecording(
        onFailure: @escaping FailureHandler = { _ in }
    ) async throws -> [MLXSpeechModel] {
        guard startID == nil, recordingModels == nil, comparisonTask == nil else {
            throw MLXModelBenchmarkError.alreadyRunning
        }
        let id = UUID()
        startID = id
        do {
            let models = await downloadedModels()
            guard startID == id else { throw CancellationError() }
            guard models.count >= 2 else {
                throw MLXModelBenchmarkError.insufficientDownloadedModels
            }
            try await capture.start { error in onFailure(error.localizedDescription) }
            // start() suspends while the engine proves it delivers audio; a
            // cancel() during that window must not be undone here.
            guard startID == id else {
                capture.cancel()
                throw CancellationError()
            }
            startID = nil
            recordingModels = models
            return models
        } catch {
            if startID == id { startID = nil }
            throw error
        }
    }

    public func stopAndCompare(
        models: [MLXSpeechModel],
        contextualStrings: [String],
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> [MLXBenchmarkResult] {
        guard startID == nil, comparisonTask == nil else {
            throw MLXModelBenchmarkError.alreadyRunning
        }
        guard let availableModels = recordingModels else {
            throw MLXModelBenchmarkError.notRecording
        }
        let requestedModels = Self.uniqueCatalogModels(from: models)
        let availableIDs = Set(availableModels.map(\.rawValue))
        guard requestedModels.count >= 2,
            requestedModels.allSatisfy({ availableIDs.contains($0.rawValue) })
        else {
            throw MLXModelBenchmarkError.invalidModelSelection
        }

        recordingModels = nil
        let audio = try capture.stop()
        guard audio.duration >= 0.08 else {
            throw MLXSpeechRecognizerError.emptyAudio
        }
        let id = UUID()
        let task = Task {
            try await Self.compare(
                models: requestedModels,
                audio: audio,
                contextualStrings: Array(contextualStrings.prefix(100)),
                decoderFactory: decoderFactory,
                onProgress: onProgress
            )
        }
        comparisonID = id
        comparisonTask = task
        do {
            let results = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearComparison(id: id)
            return results
        } catch {
            clearComparison(id: id)
            throw error
        }
    }

    public func cancel() async {
        startID = nil
        recordingModels = nil
        capture.cancel()
        guard let task = comparisonTask, let id = comparisonID else { return }
        task.cancel()
        _ = await task.result
        clearComparison(id: id)
    }

    private func clearComparison(id: UUID) {
        guard comparisonID == id else { return }
        comparisonID = nil
        comparisonTask = nil
    }

    private nonisolated static func compare(
        models: [MLXSpeechModel],
        audio: MLXCapturedAudio,
        contextualStrings: [String],
        decoderFactory: DecoderFactory,
        onProgress: ProgressHandler
    ) async throws -> [MLXBenchmarkResult] {
        var results: [MLXBenchmarkResult] = []
        for (offset, model) in models.enumerated() {
            try Task.checkCancellation()
            onProgress(.init(model: model, index: offset + 1, total: models.count))
            try Task.checkCancellation()
            let decoder = decoderFactory(model, .localOnly)
            var didUnload = false
            do {
                try await decoder.prepare()
                let started = ContinuousClock.now
                let decoded = try await decoder.transcribe(
                    samples: audio.samples,
                    contextualStrings: contextualStrings
                )
                let duration = Self.seconds(since: started)
                guard !decoded.text.isEmpty else {
                    throw MLXSpeechRecognizerError.modelOutputMissing
                }
                await decoder.unload()
                didUnload = true
                try Task.checkCancellation()
                results.append(
                    MLXBenchmarkResult(
                        model: model,
                        transcript: decoded.text,
                        errorDescription: nil,
                        audioDuration: audio.duration,
                        inferenceDuration: duration,
                        peakMemoryGB: decoded.peakMemoryGB
                    )
                )
            } catch {
                if !didUnload { await decoder.unload() }
                guard !Task.isCancelled, !(error is CancellationError) else {
                    throw CancellationError()
                }
                results.append(
                    MLXBenchmarkResult(
                        model: model,
                        transcript: nil,
                        errorDescription: error.localizedDescription,
                        audioDuration: audio.duration,
                        inferenceDuration: nil,
                        peakMemoryGB: nil
                    )
                )
            }
        }
        return results
    }

    private nonisolated static func uniqueCatalogModels(
        from models: [MLXSpeechModel]
    ) -> [MLXSpeechModel] {
        let identifiers = Set(models.map(\.rawValue))
        return MLXSpeechModel.allCases.filter { identifiers.contains($0.rawValue) }
    }

    private nonisolated static func seconds(
        since start: ContinuousClock.Instant
    ) -> TimeInterval {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
