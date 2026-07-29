import AVFAudio
import Foundation
import VoiceCore
import XCTest

@testable import VoiceMLX

final class MLXSpeechRecognizerTests: XCTestCase {
    func testCatalogPinsModelSnapshots() {
        XCTAssertEqual(
            MLXSpeechModel.qwenSmall.revision,
            "89e96d92ba34aca20b3e29fb10cc284097d1219f"
        )
        XCTAssertEqual(
            MLXSpeechModel.qwenLarge.revision,
            "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
        )
        XCTAssertEqual(
            MLXSpeechModel.graniteCoding.revision,
            "371e6922faffba916e983e9c083049ad44536e94"
        )
        XCTAssertEqual(
            MLXSpeechModel.cohereAccuracy.revision,
            "d1f843476f84846e6fe7aa58a6033f17882f0ec9"
        )
        XCTAssertEqual(
            MLXSpeechModel.parakeetFast.revision,
            "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
        )
        XCTAssertEqual(
            MLXSpeechModel.parakeetFast.repositoryID,
            "mlx-community/parakeet-tdt-0.6b-v3"
        )
        XCTAssertEqual(MLXSpeechModel.qwenSmall.runtimeArchitecture, .qwen3)
        XCTAssertEqual(MLXSpeechModel.qwenLarge.runtimeArchitecture, .qwen3)
        XCTAssertEqual(MLXSpeechModel.graniteCoding.runtimeArchitecture, .granite4)
        XCTAssertEqual(
            MLXSpeechModel.cohereAccuracy.runtimeArchitecture,
            .cohereTranscribe
        )
        XCTAssertEqual(
            MLXSpeechModel.parakeetFast.runtimeArchitecture,
            .parakeetTDT
        )
    }

    func testBatchRecognitionYieldsOneFinalTranscriptAndMetrics() async throws {
        let capture = TestCapture(samples: Array(repeating: 0.25, count: 1_600))
        let decoder = TestDecoder(text: "Use AXUIElement and CGEvent post to PID.")
        let metrics = MetricsRecorder()
        let recognizer = MLXSpeechRecognizer(
            model: .qwenSmall,
            capture: capture,
            decoder: decoder,
            onMetrics: { value in
                metrics.record(value)
            }
        )

        try await recognizer.prepare(contextualStrings: ["AXUIElement", "CGEvent.postToPid"])
        let stream = try await recognizer.start()
        try await recognizer.stop()

        var events: [TranscriptEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.text, "Use AXUIElement and CGEvent post to PID.")
        XCTAssertEqual(event.duration, 0.1, accuracy: 0.000_1)
        XCTAssertTrue(event.isFinal)
        let context = await decoder.receivedContext
        XCTAssertEqual(context, ["AXUIElement", "CGEvent.postToPid"])
        let recorded = try XCTUnwrap(metrics.first)
        XCTAssertEqual(recorded.model, .qwenSmall)
        XCTAssertEqual(recorded.audioDuration, 0.1, accuracy: 0.000_1)
    }

    func testStartRequiresPreparedModel() async {
        let recognizer = MLXSpeechRecognizer(
            model: .qwenSmall,
            capture: TestCapture(samples: []),
            decoder: TestDecoder(text: "unused")
        )

        do {
            _ = try await recognizer.start()
            XCTFail("Expected start to reject an unloaded model")
        } catch let error as MLXSpeechRecognizerError {
            guard case .notPrepared = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOptInSilenceGateRejectsShortNearSilentCapture() async throws {
        let capture = TestCapture(samples: Array(repeating: 0.001, count: 16_000))
        let recognizer = MLXSpeechRecognizer(
            model: .qwenSmall,
            capture: capture,
            decoder: TestDecoder(text: "hallucinated text"),
            shouldSkipSilentShortAudio: { true }
        )
        try await recognizer.prepare(contextualStrings: [])
        _ = try await recognizer.start()

        do {
            try await recognizer.stop()
            XCTFail("Expected near-silent audio to be rejected")
        } catch let error as MLXSpeechRecognizerError {
            guard case .emptyAudio = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancelStopsCaptureAndFinishesStreamWithoutText() async throws {
        let capture = TestCapture(samples: Array(repeating: 0, count: 1_600))
        let decoder = TestDecoder(text: "must not escape")
        let recognizer = MLXSpeechRecognizer(
            model: .qwenSmall,
            capture: capture,
            decoder: decoder
        )

        try await recognizer.prepare(contextualStrings: [])
        let stream = try await recognizer.start()
        await recognizer.cancel()

        var eventCount = 0
        do {
            for try await _ in stream {
                eventCount += 1
            }
        } catch {
            XCTFail("Cancellation should finish cleanly: \(error)")
        }
        XCTAssertEqual(eventCount, 0)
        XCTAssertTrue(capture.wasCancelled)
    }

    func testCancelWaitsForInFlightInferenceToExit() async throws {
        let decoder = BlockingDecoder()
        let recognizer = MLXSpeechRecognizer(
            model: .qwenSmall,
            capture: TestCapture(samples: Array(repeating: 0.25, count: 1_600)),
            decoder: decoder
        )
        try await recognizer.prepare(contextualStrings: [])
        _ = try await recognizer.start()

        let stopTask = Task { try await recognizer.stop() }
        await decoder.waitUntilStarted()
        let cancelCompleted = CompletionProbe()
        let cancelTask = Task {
            await recognizer.cancel()
            cancelCompleted.markCompleted()
        }
        await decoder.waitUntilCancellationWasObserved()

        XCTAssertFalse(
            cancelCompleted.isCompleted,
            "cancel() returned while the decoder was still running"
        )
        await decoder.finish()
        await cancelTask.value
        XCTAssertTrue(cancelCompleted.isCompleted)

        do {
            try await stopTask.value
            XCTFail("Expected the cancelled inference to stop")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected inference error: \(error)")
        }
    }

    func testCaptureFailureIsPreservedForStop() async throws {
        let capture = FailureCapture()
        let recognizer = MLXSpeechRecognizer(
            model: .qwenSmall,
            capture: capture,
            decoder: TestDecoder(text: "unused")
        )
        try await recognizer.prepare(contextualStrings: [])
        let stream = try await recognizer.start()

        capture.fail(with: MLXSpeechRecognizerError.audioDeviceChanged)
        do {
            for try await _ in stream {}
            XCTFail("Expected the transcript stream to report the capture failure")
        } catch let error as MLXSpeechRecognizerError {
            guard case .audioDeviceChanged = error else {
                return XCTFail("Unexpected stream error: \(error)")
            }
        }

        do {
            try await recognizer.stop()
            XCTFail("Expected stop() to preserve the capture failure")
        } catch let error as MLXSpeechRecognizerError {
            guard case .audioDeviceChanged = error else {
                return XCTFail("Unexpected stop error: \(error)")
            }
        }
    }

    func testMonoSampleExtractionCopiesFloatBuffer() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)
        )
        buffer.frameLength = 3
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        channel[0] = -0.5
        channel[1] = 0
        channel[2] = 0.75

        XCTAssertEqual(
            try MLXAudioCapture.monoSamples(from: buffer),
            [-0.5, 0, 0.75]
        )
    }
}

private final class TestCapture: MLXAudioCapturing, @unchecked Sendable {
    private let samples: [Float]
    private(set) var wasCancelled = false
    private var isRunning = false

    init(samples: [Float]) {
        self.samples = samples
    }

    func start(onFailure _: @escaping @Sendable (Error) -> Void) async throws {
        isRunning = true
    }

    func stop() throws -> MLXCapturedAudio {
        guard isRunning else {
            throw MLXSpeechRecognizerError.notRunning
        }
        isRunning = false
        return MLXCapturedAudio(samples: samples, sampleRate: 16_000)
    }

    func cancel() {
        wasCancelled = true
        isRunning = false
    }
}

private actor TestDecoder: MLXSpeechDecoding {
    private let text: String
    private(set) var receivedContext: [String] = []

    init(text: String) {
        self.text = text
    }

    func prepare() async throws {}

    func transcribe(
        samples _: [Float],
        contextualStrings: [String]
    ) async throws -> MLXDecodingResult {
        receivedContext = contextualStrings
        return MLXDecodingResult(
            text: text,
            inferenceDuration: 0.025,
            peakMemoryGB: 1.25
        )
    }

    func unload() async {}
}

private actor BlockingDecoder: MLXSpeechDecoding {
    private let started = AsyncGate()
    private let cancellationObserved = AsyncGate()
    private let release = AsyncGate()

    func waitUntilStarted() async {
        await started.wait()
    }

    func waitUntilCancellationWasObserved() async {
        await cancellationObserved.wait()
    }

    func finish() async {
        await release.open()
    }

    func prepare() async throws {}

    func transcribe(
        samples _: [Float],
        contextualStrings _: [String]
    ) async throws -> MLXDecodingResult {
        await started.open()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            Task { await self.cancellationObserved.open() }
        }
        try Task.checkCancellation()
        return MLXDecodingResult(
            text: "must not escape",
            inferenceDuration: 0.025,
            peakMemoryGB: 1.25
        )
    }

    func unload() async {}
}

private final class FailureCapture: MLXAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var isRunning = false

    func start(onFailure: @escaping @Sendable (Error) -> Void) async throws {
        lock.withLock {
            failureHandler = onFailure
            isRunning = true
        }
    }

    func stop() throws -> MLXCapturedAudio {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else {
            throw MLXSpeechRecognizerError.notRunning
        }
        isRunning = false
        return MLXCapturedAudio(samples: [0], sampleRate: 16_000)
    }

    func cancel() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    func fail(with error: Error) {
        lock.lock()
        let handler = failureHandler
        failureHandler = nil
        lock.unlock()
        handler?(error)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

private final class MetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MLXTranscriptionMetrics] = []

    var first: MLXTranscriptionMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return values.first
    }

    func record(_ metrics: MLXTranscriptionMetrics) {
        lock.lock()
        defer { lock.unlock() }
        values.append(metrics)
    }
}
