import Foundation
import VoiceMLXRuntime
import XCTest

@testable import VoiceMLX

final class MLXSpeechOutputTests: XCTestCase {
    func testCheckpointCatalogPinsImmutableRevisions() {
        for checkpoint in MLXSpeechCheckpoint.allCases {
            XCTAssertEqual(
                checkpoint.revision.count,
                40,
                "\(checkpoint) must pin a full commit hash, not a branch name"
            )
            XCTAssertTrue(
                checkpoint.revision.allSatisfy(\.isHexDigit),
                "\(checkpoint) revision must be a commit hash"
            )
            XCTAssertTrue(checkpoint.repositoryID.contains("/"))
            XCTAssertFalse(checkpoint.displayName.isEmpty)
            XCTAssertFalse(checkpoint.approximateDownload.isEmpty)
        }

        let repositories = MLXSpeechCheckpoint.allCases.map(\.repositoryID)
        XCTAssertEqual(
            Set(repositories).count,
            repositories.count,
            "Each checkpoint must map to a distinct repository"
        )
    }

    func testVoiceModeSelectsTheMatchingCheckpointVariant() {
        let clip = URL(fileURLWithPath: "/tmp/reference.wav")

        XCTAssertEqual(
            MLXSpeechCheckpoint.checkpoint(
                tier: .small,
                configuration: .preset(.ryan, style: nil)
            ),
            .customVoiceSmall
        )
        XCTAssertEqual(
            MLXSpeechCheckpoint.checkpoint(
                tier: .large,
                configuration: .preset(.aiden, style: "calm")
            ),
            .customVoiceLarge
        )
        XCTAssertEqual(
            MLXSpeechCheckpoint.checkpoint(
                tier: .small,
                configuration: .cloned(
                    referenceAudioURL: clip,
                    transcript: "hello",
                    style: nil
                )
            ),
            .baseSmall
        )
        XCTAssertEqual(
            MLXSpeechCheckpoint.checkpoint(
                tier: .large,
                configuration: .cloned(
                    referenceAudioURL: clip,
                    transcript: "hello",
                    style: "Korean accent"
                )
            ),
            .baseLarge
        )
        // VoiceDesign ships only at 1.7B, so the tier is ignored.
        for tier in MLXSpeechModelTier.allCases {
            XCTAssertEqual(
                MLXSpeechCheckpoint.checkpoint(
                    tier: tier,
                    configuration: .designed(description: "a narrator")
                ),
                .voiceDesignLarge
            )
        }
    }

    func testVoiceRequestAssembly() {
        let plain = MLXSpeechOutput.voiceRequest(for: .preset(.ryan, style: nil))
        XCTAssertEqual(plain.voiceInstruction, "Ryan")
        XCTAssertNil(plain.referenceAudioURL)

        let styled = MLXSpeechOutput.voiceRequest(
            for: .preset(.aiden, style: "  calm and slow ")
        )
        XCTAssertEqual(styled.voiceInstruction, "Aiden, calm and slow.")

        let alreadyPunctuated = MLXSpeechOutput.voiceRequest(
            for: .preset(.ryan, style: "excited.")
        )
        XCTAssertEqual(alreadyPunctuated.voiceInstruction, "Ryan, excited.")

        let blankStyle = MLXSpeechOutput.voiceRequest(
            for: .preset(.ryan, style: "   ")
        )
        XCTAssertEqual(blankStyle.voiceInstruction, "Ryan")

        let designed = MLXSpeechOutput.voiceRequest(
            for: .designed(description: " A deep South African narrator ")
        )
        XCTAssertEqual(
            designed.voiceInstruction,
            "A deep South African narrator"
        )

        let clip = URL(fileURLWithPath: "/tmp/bmo.wav")
        let cloned = MLXSpeechOutput.voiceRequest(
            for: .cloned(
                referenceAudioURL: clip,
                transcript: "Who wants to play video games?",
                style: nil
            )
        )
        XCTAssertNil(cloned.voiceInstruction)
        XCTAssertEqual(cloned.referenceAudioURL, clip)
        XCTAssertEqual(cloned.referenceTranscript, "Who wants to play video games?")

        let accentedClone = MLXSpeechOutput.voiceRequest(
            for: .cloned(
                referenceAudioURL: clip,
                transcript: "Who wants to play video games?",
                style: "with a slight Korean accent"
            )
        )
        XCTAssertEqual(
            accentedClone.voiceInstruction,
            "with a slight Korean accent"
        )
        XCTAssertEqual(accentedClone.referenceAudioURL, clip)
    }

    func testVoiceIdentifiersMatchCheckpointSpeakerNames() {
        // rawValue is sent to the model as the speaker name; the checkpoint's
        // English presets are exactly Ryan and Aiden.
        XCTAssertEqual(
            MLXSpeechVoice.allCases.map(\.rawValue).sorted(),
            ["Aiden", "Ryan"]
        )
    }

    func testStopDuringSynthesisStartupPreventsLatePlayback() async throws {
        let runtime = SuspendingMLXTTSRuntime()
        let output = MLXSpeechOutput(
            runtime: runtime,
            configuration: .preset(.ryan, style: nil)
        )
        let speech = Task {
            try await output.speak("Do not play this.", voiceIdentifier: nil)
        }
        await runtime.waitUntilSynthesisStarts()

        // Stop runs concurrently because it waits for the speech task, which is
        // parked inside the fake until it is released. Releasing only after the
        // cancellation has landed means synthesis then succeeds, so nothing but
        // `speak` itself can turn this into a `CancellationError`.
        let stopped = Task { await output.stopImmediately() }
        await runtime.waitUntilCancelled()
        await runtime.releaseSynthesis()
        await stopped.value

        do {
            try await speech.value
            XCTFail("Expected stop during startup to cancel the speech operation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLongTextIsSynthesizedOneSegmentAtATime() async throws {
        let runtime = RecordingMLXTTSRuntime()
        let output = MLXSpeechOutput(
            runtime: runtime,
            configuration: .preset(.ryan, style: nil)
        )
        let sentence = "The build finished and every check passed."
        let text = Array(repeating: sentence, count: 20).joined(separator: " ")

        try await output.speak(text, voiceIdentifier: nil)

        // Asserted against the text itself rather than against
        // `SpeechTextSegmenter.segments(for:)`, which is what the code under
        // test calls — comparing the two would pass however it segmented.
        let requested = await runtime.requestedTexts
        XCTAssertEqual(requested.count, 3, "expected three synthesis calls: \(requested)")
        XCTAssertEqual(
            requested.joined(separator: " "),
            text,
            "segmentation must not lose, reorder, or invent text"
        )
        for segment in requested {
            XCTAssertLessThanOrEqual(segment.count, SpeechTextSegmenter.defaultBudget, segment)
            XCTAssertTrue(segment.hasSuffix("."), "segment must end a sentence: \(segment)")
        }
    }
}

/// Suspends inside `synthesize` until `releaseSynthesis()`, and reports when it
/// observes cancellation without acting on it.
///
/// Staying deaf to cancellation is what gives the stop test its teeth: this fake
/// only ever returns normally, so a `CancellationError` reaching the test can
/// only have come from `MLXSpeechOutput`'s own cancellation checks.
private actor SuspendingMLXTTSRuntime: MLXTTSRuntimeServing {
    private let synthesisStarts: AsyncStream<Void>
    private let synthesisStartContinuation: AsyncStream<Void>.Continuation
    private let cancellations: AsyncStream<Void>
    private let cancellationContinuation: AsyncStream<Void>.Continuation
    private var synthesisRelease: CheckedContinuation<Void, Never>?

    init() {
        let starts = AsyncStream<Void>.makeStream()
        synthesisStarts = starts.stream
        synthesisStartContinuation = starts.continuation
        let cancels = AsyncStream<Void>.makeStream()
        cancellations = cancels.stream
        cancellationContinuation = cancels.continuation
    }

    func prepare() async throws {}

    func synthesize(
        text _: String,
        request _: MLXTTSVoiceRequest,
        language _: String
    ) async throws -> AsyncThrowingStream<MLXTTSAudioChunk, Error> {
        synthesisStartContinuation.yield(())
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                synthesisRelease = continuation
            }
        } onCancel: {
            cancellationContinuation.yield(())
        }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func unload() async {}

    func waitUntilSynthesisStarts() async {
        for await _ in synthesisStarts.prefix(1) {}
    }

    /// Returns once the synthesis task has been cancelled, so a test can let
    /// synthesis finish normally afterwards and still be sure the cancellation
    /// landed first.
    func waitUntilCancelled() async {
        for await _ in cancellations.prefix(1) {}
    }

    func releaseSynthesis() {
        synthesisRelease?.resume()
        synthesisRelease = nil
    }
}

/// Records the text of every synthesis and answers with one empty chunk.
/// `SpeechChunkPlayer` skips empty sample buffers, so the test never starts a
/// real audio engine.
private actor RecordingMLXTTSRuntime: MLXTTSRuntimeServing {
    private(set) var requestedTexts: [String] = []

    func prepare() async throws {}

    func synthesize(
        text: String,
        request _: MLXTTSVoiceRequest,
        language _: String
    ) async throws -> AsyncThrowingStream<MLXTTSAudioChunk, Error> {
        requestedTexts.append(text)
        return AsyncThrowingStream { continuation in
            continuation.yield(MLXTTSAudioChunk(samples: [], sampleRate: 24000))
            continuation.finish()
        }
    }

    func unload() async {}
}
