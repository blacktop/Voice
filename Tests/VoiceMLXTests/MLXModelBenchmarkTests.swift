import Foundation
import VoiceMLXRuntime
import XCTest

@testable import VoiceMLX

final class MLXModelBenchmarkTests: XCTestCase {
    func testOneCaptureRunsLocalModelsSequentiallyAndContinuesAfterFailure() async throws {
        let samples = Array(repeating: Float(0.25), count: 1_600)
        let capture = BenchmarkCapture(samples: samples)
        let log = BenchmarkLog()
        let policies = Locked<[MLXASRModelAccessPolicy]>([])
        let small = BenchmarkDecoder(model: .qwenSmall, text: "small", log: log)
        let large = BenchmarkDecoder(model: .qwenLarge, text: nil, log: log)
        let granite = BenchmarkDecoder(model: .graniteCoding, text: "granite", log: log)
        let benchmark = MLXModelBenchmark(
            capture: capture,
            modelProvider: { [.graniteCoding, .qwenLarge, .qwenSmall] },
            decoderFactory: { model, policy in
                policies.update { $0.append(policy) }
                return switch model {
                case .qwenSmall: small
                case .qwenLarge: large
                case .graniteCoding: granite
                case .cohereAccuracy, .parakeetFast: small
                }
            }
        )

        let available = try await benchmark.startRecording()
        let context = (0..<120).map { "term-\($0)" }
        let results = try await benchmark.stopAndCompare(
            models: available,
            contextualStrings: context
        )

        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(results.map(\.model.rawValue), available.map(\.rawValue))
        XCTAssertEqual(results[0].transcript, "small")
        XCTAssertNotNil(results[1].errorDescription)
        XCTAssertEqual(results[2].transcript, "granite")
        XCTAssertTrue(
            policies.value.allSatisfy { policy in
                if case .localOnly = policy { return true }
                return false
            })
        let snapshot = await log.snapshot()
        XCTAssertEqual(
            snapshot.events,
            [
                "prepare-qwenSmall", "transcribe-qwenSmall", "unload-qwenSmall",
                "prepare-qwenLarge", "transcribe-qwenLarge", "unload-qwenLarge",
                "prepare-graniteCoding", "transcribe-graniteCoding",
                "unload-graniteCoding",
            ]
        )
        XCTAssertEqual(snapshot.inputs.count, 3)
        XCTAssertTrue(snapshot.inputs.allSatisfy { $0.samples == samples })
        XCTAssertTrue(snapshot.inputs.allSatisfy { $0.context == Array(context.prefix(100)) })
    }

    func testStartRejectsFewerThanTwoDownloadedModelsBeforeCapture() async {
        let capture = BenchmarkCapture(samples: [])
        let benchmark = MLXModelBenchmark(
            capture: capture,
            modelProvider: { [.qwenSmall] },
            decoderFactory: { _, _ in
                BenchmarkDecoder(model: .qwenSmall, text: "unused", log: BenchmarkLog())
            }
        )

        do {
            try await benchmark.startRecording()
            XCTFail("Expected a minimum of two cached models")
        } catch let error as MLXModelBenchmarkError {
            guard case .insufficientDownloadedModels = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(capture.startCount, 0)
    }

    func testCancelWaitsForCurrentDecoderToUnloadAndSkipsRemainingModels() async throws {
        let capture = BenchmarkCapture(samples: Array(repeating: 0.1, count: 1_600))
        let log = BenchmarkLog()
        let control = BlockingControl()
        let first = BenchmarkDecoder(
            model: .qwenSmall,
            text: "cancelled",
            log: log,
            control: control
        )
        let second = BenchmarkDecoder(model: .qwenLarge, text: "unused", log: log)
        let benchmark = MLXModelBenchmark(
            capture: capture,
            modelProvider: { [.qwenSmall, .qwenLarge] },
            decoderFactory: { model, _ in model == .qwenSmall ? first : second }
        )
        let models = try await benchmark.startRecording()
        let comparison = Task {
            try await benchmark.stopAndCompare(models: models, contextualStrings: [])
        }
        await control.transcriptionStarted.wait()
        let cancelFinished = Locked(false)
        let cancellation = Task {
            await benchmark.cancel()
            cancelFinished.value = true
        }
        await control.cancellationObserved.wait()
        await control.transcriptionRelease.open()
        await control.unloadStarted.wait()
        XCTAssertFalse(cancelFinished.value)
        await control.unloadRelease.open()
        await cancellation.value
        XCTAssertTrue(cancelFinished.value)

        do {
            _ = try await comparison.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let events = await log.snapshot().events
        XCTAssertEqual(events, ["prepare-qwenSmall", "transcribe-qwenSmall", "unload-qwenSmall"])
    }
}

private enum BenchmarkTestError: Error { case failed }

private final class BenchmarkCapture: MLXAudioCapturing, @unchecked Sendable {
    private let samples: [Float]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(samples: [Float]) { self.samples = samples }
    func start(onFailure _: @escaping @Sendable (Error) -> Void) async throws {
        startCount += 1
    }
    func stop() throws -> MLXCapturedAudio {
        stopCount += 1
        return MLXCapturedAudio(samples: samples, sampleRate: 16_000)
    }
    func cancel() {}
}

private actor BenchmarkLog {
    struct Input: Sendable {
        let samples: [Float]
        let context: [String]
    }
    private var events: [String] = []
    private var inputs: [Input] = []

    func append(_ event: String) { events.append(event) }
    func append(samples: [Float], context: [String]) {
        inputs.append(.init(samples: samples, context: context))
    }
    func snapshot() -> (events: [String], inputs: [Input]) { (events, inputs) }
}

private actor BenchmarkDecoder: MLXSpeechDecoding {
    let model: MLXSpeechModel
    let text: String?
    let log: BenchmarkLog
    let control: BlockingControl?

    init(
        model: MLXSpeechModel,
        text: String?,
        log: BenchmarkLog,
        control: BlockingControl? = nil
    ) {
        self.model = model
        self.text = text
        self.log = log
        self.control = control
    }

    func prepare() async throws { await log.append("prepare-\(model.rawValue)") }
    func transcribe(
        samples: [Float],
        contextualStrings: [String]
    ) async throws -> MLXDecodingResult {
        await log.append("transcribe-\(model.rawValue)")
        await log.append(samples: samples, context: contextualStrings)
        if let control {
            await control.transcriptionStarted.open()
            await withTaskCancellationHandler {
                await control.transcriptionRelease.wait()
            } onCancel: {
                Task { await control.cancellationObserved.open() }
            }
            try Task.checkCancellation()
        }
        guard let text else { throw BenchmarkTestError.failed }
        return .init(text: text, inferenceDuration: 99, peakMemoryGB: 1.25)
    }
    func unload() async {
        await log.append("unload-\(model.rawValue)")
        if let control {
            await control.unloadStarted.open()
            await control.unloadRelease.wait()
        }
    }
}

private struct BlockingControl: Sendable {
    let transcriptionStarted = AsyncGate()
    let cancellationObserved = AsyncGate()
    let transcriptionRelease = AsyncGate()
    let unloadStarted = AsyncGate()
    let unloadRelease = AsyncGate()
}

private actor AsyncGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        openState = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    func update(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
