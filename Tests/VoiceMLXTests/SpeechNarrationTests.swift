import Foundation
import Synchronization
import VoiceMLXRuntime
import XCTest

@testable import VoiceMLX

private func narrator(_ text: String) -> [SpeechNarrationBlock] {
    [SpeechNarrationBlock(role: .narrator, text: text)]
}

final class SpeechNarrationTests: XCTestCase {
    func testSilenceMeasurementSpansChunksAndExcludesEdges() {
        var meter = SpeechSilenceMeter()
        meter.observe([0, 0, 0, 0.2, 0, 0], sampleRate: 10)
        meter.observe([0, 0, 0.2, 0, 0, 0, 0, 0], sampleRate: 10)
        XCTAssertEqual(meter.longestInternalSeconds, 0.4, accuracy: 0.0001)
    }

    func testParagraphsAndWrappedLinesSurviveSegmentation() {
        let segments = SpeechTextSegmenter.narration(
            for: "First wrapped\r\nline.\r\n\r\nNext paragraph.")
        XCTAssertEqual(segments.map(\.text), ["First wrapped line.", "Next paragraph."])
        XCTAssertEqual(segments.map(\.pauseAfter), [1.0, 1.0])
        XCTAssertTrue(SpeechTextSegmenter.narration(for: " \n\n ").isEmpty)
        let grouped = SpeechTextSegmenter.narration(for: "One. Two. Three.", budget: 10)
        XCTAssertEqual(grouped.map(\.text), ["One. Two.", "Three."])
        XCTAssertEqual(grouped.map(\.pauseAfter), [0.22, 1.0])
    }

    func testTrimsOnlyEdgesAndKeepsBreathingInsidePhrase() {
        let quiet = [Float](repeating: 0, count: 8_000)
        let speech = [Float](repeating: 0.2, count: 800)
        let input = quiet + speech + quiet + speech + quiet
        let result = SpeechNarration.prepare(input, sampleRate: 8_000, pauseAfter: 0.45)
        XCTAssertEqual(result.trimmedSeconds, 1.92, accuracy: 0.0001)
        // 40 ms head + speech + untouched one-second internal pause + speech
        // + 40 ms tail + 370 ms extra paragraph rest.
        XCTAssertEqual(result.samples.count, 13_200)
        XCTAssertEqual(Array(result.samples[1120..<9120]), quiet)
        let soft = [Float](repeating: 0.0005, count: 800)
        XCTAssertEqual(
            SpeechNarration.prepare(soft, sampleRate: 8_000, pauseAfter: 0).samples, soft)
    }

    func testParagraphWithinBudgetIsOneUtteranceAndOnlyHugeSentencesBreakInside() {
        let sentence = "This sentence runs to about sixty characters, give or take."
        let paragraph = Array(repeating: sentence, count: 6).joined(separator: " ")
        XCTAssertEqual(SpeechTextSegmenter.narration(for: paragraph).map(\.text), [paragraph])

        let clauses = Array(repeating: "a clause of some length here,", count: 16)
        let long = clauses.joined(separator: " ") + " and the end."
        XCTAssertGreaterThan(long.count, 400)
        XCTAssertEqual(
            SpeechTextSegmenter.narration(for: long).map(\.text), [long],
            "a sentence under the limit is spoken whole even when over budget"
        )
        let huge =
            Array(repeating: "another clause of some length,", count: 20).joined(
                separator: " ") + " done."
        XCTAssertGreaterThan(huge.count, SpeechTextSegmenter.narrationSentenceLimit)
        let pieces = SpeechTextSegmenter.narration(for: huge)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.map(\.text).joined(separator: " "), huge)
    }

    func testCastHandsOtherRolesToTheOtherPresetAndKeepsOneCheckpoint() {
        let cast = MLXNarrationVoices.cast(narrator: .preset(.ryan, style: "calm"))
        XCTAssertEqual(cast.narrator, .preset(.ryan, style: "calm"))
        XCTAssertEqual(cast.secondSpeaker, .aiden)
        for role in [SpeechNarrationRole.heading, .aside, .quote] {
            guard case .preset(let voice, let style) = cast.configuration(for: role) else {
                return XCTFail(
                    "preset narrators cast presets, got \(cast.configuration(for: role))")
            }
            XCTAssertEqual(voice, .aiden)
            XCTAssertNotNil(style)
            XCTAssertEqual(
                MLXSpeechCheckpoint.checkpoint(
                    tier: .large, configuration: .preset(voice, style: style)),
                .customVoiceLarge
            )
        }
        XCTAssertEqual(
            MLXNarrationVoices.cast(narrator: .preset(.aiden, style: nil)).secondSpeaker, .ryan)

        let designed = MLXNarrationVoices.cast(narrator: .designed(description: "a warm narrator"))
        XCTAssertNil(designed.secondSpeaker)
        XCTAssertEqual(
            designed.heading,
            .designed(description: "a warm narrator. Announcing a section title, clear and brisk.")
        )
        let url = URL(fileURLWithPath: "/tmp/ref.wav")
        let clone = MLXVoiceConfiguration.cloned(
            referenceAudioURL: url, transcript: "hi", style: nil)
        let cloned = MLXNarrationVoices.cast(narrator: clone)
        XCTAssertNil(cloned.secondSpeaker)
        for role in SpeechNarrationRole.allCases {
            XCTAssertEqual(
                cloned.configuration(for: role), clone,
                "a clone must keep its cached conditioning for \(role)")
        }
    }

    func testUtterancesCastEachBlockAndRestByRole() {
        let blocks = [
            SpeechNarrationBlock(role: .heading, text: "Title"),
            SpeechNarrationBlock(role: .narrator, text: "One. Two.\n\nThree."),
            SpeechNarrationBlock(role: .aside, text: "Swift code."),
            SpeechNarrationBlock(role: .quote, text: "“Quoted.”"),
        ]
        let voices = MLXNarrationVoices.cast(narrator: .preset(.ryan, style: nil))
        let utterances = MLXSpeechOutput.utterances(for: blocks, voices: voices, streaming: false)
        let texts = ["Title", "One. Two.", "Three.", "Swift code.", "“Quoted.”"]
        XCTAssertEqual(utterances.map(\.text), texts)
        XCTAssertEqual(utterances.map(\.role), [.heading, .narrator, .narrator, .aside, .quote])
        XCTAssertEqual(utterances.map(\.pauseAfter), [0.9, 1.0, 1.0, 0.7, 0])
        XCTAssertEqual(
            utterances[0].request.voiceInstruction, "Aiden, \(MLXNarrationVoices.headingStyle).")
        XCTAssertEqual(utterances[1].request.voiceInstruction, "Ryan")
        XCTAssertEqual(
            utterances[3].request.voiceInstruction, "Aiden, \(MLXNarrationVoices.asideStyle).")

        let streamed = MLXSpeechOutput.utterances(for: blocks, voices: voices, streaming: true)
        XCTAssertEqual(streamed.map(\.text), texts)
        XCTAssertTrue(streamed.allSatisfy { $0.pauseAfter == 0 })
        XCTAssertTrue(
            MLXSpeechOutput.utterances(
                for: [SpeechNarrationBlock(role: .narrator, text: " \n ")], voices: voices,
                streaming: false
            ).isEmpty)
    }

    func testNarrationQueuesInOrderBeforePreviousAudioFinishesAndStopsAtCapacity() async throws {
        let blocked = expectation(description: "third segment reaches full player")
        let player = NarrationTestPlayer(
            hold: true,
            onAttempt: { index in if index == 3 { blocked.fulfill() } }
        )
        let runtime = NarrationTestRuntime()
        let output = MLXSpeechOutput(
            runtime: runtime, configuration: .preset(.ryan, style: nil), player: player
        )
        let speaking = Task {
            try await output.narrate(narrator("First.\n\nSecond.\n\nThird.\n\nFourth."))
        }
        await fulfillment(of: [blocked], timeout: 3)
        let texts = await runtime.texts
        XCTAssertEqual(texts, ["First.", "Second.", "Third."])
        XCTAssertEqual(player.playedBuffers.count, 2, "two clips scheduled, third waits")
        XCTAssertEqual(player.playedBuffers.map { $0.first }, [0.1, 0.2])
        let paused = await output.togglePause()
        XCTAssertTrue(paused)
        XCTAssertEqual(player.pendingCount, 2, "pause must retain queued clips")
        let resumed = await output.togglePause()
        XCTAssertFalse(resumed)
        let afterResume = await runtime.texts
        XCTAssertEqual(afterResume, texts, "resume must not restart synthesis")
        // No playback completion was delivered: synthesis really overlapped
        // queued playback, but did not race through the whole document.
        await output.stopImmediately()
        do {
            try await speaking.value
            XCTFail("stop must cancel the blocked producer")
        } catch is CancellationError {}
        XCTAssertEqual(player.pendingCount, 0)
    }

    func testCallerCancellationAlsoStopsFinalPlaybackDrain() async throws {
        let draining = expectation(description: "waiting for final playback")
        let player = NarrationTestPlayer(hold: true, onDrain: { draining.fulfill() })
        let output = MLXSpeechOutput(
            runtime: NarrationTestRuntime(), configuration: .preset(.ryan, style: nil),
            player: player
        )
        let speaking = Task { try await output.narrate(narrator("One final segment.")) }
        await fulfillment(of: [draining], timeout: 3)
        speaking.cancel()
        do {
            try await speaking.value
            XCTFail("caller cancellation must reach playback")
        } catch is CancellationError {}
        XCTAssertEqual(player.pendingCount, 0)
        XCTAssertTrue(player.stopped)
    }

    func testEmptySegmentIsReportedAndLaterSegmentsStillPlay() async throws {
        for streaming in [false, true] {
            let player = NarrationTestPlayer()
            let runtime = NarrationTestRuntime(emptyAt: 2)
            let timings = Mutex<[SpeechSegmentTiming]>([])
            let skipped = Mutex<[String]>([])
            let output = MLXSpeechOutput(
                runtime: runtime, configuration: .preset(.ryan, style: nil), player: player
            )
            try await output.narrate(
                narrator("One.\n\nTwo.\n\nThree."),
                streaming: streaming,
                onTiming: { timing in timings.withLock { $0.append(timing) } },
                onSkipped: { index, reason in
                    skipped.withLock { $0.append("\(index): \(reason.rawValue)") }
                }
            )
            let texts = await runtime.texts
            XCTAssertEqual(texts, ["One.", "Two.", "Three."])
            XCTAssertEqual(skipped.withLock { $0 }, ["2: no audio produced"])
            XCTAssertEqual(player.playedBuffers.count, 2)
            XCTAssertEqual(timings.withLock { $0.first?.audioSeconds } ?? 0, 0.1, accuracy: 0.0001)
            XCTAssertFalse(player.stopped)
        }
    }

    func testEntirelyEmptyAudioStillFailsAfterReportingEverySegment() async throws {
        for streaming in [false, true] {
            let skipped = Mutex<[Int]>([])
            let output = MLXSpeechOutput(
                runtime: NarrationTestRuntime(sampleCount: 0),
                configuration: .preset(.ryan, style: nil), player: NarrationTestPlayer())
            do {
                try await output.narrate(
                    narrator("One.\n\nTwo."), streaming: streaming,
                    onSkipped: { index, reason in
                        XCTAssertEqual(reason, .noAudioProduced)
                        skipped.withLock { $0.append(index) }
                    })
                XCTFail("entirely empty audio must fail")
            } catch let error as MLXSpeechOutputError {
                XCTAssertEqual(error, .noAudioProduced)
            }
            XCTAssertEqual(skipped.withLock { $0 }, [1, 2])
        }
    }

    func testStreamingStartsPlaybackBeforeTheUtteranceFinishes() async throws {
        let firstChunk = expectation(description: "first chunk reaches player")
        let chunks = AsyncThrowingStream<MLXTTSAudioChunk, Error>.makeStream()
        let player = NarrationTestPlayer(onAttempt: { _ in firstChunk.fulfill() })
        let output = MLXSpeechOutput(
            runtime: StreamTestRuntime(chunks: chunks.stream),
            configuration: .preset(.ryan, style: nil), player: player)
        chunks.continuation.yield(MLXTTSAudioChunk(samples: [0.2], sampleRate: 24_000))
        let speaking = Task { try await output.narrate(narrator("Done."), streaming: true) }
        await fulfillment(of: [firstChunk], timeout: 3)
        chunks.continuation.finish()
        try await speaking.value
        XCTAssertEqual(player.playedBuffers, [[0.2]])
    }

    func testInvalidSampleRateFailsBeforePlayback() async throws {
        for streaming in [false, true] {
            let chunks = AsyncThrowingStream<MLXTTSAudioChunk, Error>.makeStream()
            let cancelled = Mutex(false)
            chunks.continuation.onTermination = { reason in
                if case .cancelled = reason { cancelled.withLock { $0 = true } }
            }
            let player = NarrationTestPlayer()
            let output = MLXSpeechOutput(
                runtime: StreamTestRuntime(chunks: chunks.stream),
                configuration: .preset(.ryan, style: nil), player: player)
            chunks.continuation.yield(MLXTTSAudioChunk(samples: [0.2], sampleRate: .nan))
            do {
                try await output.narrate(narrator("Invalid audio."), streaming: streaming)
                XCTFail("invalid audio must fail")
            } catch SpeechNarrationError.invalidAudio {}
            XCTAssertTrue(cancelled.withLock { $0 }, "failed narration left synthesis running")
            XCTAssertTrue(player.playedBuffers.isEmpty)
        }
    }

    func testStreamingPlaybackCancellationAlsoCancelsSynthesis() async throws {
        let chunks = AsyncThrowingStream<MLXTTSAudioChunk, Error>.makeStream()
        let cancelled = Mutex(false)
        chunks.continuation.onTermination = { reason in
            if case .cancelled = reason { cancelled.withLock { $0 = true } }
        }
        let blocked = expectation(description: "third chunk waits for playback")
        let player = NarrationTestPlayer(
            hold: true, onAttempt: { index in if index == 3 { blocked.fulfill() } })
        let output = MLXSpeechOutput(
            runtime: StreamTestRuntime(chunks: chunks.stream),
            configuration: .preset(.ryan, style: nil), player: player)
        for _ in 0..<3 {
            chunks.continuation.yield(MLXTTSAudioChunk(samples: [0.2], sampleRate: 24_000))
        }
        let speaking = Task {
            try await output.narrate(narrator("Still speaking."), streaming: true)
        }
        await fulfillment(of: [blocked], timeout: 3)
        speaking.cancel()
        do {
            try await speaking.value
            XCTFail("caller cancellation must escape")
        } catch is CancellationError {}
        XCTAssertTrue(cancelled.withLock { $0 }, "cancelled playback left synthesis running")
    }

    func testOversizedAudioCancelsThatSegmentAndContinues() async throws {
        for streaming in [false, true] {
            let player = NarrationTestPlayer()
            let runtime = NarrationTestRuntime(rate: 8_000, sampleCount: 80, oversizedAt: 1)
            let output = MLXSpeechOutput(
                runtime: runtime,
                configuration: .preset(.ryan, style: nil), player: player
            )
            let skipped = Mutex<[String]>([])
            try await output.narrate(
                narrator("Runaway generation.\n\nRead this next."), streaming: streaming,
                onSkipped: { index, reason in
                    skipped.withLock { $0.append("\(index): \(reason.rawValue)") }
                })
            let texts = await runtime.texts
            XCTAssertEqual(texts, ["Runaway generation.", "Read this next."])
            XCTAssertEqual(
                player.playedBuffers.map(\.count), streaming ? [360_000, 360_000, 80] : [80])
            XCTAssertEqual(skipped.withLock { $0 }, ["1: exceeded the 90-second audio limit"])
        }
    }

    func testStreamingLimitDrainsPreviouslyAcceptedAudio() async throws {
        let player = NarrationTestPlayer()
        let runtime = NarrationTestRuntime(rate: 8_000, sampleCount: 80, oversizedAt: 1)
        let output = MLXSpeechOutput(
            runtime: runtime,
            configuration: .preset(.ryan, style: nil), player: player
        )
        let skipped = Mutex<[String]>([])
        try await output.narrate(
            narrator("Runaway generation."), streaming: true,
            onSkipped: { index, reason in
                skipped.withLock { $0.append("\(index): \(reason.rawValue)") }
            })
        XCTAssertEqual(player.playedBuffers.map(\.count), [360_000, 360_000])
        XCTAssertFalse(player.stopped)
        XCTAssertEqual(skipped.withLock { $0 }, ["1: exceeded the 90-second audio limit"])
    }
}

private struct StreamTestRuntime: MLXTTSRuntimeServing {
    let chunks: AsyncThrowingStream<MLXTTSAudioChunk, Error>
    func prepare() async throws {}
    func unload() async {}
    func synthesize(text: String, request: MLXTTSVoiceRequest, language: String) async throws
        -> AsyncThrowingStream<MLXTTSAudioChunk, Error>
    { chunks }
}

private actor NarrationTestRuntime: MLXTTSRuntimeServing {
    private(set) var texts: [String] = []
    let emptyAt: Int?
    let rate: Double
    let sampleCount: Int
    let oversizedAt: Int?
    private nonisolated let oversizedCancelled = Mutex(false)

    init(
        emptyAt: Int? = nil, rate: Double = 24_000, sampleCount: Int = 2400,
        oversizedAt: Int? = nil
    ) {
        self.emptyAt = emptyAt
        self.rate = rate
        self.sampleCount = sampleCount
        self.oversizedAt = oversizedAt
    }

    func prepare() async throws {}
    func unload() async {}

    func synthesize(text: String, request: MLXTTSVoiceRequest, language: String) async throws
        -> AsyncThrowingStream<MLXTTSAudioChunk, Error>
    {
        if texts.count == oversizedAt, !oversizedCancelled.withLock({ $0 }) {
            throw MLXTTSRuntimeError.synthesisInProgress
        }
        texts.append(text)
        let empty = texts.count == emptyAt
        let amplitude = Float(texts.count) / 10
        let rate = rate
        let sampleCount = sampleCount
        if texts.count == oversizedAt {
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { [self] termination in
                    if case .cancelled = termination { oversizedCancelled.withLock { $0 = true } }
                }
                for count in [Int(rate * 45), Int(rate * 45), 1] {
                    continuation.yield(
                        MLXTTSAudioChunk(
                            samples: [Float](repeating: amplitude, count: count), sampleRate: rate))
                }
            }
        }
        return AsyncThrowingStream { continuation in
            if !empty {
                continuation.yield(
                    MLXTTSAudioChunk(
                        samples: [Float](repeating: amplitude, count: sampleCount), sampleRate: rate
                    )
                )
            }
            continuation.finish()
        }
    }
}

private final class NarrationTestPlayer: SpeechChunkPlaying, Sendable {
    private struct State {
        var attempts = 0
        var buffers: [[Float]] = []
        var stopped = false
        var paused = false
    }
    private let state = Mutex(State())
    private let queue = PlaybackBufferQueue(capacity: 2)
    private let hold: Bool
    private let onAttempt: @Sendable (Int) -> Void
    private let onDrain: @Sendable () -> Void

    init(
        hold: Bool = false,
        onDrain: @escaping @Sendable () -> Void = {},
        onAttempt: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.hold = hold
        self.onDrain = onDrain
        self.onAttempt = onAttempt
    }

    var playedBuffers: [[Float]] { state.withLock { $0.buffers } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var pendingCount: Int { queue.pendingBufferCount }
    var idleSeconds: Double { queue.idleSeconds }

    func enqueue(samples: [Float], sampleRate: Double) async throws {
        let attempt = state.withLock { state in
            state.attempts += 1
            return state.attempts
        }
        onAttempt(attempt)
        let slot = try await queue.reserve()
        state.withLock {
            $0.buffers.append(samples)
            $0.stopped = false
        }
        if !hold { queue.complete(slot) }
    }

    func awaitPlaybackCompletion() async throws {
        onDrain()
        try await queue.awaitDrain()
    }
    func stop() {
        state.withLock {
            $0.stopped = true
            $0.paused = false
        }
        queue.cancel()
    }

    func togglePause() -> Bool {
        state.withLock {
            $0.paused.toggle()
            return $0.paused
        }
    }
}
