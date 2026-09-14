import Foundation
import Testing

@testable import VoiceMLXRuntime

@Suite
struct MLXTTSRuntimeTests {
    @Test
    func modelTypeIsReadFromTheSnapshotConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-tts-model-type-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = #"{"model_type": "breeze_tts", "sample_rate": 24000}"#
        try configuration.write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        #expect(try MLXTTSRuntime.modelType(in: directory) == "breeze_tts")
        #expect(throws: (any Error).self) {
            try MLXTTSRuntime.modelType(in: directory.appendingPathComponent("missing"))
        }
    }

    @Test
    func snapshotPolicyCoversNestedTokenizerFilesAndAccessModes() {
        // fnmatch without FNM_PATHNAME lets `*` cross `/`, so these three
        // patterns must also cover the checkpoint's speech_tokenizer/ files.
        #expect(
            MLXTTSRuntime.snapshotPatterns() == ["*.safetensors", "*.json", "*.txt"]
        )
        #expect(!MLXTTSRuntime.localFilesOnly(for: .downloadIfNeeded))
        #expect(MLXTTSRuntime.localFilesOnly(for: .localOnly))
    }

    @Test
    func missingLocalSnapshotReportsUnavailableWithoutTouchingTheNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = MLXTTSConfiguration(
            repositoryID: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
            revision: "049ef77fe8816b536193c0c25f9a214d17921282",
            modelStoreURL: directory,
            accessPolicy: .localOnly
        )

        let available = await MLXTTSRuntime.isModelAvailableLocally(
            configuration: configuration
        )
        #expect(!available)
    }

    /// Downloads the pinned 0.6B snapshot into the app's real model store and
    /// synthesizes one sentence. Gated behind an environment variable so
    /// normal test runs stay offline; run explicitly with
    /// `env VOICE_MLX_TTS_INTEGRATION=1 swift test --filter integration`.
    @Test
    func integrationDownloadsPinnedSnapshotAndSynthesizesAudio() async throws {
        guard ProcessInfo.processInfo.environment["VOICE_MLX_TTS_INTEGRATION"] == "1"
        else { return }

        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        let modelStore =
            base
            .appendingPathComponent("io.blacktop.Voice", isDirectory: true)
            .appendingPathComponent("MLXModels", isDirectory: true)

        let runtime = MLXTTSRuntime(
            configuration: MLXTTSConfiguration(
                repositoryID: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
                revision: "049ef77fe8816b536193c0c25f9a214d17921282",
                modelStoreURL: modelStore
            ),
            onPreparation: { _ in }
        )
        try await runtime.prepare()

        var totalSamples = 0
        var sampleRate = 0.0
        let chunks = try await runtime.synthesize(
            text: "Hello from Voice. This is the local Qwen speech model.",
            request: MLXTTSVoiceRequest(voiceInstruction: "Ryan"),
            language: "English"
        )
        for try await chunk in chunks {
            totalSamples += chunk.samples.count
            sampleRate = chunk.sampleRate
        }
        await runtime.unload()

        #expect(sampleRate > 0)
        let seconds = Double(totalSamples) / max(sampleRate, 1)
        #expect(seconds > 1, "Expected speech audio, got \(seconds)s")
        #expect(seconds < 30, "Expected a short utterance, got \(seconds)s")
    }

    @Test
    func synthesisBeforePrepareFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtime = MLXTTSRuntime(
            configuration: MLXTTSConfiguration(
                repositoryID: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
                revision: "049ef77fe8816b536193c0c25f9a214d17921282",
                modelStoreURL: directory
            ),
            onPreparation: { _ in }
        )

        await #expect(throws: MLXTTSRuntimeError.notPrepared) {
            _ = try await runtime.synthesize(
                text: "hello",
                request: MLXTTSVoiceRequest(voiceInstruction: "Ryan"),
                language: "English"
            )
        }
    }

    @Test
    func cloneRequestWithoutTranscriptFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtime = MLXTTSRuntime(
            configuration: MLXTTSConfiguration(
                repositoryID: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7",
                modelStoreURL: directory
            ),
            onPreparation: { _ in }
        )

        await #expect(throws: MLXTTSRuntimeError.referenceTranscriptMissing) {
            _ = try await runtime.synthesize(
                text: "hello",
                request: MLXTTSVoiceRequest(
                    referenceAudioURL: URL(fileURLWithPath: "/tmp/ref.wav"),
                    referenceTranscript: "   "
                ),
                language: "English"
            )
        }
    }

    @Test
    func cancellationBarrierWaitsForGenerationToExit() async throws {
        let probe = TTSGenerationLifecycleProbe()
        let generationTask = Task.detached {
            await probe.runGeneration()
        }
        await probe.waitUntilGenerationStarts()

        let completionTask = MLXTTSRuntime.finishAfterCancelling(generationTask) {
            await probe.markFinished()
        }
        try await Task.sleep(for: .milliseconds(20))

        let finishedBeforeRelease = await probe.isFinished
        #expect(!finishedBeforeRelease)

        await probe.releaseGeneration()
        await completionTask.value

        let events = await probe.events
        #expect(events == [.started, .exited, .finished])
    }
}

private actor TTSGenerationLifecycleProbe {
    enum Event: Equatable, Sendable {
        case started
        case exited
        case finished
    }

    private let starts: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var events: [Event] = []

    var isFinished: Bool {
        events.contains(.finished)
    }

    init() {
        let pair = AsyncStream<Void>.makeStream()
        starts = pair.stream
        startContinuation = pair.continuation
    }

    func runGeneration() async {
        events.append(.started)
        startContinuation.yield(())
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        events.append(.exited)
    }

    func waitUntilGenerationStarts() async {
        for await _ in starts.prefix(1) {}
    }

    func releaseGeneration() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func markFinished() {
        events.append(.finished)
    }
}
