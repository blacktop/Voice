import Foundation
internal import HuggingFace
@preconcurrency internal import MLX
internal import MLXAudioSTT

public enum MLXASRArchitecture: String, Sendable {
    case qwen3
    case granite4
    case cohereTranscribe
    case parakeetTDT
}

public enum MLXASRModelAccessPolicy: Sendable {
    case downloadIfNeeded
    case localOnly
}

public struct MLXASRConfiguration: Sendable {
    public let architecture: MLXASRArchitecture
    public let repositoryID: String
    public let revision: String
    public let modelStoreURL: URL
    public let accessPolicy: MLXASRModelAccessPolicy

    public init(
        architecture: MLXASRArchitecture,
        repositoryID: String,
        revision: String,
        modelStoreURL: URL,
        accessPolicy: MLXASRModelAccessPolicy = .downloadIfNeeded
    ) {
        self.architecture = architecture
        self.repositoryID = repositoryID
        self.revision = revision
        self.modelStoreURL = modelStoreURL
        self.accessPolicy = accessPolicy
    }
}

public enum MLXASRPreparationStage: Sendable {
    case downloading(fraction: Double)
    case loading
    case ready
}

public struct MLXASRResult: Sendable {
    public let text: String
    public let inferenceDuration: TimeInterval
    public let peakMemoryGB: Double

    public init(
        text: String,
        inferenceDuration: TimeInterval,
        peakMemoryGB: Double
    ) {
        self.text = text
        self.inferenceDuration = inferenceDuration
        self.peakMemoryGB = peakMemoryGB
    }
}

public enum MLXASRRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidRepositoryID(String)
    case missingOutput
    case notPrepared
    case transcriptionInProgress
    case unloading
    case unsupportedHardware

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let value):
            "Invalid MLX model repository: \(value)."
        case .missingOutput:
            "The MLX model finished without producing a transcript."
        case .notPrepared:
            "The MLX model has not finished loading."
        case .transcriptionInProgress:
            "The MLX runtime is already transcribing audio."
        case .unloading:
            "The MLX runtime is unloading its current model."
        case .unsupportedHardware:
            "MLX speech recognition requires an Apple Silicon Mac."
        }
    }
}

struct MLXASRTranscriptionGate {
    private(set) var isActive = false

    mutating func acquire() throws {
        guard !isActive else {
            throw MLXASRRuntimeError.transcriptionInProgress
        }
        isActive = true
    }

    mutating func release() {
        isActive = false
    }
}

protocol ParakeetGenerating {
    associatedtype Audio

    var defaultGenerationParameters: STTGenerateParameters { get }
    func generate(
        audio: Audio,
        generationParameters: STTGenerateParameters
    ) -> STTOutput
}

extension ParakeetModel: ParakeetGenerating {}

public actor MLXASRRuntime {
    private enum LoadedModel {
        case qwen3(Qwen3ASRModel)
        case granite4(GraniteSpeechModel)
        case cohereTranscribe(CohereTranscribeModel)
        case parakeetTDT(ParakeetModel)
    }

    private final class ModelSession: @unchecked Sendable {
        let model: LoadedModel

        init(model: LoadedModel) {
            self.model = model
        }
    }

    private let configuration: MLXASRConfiguration
    private let onPreparation: @Sendable (MLXASRPreparationStage) -> Void
    private var session: ModelSession?
    private var loadTask: Task<ModelSession, Error>?
    private var loadGeneration: UUID?
    private var unloadTask: Task<Void, Never>?
    private var unloadGeneration: UUID?
    private var transcriptionGate = MLXASRTranscriptionGate()
    private var transcriptionCompletion: AsyncStream<Void>?

    public init(
        configuration: MLXASRConfiguration,
        onPreparation: @escaping @Sendable (MLXASRPreparationStage) -> Void
    ) {
        self.configuration = configuration
        self.onPreparation = onPreparation
    }

    public static func isModelAvailableLocally(
        configuration: MLXASRConfiguration
    ) async -> Bool {
        do {
            _ = try await resolveSnapshot(
                configuration: configuration,
                accessPolicy: .localOnly
            )
            return true
        } catch {
            return false
        }
    }

    public func prepare() async throws {
        #if !arch(arm64)
            throw MLXASRRuntimeError.unsupportedHardware
        #else
            guard unloadTask == nil else {
                throw CancellationError()
            }
            if session != nil {
                onPreparation(.ready)
                return
            }
            if let loadTask, let generation = loadGeneration {
                let loaded = try await loadTask.value
                if session != nil {
                    onPreparation(.ready)
                    return
                }
                guard loadGeneration == generation else {
                    throw CancellationError()
                }
                session = loaded
                self.loadTask = nil
                loadGeneration = nil
                onPreparation(.ready)
                return
            }

            let configuration = configuration
            let preparationHandler = onPreparation
            preparationHandler(.downloading(fraction: 0))
            let generation = UUID()
            loadGeneration = generation
            let task = Task.detached(priority: .userInitiated) {
                try Self.prepareModelStore(at: configuration.modelStoreURL)
                let modelDirectory = try await Self.resolveSnapshot(
                    configuration: configuration,
                    accessPolicy: configuration.accessPolicy
                ) { progress in
                    preparationHandler(
                        .downloading(fraction: Self.fraction(from: progress))
                    )
                }
                try Task.checkCancellation()
                preparationHandler(.loading)
                let loaded: ModelSession
                switch configuration.architecture {
                case .qwen3:
                    let model = try await StrictLocalASRModelLoader.loadQwen3(
                        from: modelDirectory
                    )
                    loaded = ModelSession(model: .qwen3(model))
                case .granite4:
                    let model = try await StrictLocalASRModelLoader.loadGranite(
                        from: modelDirectory
                    )
                    loaded = ModelSession(model: .granite4(model))
                case .cohereTranscribe:
                    let model = try CohereTranscribeModel.fromDirectory(
                        modelDirectory
                    )
                    loaded = ModelSession(model: .cohereTranscribe(model))
                case .parakeetTDT:
                    let model = try ParakeetModel.fromDirectory(modelDirectory)
                    loaded = ModelSession(model: .parakeetTDT(model))
                }
                try Task.checkCancellation()
                return loaded
            }
            loadTask = task
            do {
                let loaded = try await task.value
                guard loadGeneration == generation else {
                    throw CancellationError()
                }
                session = loaded
                loadTask = nil
                loadGeneration = nil
                onPreparation(.ready)
            } catch {
                if loadGeneration == generation {
                    loadTask = nil
                    loadGeneration = nil
                }
                throw error
            }
        #endif
    }

    public func transcribe(
        samples: [Float],
        contextualStrings: [String]
    ) async throws -> MLXASRResult {
        guard unloadTask == nil else {
            throw MLXASRRuntimeError.unloading
        }
        guard let session else {
            throw MLXASRRuntimeError.notPrepared
        }
        try transcriptionGate.acquire()
        let (completion, completionContinuation) = AsyncStream<Void>.makeStream()
        transcriptionCompletion = completion
        defer {
            transcriptionCompletion = nil
            transcriptionGate.release()
            completionContinuation.finish()
        }

        Memory.peakMemory = 0
        let audio = MLXArray(samples)
        let started = ContinuousClock.now
        let reportsInferenceMetrics: Bool
        switch session.model {
        case .parakeetTDT:
            reportsInferenceMetrics = false
        case .qwen3, .granite4, .cohereTranscribe:
            reportsInferenceMetrics = true
        }
        var finalOutput: STTOutput?
        let stream: AsyncThrowingStream<STTGeneration, Error>?
        switch session.model {
        case .qwen3(let model):
            stream = model.generateStream(
                audio: audio,
                maxTokens: 4_096,
                temperature: 0,
                context: Self.context(from: contextualStrings),
                language: "English",
                chunkDuration: 300,
                minChunkDuration: 0.1,
                // Qwen's greedy decoder can fall into short local repetition loops
                // that do not trigger its 24-token runaway guard. The pinned MLX
                // implementation recommends 1.15 with a 32-token context.
                repetitionPenalty: 1.15,
                repetitionContextSize: 32
            )
        case .granite4(let model):
            stream = model.generateStream(
                audio: audio,
                maxTokens: 4_096,
                temperature: 0,
                prompt: Self.granitePrompt(from: contextualStrings)
            )
        case .cohereTranscribe(let model):
            stream = model.generateStream(
                audio: audio,
                generationParameters: Self.cohereGenerationParameters(
                    from: model.defaultGenerationParameters
                )
            )
        case .parakeetTDT(let model):
            finalOutput = Self.decodeParakeetTurn(model: model, audio: audio)
            stream = nil
        }
        if let stream {
            for try await event in stream {
                try Task.checkCancellation()
                if case .result(let output) = event {
                    finalOutput = output
                }
            }
        }
        try Task.checkCancellation()
        guard let finalOutput else {
            throw MLXASRRuntimeError.missingOutput
        }

        let elapsed = ContinuousClock.now - started
        let measuredDuration =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let inferenceDuration =
            reportsInferenceMetrics && finalOutput.totalTime > 0
            ? finalOutput.totalTime : measuredDuration
        let peakMemoryGB =
            reportsInferenceMetrics
            ? finalOutput.peakMemoryUsage : Double(Memory.peakMemory) / 1e9
        return MLXASRResult(
            text: finalOutput.text.trimmingCharacters(in: .whitespacesAndNewlines),
            inferenceDuration: inferenceDuration,
            peakMemoryGB: peakMemoryGB
        )
    }

    static func decodeParakeetTurn<Model: ParakeetGenerating>(
        model: Model,
        audio: Model.Audio
    ) -> STTOutput {
        model.generate(
            audio: audio,
            generationParameters: englishParameters(
                from: model.defaultGenerationParameters
            )
        )
    }

    public func unload() async {
        if let unloadTask {
            await unloadTask.value
            return
        }
        let task = loadTask
        loadGeneration = nil
        loadTask = nil
        task?.cancel()
        let transcriptionCompletion = transcriptionCompletion
        let generation = UUID()
        unloadGeneration = generation
        let unloadTask = Task {
            if let transcriptionCompletion {
                for await _ in transcriptionCompletion {}
            }
            _ = await task?.result
            session = nil
            Memory.clearCache()
        }
        self.unloadTask = unloadTask
        await unloadTask.value
        if unloadGeneration == generation {
            self.unloadTask = nil
            unloadGeneration = nil
        }
    }

    private static func prepareModelStore(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func resolveSnapshot(
        configuration: MLXASRConfiguration,
        accessPolicy: MLXASRModelAccessPolicy,
        progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        guard let repository = Repo.ID(rawValue: configuration.repositoryID) else {
            throw MLXASRRuntimeError.invalidRepositoryID(
                configuration.repositoryID
            )
        }
        let cache = HubCache(cacheDirectory: configuration.modelStoreURL)
        let client = HubClient(
            host: HubClient.defaultHost,
            bearerToken: nil,
            cache: cache
        )
        return try await client.downloadSnapshot(
            of: repository,
            kind: .model,
            revision: configuration.revision,
            matching: snapshotPatterns(for: configuration.architecture),
            localFilesOnly: localFilesOnly(for: accessPolicy),
            maxConcurrentDownloads: 4,
            progressHandler: progressHandler
        )
    }

    static func snapshotPatterns(
        for architecture: MLXASRArchitecture
    ) -> [String] {
        switch architecture {
        case .cohereTranscribe:
            ["*.safetensors", "*.json", "*.txt", "*.model"]
        case .qwen3, .granite4, .parakeetTDT:
            ["*.safetensors", "*.json", "*.txt"]
        }
    }

    static func localFilesOnly(
        for accessPolicy: MLXASRModelAccessPolicy
    ) -> Bool {
        switch accessPolicy {
        case .downloadIfNeeded:
            false
        case .localOnly:
            true
        }
    }

    private static func fraction(from progress: Progress) -> Double {
        guard progress.totalUnitCount > 0 else { return 0 }
        return min(
            1,
            max(
                0,
                Double(progress.completedUnitCount)
                    / Double(progress.totalUnitCount)
            )
        )
    }

    private static func context(from strings: [String]) -> String {
        let terms = contextualTerms(from: strings)
        guard !terms.isEmpty else { return "" }
        return "Use these spellings when they match the audio: "
            + terms.joined(separator: ", ")
    }

    private static func granitePrompt(from strings: [String]) -> String {
        let base = "can you transcribe the speech into a written format?"
        let terms = contextualTerms(from: strings)
        guard !terms.isEmpty else { return base }
        return base + "\nKeywords: " + terms.joined(separator: ", ")
    }

    private static func contextualTerms(from strings: [String]) -> [String] {
        Array(
            strings
                .lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(100)
        )
    }

    private static func englishParameters(
        from defaults: STTGenerateParameters
    ) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: defaults.maxTokens,
            temperature: defaults.temperature,
            topP: defaults.topP,
            topK: defaults.topK,
            verbose: false,
            language: "en",
            chunkDuration: defaults.chunkDuration,
            minChunkDuration: defaults.minChunkDuration,
            repetitionPenalty: defaults.repetitionPenalty,
            repetitionContextSize: defaults.repetitionContextSize
        )
    }

    static func cohereGenerationParameters(
        from defaults: STTGenerateParameters
    ) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: 4_096,
            temperature: defaults.temperature,
            topP: defaults.topP,
            topK: defaults.topK,
            verbose: false,
            language: "en",
            chunkDuration: 30,
            minChunkDuration: defaults.minChunkDuration,
            repetitionPenalty: defaults.repetitionPenalty,
            repetitionContextSize: defaults.repetitionContextSize
        )
    }
}
