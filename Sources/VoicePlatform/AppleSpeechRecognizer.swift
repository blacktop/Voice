import AVFAudio
import CoreMedia
import Foundation
import Speech
import VoiceCore

public enum AppleSpeechRecognizerError: LocalizedError, Sendable {
    case localeUnsupported(String)
    case noCompatibleAudioFormat
    case notPrepared
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            "Apple Speech does not support \(identifier) on this Mac."
        case .noCompatibleAudioFormat:
            "Apple Speech did not provide a microphone-compatible audio format."
        case .notPrepared:
            "The speech recognizer has not finished preparing."
        case .alreadyRunning:
            "A speech recognition session is already running."
        }
    }
}

/// Persistent, truly incremental on-device transcription through SpeechAnalyzer.
public actor AppleSpeechRecognizer: SpeechRecognizing {
    private let requestedLocale: Locale
    private let microphone = MicrophoneInput()
    private var contextualStrings: [String] = []
    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var outputFormat: AVAudioFormat?
    private var inputConversion: AnalyzerInputConversion?
    private var resultTask: Task<Void, Never>?
    private var outputContinuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var sessionBuildTask: Task<Void, Error>?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        requestedLocale = locale
    }

    public func prepare(contextualStrings: [String]) async throws {
        self.contextualStrings = Array(contextualStrings.prefix(100))
        if analyzer == nil || transcriber == nil || outputFormat == nil {
            try await sessionRebuild().value
        }
        try await applyContextualStrings()
    }

    /// Returns the in-flight session build, or starts one. Coalescing keeps a
    /// background pre-build and a concurrent prepare() from constructing two
    /// sessions (and double-reserving the locale).
    private func sessionRebuild() -> Task<Void, Error> {
        if let sessionBuildTask {
            return sessionBuildTask
        }
        let task = Task {
            defer { sessionBuildTask = nil }
            try await self.buildSession()
        }
        sessionBuildTask = task
        return task
    }

    /// Pre-builds the next session off the hotkey path so a press only pays a
    /// context update. A failure here is retried, and surfaced, by the next
    /// prepare().
    private func scheduleSessionRebuild() {
        _ = sessionRebuild()
    }

    private func buildSession() async throws {
        guard
            let locale = await DictationTranscriber.supportedLocale(
                equivalentTo: requestedLocale
            )
        else {
            throw AppleSpeechRecognizerError.localeUnsupported(requestedLocale.identifier)
        }

        // No shortForm content hint: planning dictations run long, and the
        // short-form bias degrades recognition of extended speech.
        //
        // No etiquetteReplacements: it redacts words Apple classifies as
        // expletives into asterisks. Dictation must transcribe what was said
        // verbatim — the user is writing their own text, and silently altering
        // it is worse than any word it masks.
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }
        _ = try await AssetInventory.reserve(locale: locale)

        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        let options = SpeechAnalyzer.Options(
            priority: .high,
            modelRetention: .processLifetime
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        try await analyzer.setContext(context)

        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: microphone.naturalFormat
            )
        else {
            throw AppleSpeechRecognizerError.noCompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)
        // AnalyzerInput(buffer:) traps inside Speech.framework on macOS 27, so
        // buffers go through this converter instead. The factory is async, so
        // it has to be built here rather than in the synchronous microphone
        // start.
        if #available(macOS 27, *) {
            inputConversion = try await AnalyzerInputConversion.make(
                compatibleWith: [transcriber]
            )
        }
        self.transcriber = transcriber
        self.analyzer = analyzer
        outputFormat = format
    }

    private func applyContextualStrings() async throws {
        guard let analyzer else {
            throw AppleSpeechRecognizerError.notPrepared
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        try await analyzer.setContext(context)
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard let transcriber, let analyzer, let outputFormat else {
            throw AppleSpeechRecognizerError.notPrepared
        }
        guard resultTask == nil else {
            throw AppleSpeechRecognizerError.alreadyRunning
        }

        // Unbounded: dropping the oldest events would silently discard
        // finalized transcript text. Volume is bounded by speech rate.
        let outputPair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        outputContinuation = outputPair.continuation
        let continuation = outputPair.continuation
        let startedResultTask = Task {
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let range = result.range
                    let text = String(result.text.characters)
                    continuation.yield(
                        TranscriptEvent(
                            text: text,
                            startTime: range.start.seconds,
                            duration: range.duration.seconds,
                            isFinal: result.isFinal
                        )
                    )
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
                await self.handleRuntimeFailure(error)
            }
        }
        resultTask = startedResultTask

        do {
            let input = try await microphone.start(
                outputFormat: outputFormat,
                inputConversion: inputConversion,
                onFailure: { [weak self] error in
                    Task {
                        await self?.handleRuntimeFailure(error)
                    }
                }
            )
            // The microphone start now suspends while the input proves it
            // delivers audio. A cancel(), shutdown(), or runtime failure during
            // that window has already torn this session down, so the analyzer
            // must not be handed a stream it will never finish.
            guard resultTask == startedResultTask else {
                throw CancellationError()
            }
            try await analyzer.start(inputSequence: input)
        } catch {
            // Only the start that still owns the session may tear it down.
            // Losing the race above means another path already stopped this
            // microphone and analyzer, and the actor's fields may now describe
            // a newer session that must not be cleared here.
            let ownsSession = resultTask == startedResultTask
            startedResultTask.cancel()
            continuation.finish(throwing: error)
            if ownsSession {
                microphone.stop()
                await analyzer.cancelAndFinishNow()
            }
            await startedResultTask.value
            guard ownsSession else { throw CancellationError() }
            resultTask = nil
            outputContinuation = nil
            self.analyzer = nil
            self.transcriber = nil
            self.outputFormat = nil
            self.inputConversion = nil
            throw error
        }
        return outputPair.stream
    }

    public func stop() async throws {
        microphone.stop()
        guard let analyzer else { return }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
            resultTask = nil
            outputContinuation = nil
            // A finished analyzer closes its module result streams. Recreate
            // the session for the next capture; process-lifetime model retention
            // keeps the expensive system resources warm.
            self.analyzer = nil
            transcriber = nil
            outputFormat = nil
            inputConversion = nil
            scheduleSessionRebuild()
        } catch {
            await cancel()
            throw error
        }
    }

    public func cancel() async {
        await tearDown(scheduleRebuild: true)
    }

    public func shutdown() async {
        let buildTask = sessionBuildTask
        buildTask?.cancel()
        try? await buildTask?.value
        sessionBuildTask = nil
        await tearDown(scheduleRebuild: false)
    }

    private func tearDown(scheduleRebuild: Bool) async {
        microphone.stop()
        let task = resultTask
        task?.cancel()
        resultTask = nil
        outputContinuation?.finish()
        outputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        await task?.value
        self.analyzer = nil
        transcriber = nil
        outputFormat = nil
        inputConversion = nil
        if scheduleRebuild {
            scheduleSessionRebuild()
        }
    }

    private func handleRuntimeFailure(_ error: Error) async {
        guard resultTask != nil || outputContinuation != nil else { return }
        microphone.stop()
        let task = resultTask
        task?.cancel()
        resultTask = nil
        outputContinuation?.finish(throwing: error)
        outputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        self.analyzer = nil
        transcriber = nil
        outputFormat = nil
        inputConversion = nil
        scheduleSessionRebuild()
    }
}
