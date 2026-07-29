import AVFAudio
import Foundation
import Speech
import VoiceCore

enum MicrophoneInputError: LocalizedError {
    case deviceConfigurationChanged
    case invalidInputFormat
    case noAudioDelivered
    case unavailableConverter
    case unavailableOutputBuffer

    var errorDescription: String? {
        switch self {
        case .deviceConfigurationChanged:
            "The audio input device changed mid-capture. Hold the hotkey to try again."
        case .invalidInputFormat:
            "The selected microphone did not provide a usable audio format."
        case .noAudioDelivered:
            "The selected microphone started but did not deliver audio. Check or reconnect "
                + "the input device, then hold the dictation key again."
        case .unavailableConverter:
            "Voice could not create the required on-device audio converter."
        case .unavailableOutputBuffer:
            "Voice could not allocate an audio conversion buffer."
        }
    }
}

/// Wraps the macOS 27 `AnalyzerInputConverter`, used instead of the direct
/// `AnalyzerInput(buffer:)` path because that initializer traps inside
/// Speech.framework on macOS 27 (filed with Apple; the initializer itself is
/// not deprecated — only `AnalyzerInput.buffer` is).
/// Swift forbids `@available` on stored properties, so the converter
/// is held as `AnyObject` and cast at each use. The lock serializes the capture
/// thread's `convert` against `flush` on stop, since the converter buffers
/// samples across calls.
///
/// Only the async `AnalyzerInputConverter.converter(compatibleWith:)` factory
/// may be used: the synchronous `init(analyzerFormat:)` never returns on
/// macOS 27 beta 4.
final class AnalyzerInputConversion: @unchecked Sendable {
    private let converter: AnyObject
    private let lock = NSLock()

    @available(macOS 27, *)
    private init(converter: AnalyzerInputConverter) {
        self.converter = converter
    }

    @available(macOS 27, *)
    static func make(compatibleWith modules: [any SpeechModule]) async throws
        -> AnalyzerInputConversion
    {
        AnalyzerInputConversion(
            converter: try await AnalyzerInputConverter.converter(compatibleWith: modules)
        )
    }

    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput] {
        guard #available(macOS 27, *), let converter = converter as? AnalyzerInputConverter
        else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return try converter.convert(buffer, at: time)
    }

    /// Drains samples the converter is holding for resampling. Without this the
    /// tail of a short utterance never reaches the analyzer.
    func flush() throws -> [AnalyzerInput] {
        guard #available(macOS 27, *), let converter = converter as? AnalyzerInputConverter
        else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return try converter.flush()
    }
}

/// Owns one AVAudioEngine session. Access is serialized by AppleSpeechRecognizer.
final class MicrophoneInput: @unchecked Sendable {
    /// AVAudioConverter invokes its input block synchronously. Wrapping the
    /// non-Sendable AVAudioPCMBuffer records that one-shot lifetime invariant.
    private final class OneShotConverterInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var activeGeneration: UUID?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var converter: AVAudioConverter?
    private var inputConversion: AnalyzerInputConversion?
    /// Signals the first delivered buffer to `start`. Finished on teardown so a
    /// `stop()` racing startup ends the wait instead of paying its timeout, and
    /// finished on success so the tap stops feeding a stream nobody reads.
    private var readinessContinuation: AsyncStream<Void>.Continuation?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var tapInstalled = false
    private var configurationChangeObserver: (any NSObjectProtocol)?

    init() {
        // An input-device or sample-rate change stops the engine without any
        // error reaching the tap; surface it instead of listening to a dead mic.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
    }

    var naturalFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// - Parameter inputConversion: the macOS 27 converter, built by the caller
    ///   in an async context. When nil, the legacy AVAudioConverter path runs.
    func start(
        outputFormat: AVAudioFormat,
        inputConversion: AnalyzerInputConversion?,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws -> AsyncThrowingStream<AnalyzerInput, Error> {
        stop()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneInputError.invalidInputFormat
        }

        // Unbounded: AnalyzerInput carries no time codes (the analyzer appends
        // each buffer after the last), so dropping the oldest buffers silently
        // splices the audio timeline and corrupts recognition of long speech.
        // Memory is bounded by capture length (~1.4 KB per converted buffer).
        let streamPair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let generation = UUID()

        // The macOS 27 converter performs the format conversion itself, so the
        // legacy AVAudioConverter is only built when it is absent.
        let needsConversion =
            inputConversion == nil && !Self.formatsMatch(inputFormat, outputFormat)
        let converter: AVAudioConverter?
        if needsConversion {
            guard let created = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw MicrophoneInputError.unavailableConverter
            }
            created.downmix = inputFormat.channelCount > outputFormat.channelCount
            converter = created
        } else {
            converter = nil
        }
        let readiness = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withStateLock {
            activeGeneration = generation
            continuation = streamPair.continuation
            self.converter = converter
            self.inputConversion = inputConversion
            readinessContinuation = readiness.continuation
            failureHandler = onFailure
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            readiness.continuation.yield(())
            self?.consume(
                buffer,
                outputFormat: outputFormat,
                generation: generation
            )
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            finish(generation: generation, throwing: error)
            throw error
        }
        let isReady = await AudioCaptureReadiness.wait(
            for: readiness.stream,
            timeout: AudioCaptureReadiness.startupTimeout
        )
        finishReadiness()
        guard isReady else {
            stop()
            try Task.checkCancellation()
            throw MicrophoneInputError.noAudioDelivered
        }
        return streamPair.stream
    }

    private func finishReadiness() {
        let continuation = withStateLock { () -> AsyncStream<Void>.Continuation? in
            let captured = readinessContinuation
            readinessContinuation = nil
            return captured
        }
        continuation?.finish()
    }

    func stop() {
        // Stop delivery before touching state: a buffer already inside
        // consume() has copied the continuation and conversion out from under
        // the lock, so clearing state first would let its convert() run after
        // the flush below and drop the tail it produced.
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let state = withStateLock {
            () -> (
                AsyncThrowingStream<AnalyzerInput, Error>.Continuation?,
                AnalyzerInputConversion?
            ) in
            activeGeneration = nil
            converter = nil
            failureHandler = nil
            readinessContinuation?.finish()
            readinessContinuation = nil
            let captured = self.continuation
            self.continuation = nil
            let conversion = inputConversion
            inputConversion = nil
            return (captured, conversion)
        }
        // The drained tail must reach the analyzer before the stream finishes
        // or the end of a short utterance is lost.
        if let conversion = state.1, let continuation = state.0 {
            for input in (try? conversion.flush()) ?? [] {
                continuation.yield(input)
            }
        }
        state.0?.finish()
    }

    private func consume(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        generation: UUID
    ) {
        let state = withStateLock {
            () -> (
                AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
                AVAudioConverter?,
                AnalyzerInputConversion?
            )? in
            guard activeGeneration == generation, let continuation else { return nil }
            return (continuation, converter, inputConversion)
        }
        guard let (continuation, converter, inputConversion) = state else { return }

        do {
            if let inputConversion {
                for input in try inputConversion.convert(buffer, at: nil) {
                    continuation.yield(input)
                }
                return
            }
            let output: AVAudioPCMBuffer
            if let converter {
                output = try Self.convert(
                    buffer,
                    using: converter,
                    outputFormat: outputFormat
                )
            } else {
                output = try Self.copy(buffer)
            }
            if let input = Self.makeAnalyzerInput(buffer: output) {
                continuation.yield(input)
            }
        } catch {
            finish(generation: generation, throwing: error)
        }
    }

    /// Converted live buffers are contiguous in converter-output order. Leaving
    /// the time code nil tells SpeechAnalyzer to append each one after the prior
    /// buffer instead of reusing a source-clock timestamp that conversion
    /// rounding or priming may make overlap the converted audio.
    static func makeAnalyzerInput(buffer: AVAudioPCMBuffer) -> AnalyzerInput? {
        guard buffer.frameLength > 0 else { return nil }
        return AnalyzerInput(buffer: buffer)
    }

    private func handleConfigurationChange() {
        let generation = withStateLock { activeGeneration }
        guard let generation else { return }
        finish(
            generation: generation,
            throwing: MicrophoneInputError.deviceConfigurationChanged
        )
    }

    private func finish(generation: UUID, throwing error: Error) {
        let state = withStateLock {
            () -> (
                AsyncThrowingStream<AnalyzerInput, Error>.Continuation?,
                (@Sendable (Error) -> Void)?
            ) in
            guard activeGeneration == generation else {
                return (nil, nil)
            }
            activeGeneration = nil
            converter = nil
            readinessContinuation?.finish()
            readinessContinuation = nil
            let captured = self.continuation
            self.continuation = nil
            let handler = failureHandler
            failureHandler = nil
            return (captured, handler)
        }
        state.0?.finish(throwing: error)
        state.1?(error)
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func copy(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
            )
        else {
            throw MicrophoneInputError.unavailableOutputBuffer
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData,
                let destinationData = destinationBuffer.mData
            else { continue }
            memcpy(
                destinationData,
                sourceData,
                min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
            )
        }
        return copy
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 32
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else {
            throw MicrophoneInputError.unavailableOutputBuffer
        }

        let input = OneShotConverterInput(buffer: source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            input.next(status: inputStatus)
        }
        if let conversionError {
            throw conversionError
        }
        if status == .error {
            throw MicrophoneInputError.unavailableConverter
        }
        return output
    }
}
