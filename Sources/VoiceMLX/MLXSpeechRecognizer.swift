import Foundation
import VoiceCore

public actor MLXSpeechRecognizer: SpeechRecognizing {
    public typealias PreparationHandler = @Sendable (MLXModelPreparationStage) -> Void
    public typealias MetricsHandler = @Sendable (MLXTranscriptionMetrics) -> Void

    /// Voice's directory in Application Support. Shared state that is not a
    /// model — the speech lock, for instance — belongs here rather than inside
    /// the model store.
    public nonisolated static var containerURL: URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidates = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        let base = candidates.first ?? fallback
        return base.appendingPathComponent("io.blacktop.Voice", isDirectory: true)
    }

    public nonisolated static var modelStoreURL: URL {
        containerURL.appendingPathComponent("MLXModels", isDirectory: true)
    }

    private let model: MLXSpeechModel
    private let capture: any MLXAudioCapturing
    private let decoder: any MLXSpeechDecoding
    private let onMetrics: MetricsHandler
    private let shouldSkipSilentShortAudio: @Sendable () -> Bool
    private var contextualStrings: [String] = []
    private var isPrepared = false
    private var isCapturing = false
    private var generation: UUID?
    private var outputContinuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var inferenceTask: Task<MLXDecodingResult, Error>?
    private var pendingCaptureError: Error?

    public init(
        model: MLXSpeechModel,
        onPreparation: @escaping PreparationHandler = { _ in },
        shouldSkipSilentShortAudio: @escaping @Sendable () -> Bool = { false },
        onMetrics: @escaping MetricsHandler = { _ in }
    ) {
        self.model = model
        capture = MLXAudioCapture()
        decoder = NativeMLXSpeechDecoder(
            model: model,
            onPreparation: onPreparation
        )
        self.onMetrics = onMetrics
        self.shouldSkipSilentShortAudio = shouldSkipSilentShortAudio
    }

    init(
        model: MLXSpeechModel,
        capture: any MLXAudioCapturing,
        decoder: any MLXSpeechDecoding,
        shouldSkipSilentShortAudio: @escaping @Sendable () -> Bool = { false },
        onMetrics: @escaping MetricsHandler = { _ in }
    ) {
        self.model = model
        self.capture = capture
        self.decoder = decoder
        self.onMetrics = onMetrics
        self.shouldSkipSilentShortAudio = shouldSkipSilentShortAudio
    }

    public func prepare(contextualStrings: [String]) async throws {
        self.contextualStrings = Array(contextualStrings.prefix(100))
        try await decoder.prepare()
        isPrepared = true
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard isPrepared else {
            throw MLXSpeechRecognizerError.notPrepared
        }
        guard !isCapturing, inferenceTask == nil else {
            throw MLXSpeechRecognizerError.alreadyRunning
        }
        pendingCaptureError = nil

        let pair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        // Claimed before the capture is awaited: start() now suspends while the
        // engine proves it delivers audio, and a cancel() landing in that window
        // must win instead of being overwritten when this resumes.
        let generation = UUID()
        self.generation = generation
        outputContinuation = pair.continuation
        isCapturing = true
        do {
            try await capture.start { [weak self] error in
                Task {
                    await self?.handleCaptureFailure(error, generation: generation)
                }
            }
        } catch {
            guard self.generation == generation else { throw takeoverError() }
            finish(generation: generation, throwing: error)
            isCapturing = false
            throw error
        }
        guard self.generation == generation else {
            capture.cancel()
            throw takeoverError()
        }
        return pair.stream
    }

    /// Why a `start()` that lost its generation during the capture-readiness
    /// wait ended: a capture failure has an error worth showing, while a
    /// `cancel()` is a plain cancellation. Either beats the teardown error the
    /// aborted capture produced, which describes the teardown, not the cause.
    private func takeoverError() -> Error {
        if let pendingCaptureError {
            self.pendingCaptureError = nil
            return pendingCaptureError
        }
        return CancellationError()
    }

    public func stop() async throws {
        if let pendingCaptureError {
            self.pendingCaptureError = nil
            throw pendingCaptureError
        }
        guard isCapturing, let activeGeneration = generation else {
            throw MLXSpeechRecognizerError.notRunning
        }
        isCapturing = false

        let audio: MLXCapturedAudio
        do {
            audio = try capture.stop()
        } catch {
            finish(generation: activeGeneration, throwing: error)
            throw error
        }
        guard audio.duration >= 0.08 else {
            let error = MLXSpeechRecognizerError.emptyAudio
            finish(generation: activeGeneration, throwing: error)
            throw error
        }
        if shouldSkipSilentShortAudio(),
            MLXShortAudioSilenceAssessment.isSilent(
                samples: audio.samples,
                sampleRate: audio.sampleRate
            )
        {
            let error = MLXSpeechRecognizerError.emptyAudio
            finish(generation: activeGeneration, throwing: error)
            throw error
        }

        let context = contextualStrings
        let decoder = decoder
        let task = Task {
            try await decoder.transcribe(
                samples: audio.samples,
                contextualStrings: context
            )
        }
        inferenceTask = task
        do {
            let result = try await task.value
            try Task.checkCancellation()
            guard generation == activeGeneration else {
                throw CancellationError()
            }
            guard !result.text.isEmpty else {
                throw MLXSpeechRecognizerError.modelOutputMissing
            }

            outputContinuation?.yield(
                TranscriptEvent(
                    text: result.text,
                    startTime: 0,
                    duration: audio.duration,
                    isFinal: true
                )
            )
            onMetrics(
                MLXTranscriptionMetrics(
                    model: model,
                    audioDuration: audio.duration,
                    inferenceDuration: result.inferenceDuration,
                    peakMemoryGB: result.peakMemoryGB
                )
            )
            finish(generation: activeGeneration)
        } catch {
            finish(generation: activeGeneration, throwing: error)
            throw error
        }
    }

    public func cancel() async {
        let task = inferenceTask
        generation = nil
        isCapturing = false
        pendingCaptureError = nil
        capture.cancel()
        task?.cancel()
        outputContinuation?.finish()
        outputContinuation = nil
        _ = await task?.result
        inferenceTask = nil
    }

    public func shutdown() async {
        await cancel()
        isPrepared = false
        await decoder.unload()
    }

    private func handleCaptureFailure(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        capture.cancel()
        isCapturing = false
        pendingCaptureError = error
        finish(generation: generation, throwing: error)
    }

    private func finish(generation: UUID, throwing error: Error? = nil) {
        guard self.generation == generation else { return }
        self.generation = nil
        inferenceTask = nil
        if let error {
            outputContinuation?.finish(throwing: error)
        } else {
            outputContinuation?.finish()
        }
        outputContinuation = nil
    }
}
