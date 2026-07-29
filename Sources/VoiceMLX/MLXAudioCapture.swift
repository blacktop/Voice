import AVFAudio
import Foundation
import VoiceCore

struct MLXCapturedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

protocol MLXAudioCapturing: Sendable {
    func start(onFailure: @escaping @Sendable (Error) -> Void) async throws
    func stop() throws -> MLXCapturedAudio
    func cancel()
}

/// Captures raw microphone buffers only in memory and converts them to the
/// 16 kHz mono Float32 representation expected by the selected ASR model.
final class MLXAudioCapture: MLXAudioCapturing, @unchecked Sendable {
    private static let unspecifiedCoreAudioErrorCode = 2_003_329_396

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

    private var engine = AVAudioEngine()
    private let stateCondition = NSCondition()
    private let sampleRate: Double
    private let maximumDuration: TimeInterval
    private var activeGeneration: UUID?
    private var isStopping = false
    private var inFlightConversions = 0
    private var chunks: [[Float]] = []
    private var sampleCount = 0
    private var converter: AVAudioConverter?
    /// Signals the first delivered buffer to `start`. Finished on teardown so a
    /// `cancel()` racing startup ends the wait instead of paying its timeout,
    /// and finished on success so the tap stops feeding a stream nobody reads.
    private var readinessContinuation: AsyncStream<Void>.Continuation?
    private var terminalError: Error?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var tapInstalled = false
    private var isEngineStarted = false
    private var configurationChangeObserver: (any NSObjectProtocol)?

    init(sampleRate: Double = 16_000, maximumDuration: TimeInterval = 600) {
        self.sampleRate = sampleRate
        self.maximumDuration = maximumDuration
        observeConfigurationChanges()
    }

    private func observeConfigurationChanges() {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
        let observedEngine = engine
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange(from: observedEngine)
        }
    }

    deinit {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
    }

    func start(onFailure: @escaping @Sendable (Error) -> Void) async throws {
        cancel()
        let readiness = try Self.startWithOneRecovery(
            start: {
                try self.startAttempt(onFailure: onFailure)
            },
            recover: replaceEngine
        )
        let isReady = await AudioCaptureReadiness.wait(
            for: readiness,
            timeout: AudioCaptureReadiness.startupTimeout
        )
        finishReadiness()
        guard isReady else {
            cancel()
            try Task.checkCancellation()
            throw MLXSpeechRecognizerError.audioEngineUnavailable
        }
    }

    private func finishReadiness() {
        let continuation = withStateLock { () -> AsyncStream<Void>.Continuation? in
            let captured = readinessContinuation
            readinessContinuation = nil
            return captured
        }
        continuation?.finish()
    }

    private func startAttempt(
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws -> AsyncStream<Void> {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw MLXSpeechRecognizerError.invalidAudioFormat
        }
        converter.downmix = inputFormat.channelCount > outputFormat.channelCount
        let readiness = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        let generation = UUID()
        withStateLock {
            activeGeneration = generation
            isStopping = false
            chunks.removeAll(keepingCapacity: true)
            sampleCount = 0
            self.converter = converter
            readinessContinuation = readiness.continuation
            terminalError = nil
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
            beginStopping()
            removeTapAndStopEngine()
            waitForConversionsToFinish()
            clearState()
            throw error
        }
        withStateLock { isEngineStarted = true }
        return readiness.stream
    }

    private func replaceEngine() {
        withStateLock { engine = AVAudioEngine() }
        observeConfigurationChanges()
    }

    static func startWithOneRecovery<T>(
        start: () throws -> T,
        recover: () -> Void
    ) throws -> T {
        do {
            return try start()
        } catch {
            guard isUnspecifiedCoreAudioStartError(error) else { throw error }
            recover()
            do {
                return try start()
            } catch {
                if isUnspecifiedCoreAudioStartError(error) {
                    throw MLXSpeechRecognizerError.audioEngineUnavailable
                }
                throw error
            }
        }
    }

    static func isUnspecifiedCoreAudioStartError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "com.apple.coreaudio.avfaudio"
            && error.code == unspecifiedCoreAudioErrorCode
    }

    func stop() throws -> MLXCapturedAudio {
        beginStopping()
        removeTapAndStopEngine()
        waitForConversionsToFinish()
        let state = withStateLock { () -> ([[Float]], Error?) in
            guard activeGeneration != nil else {
                clearStateLocked()
                return ([], MLXSpeechRecognizerError.notRunning)
            }
            let captured = chunks
            let error = terminalError
            clearStateLocked()
            return (captured, error)
        }
        if let error = state.1 {
            throw error
        }

        let count = state.0.reduce(into: 0) { $0 += $1.count }
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for chunk in state.0 {
            samples.append(contentsOf: chunk)
        }
        return MLXCapturedAudio(samples: samples, sampleRate: sampleRate)
    }

    func cancel() {
        beginStopping()
        removeTapAndStopEngine()
        waitForConversionsToFinish()
        clearState()
    }

    private func consume(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        generation: UUID
    ) {
        let activeConverter = withStateLock { () -> AVAudioConverter? in
            guard activeGeneration == generation, terminalError == nil, !isStopping,
                let converter
            else {
                return nil
            }
            inFlightConversions += 1
            return converter
        }
        guard let activeConverter else { return }
        defer { finishConversion() }

        do {
            let converted = try Self.convert(
                buffer,
                using: activeConverter,
                outputFormat: outputFormat
            )
            let samples = try Self.monoSamples(from: converted)
            guard !samples.isEmpty else { return }
            append(samples, generation: generation)
        } catch {
            fail(generation: generation, error: error)
        }
    }

    private func append(_ samples: [Float], generation: UUID) {
        let limit = Int(maximumDuration * sampleRate)
        let failure = withStateLock { () -> ((@Sendable (Error) -> Void)?, Error?) in
            guard activeGeneration == generation, terminalError == nil else {
                return (nil, nil)
            }
            guard sampleCount + samples.count <= limit else {
                let error = MLXSpeechRecognizerError.audioDurationLimit(maximumDuration)
                terminalError = error
                let handler = failureHandler
                failureHandler = nil
                return (handler, error)
            }
            chunks.append(samples)
            sampleCount += samples.count
            return (nil, nil)
        }
        if let error = failure.1 {
            failure.0?(error)
        }
    }

    // A change notification can be delivered on the CoreAudio thread while a
    // failed start attempt is being retried on a replacement engine, or after
    // the observed engine has been discarded; only a change on the currently
    // started engine may fail the session.
    private func handleConfigurationChange(from notifiedEngine: AVAudioEngine) {
        let error = MLXSpeechRecognizerError.audioDeviceChanged
        let handler = withStateLock { () -> (@Sendable (Error) -> Void)? in
            guard
                Self.shouldFailSessionOnConfigurationChange(
                    notifiedEngineIsCurrent: notifiedEngine === engine,
                    isEngineStarted: isEngineStarted,
                    isStopping: isStopping,
                    hasActiveGeneration: activeGeneration != nil,
                    hasTerminalError: terminalError != nil
                )
            else { return nil }
            terminalError = error
            let handler = failureHandler
            failureHandler = nil
            return handler
        }
        handler?(error)
    }

    /// A configuration-change delivery may only fail the session for the
    /// currently started engine: deliveries racing a failed start attempt
    /// (state exists but the engine never started) or arriving for an engine
    /// that recovery already replaced must be ignored, or they cancel a
    /// session that is capturing fine.
    static func shouldFailSessionOnConfigurationChange(
        notifiedEngineIsCurrent: Bool,
        isEngineStarted: Bool,
        isStopping: Bool,
        hasActiveGeneration: Bool,
        hasTerminalError: Bool
    ) -> Bool {
        notifiedEngineIsCurrent && isEngineStarted && !isStopping
            && hasActiveGeneration && !hasTerminalError
    }

    private func fail(generation: UUID, error: Error) {
        let handler = withStateLock { () -> (@Sendable (Error) -> Void)? in
            guard activeGeneration == generation, terminalError == nil else { return nil }
            terminalError = error
            let handler = failureHandler
            failureHandler = nil
            return handler
        }
        handler?(error)
    }

    private func beginStopping() {
        withStateLock {
            isStopping = true
            failureHandler = nil
        }
    }

    private func finishConversion() {
        withStateLock {
            if inFlightConversions > 0 {
                inFlightConversions -= 1
            }
            if inFlightConversions == 0 {
                stateCondition.broadcast()
            }
        }
    }

    private func waitForConversionsToFinish() {
        stateCondition.lock()
        while inFlightConversions > 0 {
            stateCondition.wait()
        }
        stateCondition.unlock()
    }

    private func removeTapAndStopEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func clearState() {
        withStateLock {
            clearStateLocked()
        }
    }

    private func clearStateLocked() {
        activeGeneration = nil
        isStopping = false
        isEngineStarted = false
        chunks.removeAll(keepingCapacity: false)
        sampleCount = 0
        converter = nil
        readinessContinuation?.finish()
        readinessContinuation = nil
        terminalError = nil
        failureHandler = nil
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateCondition.lock()
        defer { stateCondition.unlock() }
        return try body()
    }

    static func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.channelCount == 1,
            let channel = buffer.floatChannelData?.pointee
        else {
            throw MLXSpeechRecognizerError.invalidAudioFormat
        }
        return Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            )
        )
    }

    static func convert(
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
            throw MLXSpeechRecognizerError.invalidAudioFormat
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
            throw MLXSpeechRecognizerError.invalidAudioFormat
        }
        return output
    }
}
