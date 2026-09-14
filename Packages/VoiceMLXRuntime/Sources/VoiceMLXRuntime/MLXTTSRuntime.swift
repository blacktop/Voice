import Foundation
internal import HuggingFace
@preconcurrency internal import MLX
internal import MLXAudioCore
internal import MLXAudioTTS
internal import MLXLMCommon
import Synchronization

public enum MLXTTSModelAccessPolicy: Sendable {
    case downloadIfNeeded
    case localOnly
}

public struct MLXTTSConfiguration: Sendable {
    public let repositoryID: String
    public let revision: String
    public let modelStoreURL: URL
    public let accessPolicy: MLXTTSModelAccessPolicy

    public init(
        repositoryID: String,
        revision: String,
        modelStoreURL: URL,
        accessPolicy: MLXTTSModelAccessPolicy = .downloadIfNeeded
    ) {
        self.repositoryID = repositoryID
        self.revision = revision
        self.modelStoreURL = modelStoreURL
        self.accessPolicy = accessPolicy
    }
}

public enum MLXTTSPreparationStage: Sendable {
    case downloading(fraction: Double)
    case loading
    case ready
}

/// A run of synthesized speech samples ready for playback.
public struct MLXTTSAudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// How one utterance should sound.
///
/// - Preset and designed voices supply `voiceInstruction` only: a speaker name
///   with optional style ("Ryan, calm and slow.") for CustomVoice checkpoints,
///   or a full voice description for VoiceDesign checkpoints.
/// - Cloned voices supply `referenceAudioURL` and `referenceTranscript` (Base
///   checkpoints). A `voiceInstruction` may be combined with a clone to steer
///   delivery (for example an accent); without one, the reference conditioning
///   is computed once and cached for later utterances.
public struct MLXTTSVoiceRequest: Sendable {
    public let voiceInstruction: String?
    public let referenceAudioURL: URL?
    public let referenceTranscript: String?

    public init(
        voiceInstruction: String? = nil,
        referenceAudioURL: URL? = nil,
        referenceTranscript: String? = nil
    ) {
        self.voiceInstruction = voiceInstruction
        self.referenceAudioURL = referenceAudioURL
        self.referenceTranscript = referenceTranscript
    }
}

public enum MLXTTSRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidRepositoryID(String)
    case notPrepared
    case referenceTranscriptMissing
    case synthesisInProgress
    case unloading
    case unsupportedHardware

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let value):
            "Invalid MLX speech model repository: \(value)."
        case .notPrepared:
            "The MLX speech model has not finished loading."
        case .referenceTranscriptMissing:
            "Voice cloning needs the transcript of the reference clip."
        case .synthesisInProgress:
            "The MLX runtime is already synthesizing speech."
        case .unloading:
            "The MLX runtime is unloading its current speech model."
        case .unsupportedHardware:
            "MLX speech synthesis requires an Apple Silicon Mac."
        }
    }
}

/// Downloads (pinned to one immutable revision), loads, and drives a local
/// Qwen3-TTS checkpoint. Synthesis streams audio chunks so playback can begin
/// before the full utterance has been generated.
public actor MLXTTSRuntime {
    private final class ModelSession: @unchecked Sendable {
        let model: Qwen3TTSModel
        // Reference-conditioning cache for cloned voices. Accessed only from
        // synthesis tasks, which the runtime's single-synthesis gate serializes.
        var conditioningKey: String?
        var conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?

        init(model: Qwen3TTSModel) {
            self.model = model
        }

        func cachedConditioning(
            referenceAudioURL: URL,
            transcript: String,
            language: String
        ) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning {
            let key = [referenceAudioURL.path, transcript, language]
                .joined(separator: "\u{1F}")
            if conditioningKey == key, let conditioning {
                return conditioning
            }
            let (_, referenceAudio) = try loadAudioArray(
                from: referenceAudioURL,
                sampleRate: model.sampleRate
            )
            let prepared = try model.prepareReferenceConditioning(
                refAudio: referenceAudio,
                refText: transcript,
                language: language
            )
            conditioningKey = key
            conditioning = prepared
            return prepared
        }
    }

    private let configuration: MLXTTSConfiguration
    private let onPreparation: @Sendable (MLXTTSPreparationStage) -> Void
    private var session: ModelSession?
    private var loadTask: Task<ModelSession, Error>?
    private var loadGeneration: UUID?
    private var unloadTask: Task<Void, Never>?
    private var unloadGeneration: UUID?
    private var synthesisActive = false
    private var synthesisGeneration: UUID?
    private var activeGeneration: Task<Void, Never>?
    private var producerFinished: SynthesisFinishedFlag?
    private var synthesisCompletion: AsyncStream<Void>?
    private var synthesisCompletionContinuation: AsyncStream<Void>.Continuation?

    public init(
        configuration: MLXTTSConfiguration,
        onPreparation: @escaping @Sendable (MLXTTSPreparationStage) -> Void
    ) {
        self.configuration = configuration
        self.onPreparation = onPreparation
    }

    public static func isModelAvailableLocally(
        configuration: MLXTTSConfiguration
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
            throw MLXTTSRuntimeError.unsupportedHardware
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
            let task = Task(priority: .userInitiated) { @concurrent in
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
                let model = try await Qwen3TTSModel.fromModelDirectory(modelDirectory)
                try Task.checkCancellation()
                return ModelSession(model: model)
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

    /// Streams synthesized audio for one utterance. The returned stream must be
    /// consumed (or cancelled) before another synthesis can start; a caller that
    /// drains one stream and immediately asks for the next is served in turn.
    public func synthesize(
        text: String,
        request: MLXTTSVoiceRequest,
        language: String
    ) async throws -> AsyncThrowingStream<MLXTTSAudioChunk, Error> {
        let referenceTranscript =
            request.referenceTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if request.referenceAudioURL != nil, referenceTranscript.isEmpty {
            throw MLXTTSRuntimeError.referenceTranscriptMissing
        }
        // The gate is reopened from a detached teardown task, so a caller
        // synthesizing back-to-back — one call per text segment, and every
        // interrupt-then-speak — arrives while that task is still queued. Wait
        // for the generation being torn down instead of rejecting the caller.
        //
        // Both conditions are needed. `isCancelled` covers an abandoned stream,
        // where termination is what cancels the generation. `producerFinished`
        // covers a drained one: the stream's termination handler is not ordered
        // against the consumer waking from its final chunk, so the consumer can
        // be back here first, and only the producer's own flag is set by then.
        if synthesisActive, let previous = activeGeneration,
            previous.isCancelled || producerFinished?.isSet == true,
            let generation = synthesisGeneration
        {
            await previous.value
            finishSynthesis(generation: generation)
        }
        guard unloadTask == nil else {
            throw MLXTTSRuntimeError.unloading
        }
        guard let session else {
            throw MLXTTSRuntimeError.notPrepared
        }
        guard !synthesisActive else {
            throw MLXTTSRuntimeError.synthesisInProgress
        }
        synthesisActive = true
        let generation = UUID()
        synthesisGeneration = generation
        let (completion, completionContinuation) = AsyncStream<Void>.makeStream()
        synthesisCompletion = completion
        synthesisCompletionContinuation = completionContinuation

        let sampleRate = Double(session.model.sampleRate)
        let pair = AsyncThrowingStream<MLXTTSAudioChunk, Error>.makeStream()
        let finished = SynthesisFinishedFlag()
        let generationTask = Task(priority: .userInitiated) { @concurrent in
            do {
                let samplesStream = try Self.makeSamplesStream(
                    session: session,
                    text: text,
                    request: request,
                    referenceTranscript: referenceTranscript,
                    language: language
                )
                for try await samples in samplesStream {
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { continue }
                    pair.continuation.yield(
                        MLXTTSAudioChunk(samples: samples, sampleRate: sampleRate)
                    )
                }
                finished.set()
                pair.continuation.finish()
            } catch {
                finished.set()
                pair.continuation.finish(throwing: error)
            }
        }
        activeGeneration = generationTask
        producerFinished = finished
        pair.continuation.onTermination = { [weak self] _ in
            _ = Self.finishAfterCancelling(generationTask) { [weak self] in
                await self?.finishSynthesis(generation: generation)
            }
        }
        return pair.stream
    }

    /// Records that a generation task has stopped producing, set by that task
    /// itself rather than by the stream's termination handler so the answer is
    /// already correct the moment the consumer wakes from the final chunk.
    /// A class because the flag is shared between the generation task and the
    /// runtime, and `Mutex` cannot be copied.
    private final class SynthesisFinishedFlag: Sendable {
        private let finished = Mutex(false)

        var isSet: Bool {
            finished.withLock { $0 }
        }

        func set() {
            finished.withLock { $0 = true }
        }
    }

    static func finishAfterCancelling(
        _ generationTask: Task<Void, Never>,
        finish: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        generationTask.cancel()
        return Task {
            await generationTask.value
            await finish()
        }
    }

    private static func makeSamplesStream(
        session: ModelSession,
        text: String,
        request: MLXTTSVoiceRequest,
        referenceTranscript: String,
        language: String
    ) throws -> AsyncThrowingStream<[Float], Error> {
        let model = session.model
        guard let referenceAudioURL = request.referenceAudioURL else {
            return model.generateSamplesStream(
                text: text,
                voice: request.voiceInstruction,
                refAudio: nil,
                refText: nil,
                language: language,
                streamingInterval: 1.0
            )
        }

        if let instruction = request.voiceInstruction {
            // Style plus clone must recondition per utterance; the instruct
            // path cannot reuse precomputed reference conditioning.
            let (_, referenceAudio) = try loadAudioArray(
                from: referenceAudioURL,
                sampleRate: model.sampleRate
            )
            return model.generateSamplesStream(
                text: text,
                voice: instruction,
                refAudio: referenceAudio,
                refText: referenceTranscript,
                language: language,
                streamingInterval: 1.0
            )
        }

        let conditioning = try session.cachedConditioning(
            referenceAudioURL: referenceAudioURL,
            transcript: referenceTranscript,
            language: language
        )
        let stream = model.generateStream(
            text: text,
            conditioning: conditioning,
            generationParameters: model.defaultGenerationParameters,
            streamingInterval: 1.0
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in stream {
                        try Task.checkCancellation()
                        if case .audio(let chunk) = event {
                            continuation.yield(chunk.asArray(Float.self))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
        let synthesisCompletion = synthesisCompletion
        let generation = UUID()
        unloadGeneration = generation
        let unloadTask = Task {
            if let synthesisCompletion {
                for await _ in synthesisCompletion {}
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

    /// Reopens the synthesis gate. The generation is checked so a teardown that
    /// lands after the next synthesis has started cannot release its gate and
    /// let two generations run through the model at once.
    private func finishSynthesis(generation: UUID) {
        guard synthesisGeneration == generation else { return }
        synthesisActive = false
        synthesisGeneration = nil
        activeGeneration = nil
        producerFinished = nil
        synthesisCompletionContinuation?.finish()
        synthesisCompletionContinuation = nil
        synthesisCompletion = nil
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
        configuration: MLXTTSConfiguration,
        accessPolicy: MLXTTSModelAccessPolicy,
        progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        guard let repository = Repo.ID(rawValue: configuration.repositoryID) else {
            throw MLXTTSRuntimeError.invalidRepositoryID(
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
            matching: snapshotPatterns(),
            localFilesOnly: localFilesOnly(for: accessPolicy),
            maxConcurrentDownloads: 4,
            progressHandler: progressHandler
        )
    }

    /// The patterns use fnmatch without FNM_PATHNAME, so `*` also matches the
    /// checkpoint's `speech_tokenizer/` subdirectory files.
    static func snapshotPatterns() -> [String] {
        ["*.safetensors", "*.json", "*.txt"]
    }

    static func localFilesOnly(
        for accessPolicy: MLXTTSModelAccessPolicy
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
}
