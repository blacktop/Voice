import Foundation
import VoiceMLXRuntime

/// What a stretch of document text is, so narration can cast it. The
/// narrator reads prose; the other roles go to a second voice so a listener
/// hears the document's structure without hearing its markup.
public enum SpeechNarrationRole: String, Sendable, CaseIterable {
    case narrator
    case heading
    /// A label standing in for material that is not read: a code block, a
    /// table, a bare URL.
    case aside
    case quote

    /// The rest after the last utterance of a block in this role. A heading
    /// or an aside is its own thought, so it gets a paragraph-sized rest.
    var pauseAfter: Double {
        switch self {
        case .narrator, .quote: 1.0
        case .heading: 0.9
        case .aside: 0.7
        }
    }
}

/// One paragraph-sized run of text in a single role.
public struct SpeechNarrationBlock: Equatable, Sendable {
    public let role: SpeechNarrationRole
    public let text: String

    public init(role: SpeechNarrationRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// One synthesis call: a segment of text in the voice its role was cast with.
struct SpeechUtterance: Sendable {
    let text: String
    let role: SpeechNarrationRole
    let request: MLXTTSVoiceRequest
    let pauseAfter: Double
}

/// Durations only: diagnostics never include document text or voice prompts.
public struct SpeechSegmentTiming: Sendable {
    public let index: Int
    public let role: SpeechNarrationRole
    public let generationSeconds: Double
    public let audioSeconds: Double
    public let trimmedSeconds: Double
    public let longestInternalSilenceSeconds: Double
    public let queueWaitSeconds: Double
    public let playbackIdleSeconds: Double
}

/// A skipped utterance is reported without disclosing its text or voice prompt.
public enum SpeechSegmentSkipReason: String, Sendable {
    case audioLimitExceeded = "exceeded the 90-second audio limit"
    case noAudioProduced = "no audio produced"
}

protocol SpeechChunkPlaying: Sendable {
    func enqueue(samples: [Float], sampleRate: Double) async throws
    func awaitPlaybackCompletion() async throws
    func stop()
    func togglePause() -> Bool
    var idleSeconds: Double { get }
}

enum SpeechNarrationError: LocalizedError {
    case invalidAudio
    case audioLimitExceeded(streamedAudio: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidAudio: "The speech model produced invalid or inconsistent audio."
        case .audioLimitExceeded: SpeechSegmentSkipReason.audioLimitExceeded.rawValue
        }
    }
}

/// One model producer feeding a bounded player. Collecting each short segment
/// prevents model chunk delivery stalls from interrupting a sentence; enqueue
/// returns before playback completes so the next segment is generated ahead.
enum SpeechNarration {
    static func run(
        utterances: [SpeechUtterance],
        runtime: any MLXTTSRuntimeServing,
        player: any SpeechChunkPlaying,
        streaming: Bool,
        onTiming: @Sendable (SpeechSegmentTiming) -> Void,
        onSkipped: @Sendable (Int, SpeechSegmentSkipReason) -> Void
    ) async throws {
        var producedAudio = false
        for (index, utterance) in utterances.enumerated() {
            try Task.checkCancellation()
            do {
                let timing = try await render(
                    utterance, index: index + 1, runtime: runtime, player: player,
                    streaming: streaming)
                if timing.audioSeconds > 0 {
                    producedAudio = true
                } else {
                    onSkipped(index + 1, .noAudioProduced)
                }
                if streaming || timing.audioSeconds > 0 { onTiming(timing) }
            } catch SpeechNarrationError.audioLimitExceeded(let streamedAudio) {
                try Task.checkCancellation()
                producedAudio = producedAudio || streamedAudio
                onSkipped(index + 1, .audioLimitExceeded)
            }
        }
        try Task.checkCancellation()
        guard producedAudio else { throw MLXSpeechOutputError.noAudioProduced }
        try await player.awaitPlaybackCompletion()
    }

    private struct SegmentAudio {
        var samples: [Float] = []
        var sampleRate: Double?
        var sampleCount = 0
        var queueWaitSeconds = 0.0
        var silence = SpeechSilenceMeter()

        var seconds: Double {
            guard let sampleRate else { return 0 }
            return Double(sampleCount) / sampleRate
        }

        mutating func observe(_ chunk: MLXTTSAudioChunk, buffering: Bool) throws {
            guard isValid(chunk, sampleRate: sampleRate) else {
                throw SpeechNarrationError.invalidAudio
            }
            sampleRate = chunk.sampleRate
            guard chunk.samples.count <= Int(chunk.sampleRate * 90) - sampleCount else {
                throw SpeechNarrationError.audioLimitExceeded(
                    streamedAudio: !buffering && sampleCount > 0)
            }
            sampleCount += chunk.samples.count
            if buffering { samples.append(contentsOf: chunk.samples) }
            silence.observe(chunk.samples, sampleRate: chunk.sampleRate)
        }
    }

    /// Owns the stream until it finishes or its producer has been cancelled.
    private static func render(
        _ utterance: SpeechUtterance, index: Int, runtime: any MLXTTSRuntimeServing,
        player: any SpeechChunkPlaying, streaming: Bool
    ) async throws -> SpeechSegmentTiming {
        let started = ContinuousClock.now
        let chunks = try await runtime.synthesize(
            text: utterance.text, request: utterance.request, language: "English")
        do {
            var audio = try await collect(chunks, player: player, streaming: streaming)
            let generation = max(
                0, started.duration(to: .now) / .seconds(1) - audio.queueWaitSeconds)
            var trimmed = 0.0
            if !streaming, let sampleRate = audio.sampleRate {
                let prepared = prepare(
                    audio.samples, sampleRate: sampleRate, pauseAfter: utterance.pauseAfter)
                trimmed = prepared.trimmedSeconds
                let queued = ContinuousClock.now
                try await player.enqueue(samples: prepared.samples, sampleRate: sampleRate)
                audio.queueWaitSeconds += queued.duration(to: .now) / .seconds(1)
            }
            return SpeechSegmentTiming(
                index: index, role: utterance.role, generationSeconds: generation,
                audioSeconds: audio.seconds, trimmedSeconds: trimmed,
                longestInternalSilenceSeconds: audio.silence.longestInternalSeconds,
                queueWaitSeconds: audio.queueWaitSeconds, playbackIdleSeconds: player.idleSeconds)
        } catch {
            await cancel(chunks)
            throw error
        }
    }

    /// All utterances are capped at 90 seconds. Streaming enqueues each
    /// chunk immediately and retains no audio for later playback.
    private static func collect(
        _ chunks: AsyncThrowingStream<MLXTTSAudioChunk, Error>,
        player: any SpeechChunkPlaying, streaming: Bool
    ) async throws -> SegmentAudio {
        var audio = SegmentAudio()
        for try await chunk in chunks {
            try Task.checkCancellation()
            guard !chunk.samples.isEmpty else { continue }
            try audio.observe(chunk, buffering: !streaming)
            if streaming {
                let queued = ContinuousClock.now
                try await player.enqueue(samples: chunk.samples, sampleRate: chunk.sampleRate)
                audio.queueWaitSeconds += queued.duration(to: .now) / .seconds(1)
            }
        }
        try Task.checkCancellation()
        return audio
    }

    private static func isValid(_ chunk: MLXTTSAudioChunk, sampleRate: Double?) -> Bool {
        guard chunk.sampleRate.isFinite, (8_000...192_000).contains(chunk.sampleRate) else {
            return false
        }
        if let sampleRate, sampleRate != chunk.sampleRate { return false }
        return chunk.samples.allSatisfy(\.isFinite)
    }

    /// Breaking iteration alone need not cancel a producer that retains its
    /// continuation. A cancelled iterator invokes the stream's termination
    /// handler, allowing the runtime to finish teardown before the next call.
    private static func cancel(_ chunks: AsyncThrowingStream<MLXTTSAudioChunk, Error>) async {
        await withTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                var iterator = chunks.makeAsyncIterator()
                _ = try? await iterator.next()
            }
        }
    }

    /// Only trim quiet edges, never pauses inside a phrase. A conservative
    /// -60 dB threshold plus 40 ms guards protects soft consonants and breaths.
    /// Silent/very quiet clips are retained rather than accidentally discarded.
    static func prepare(_ samples: [Float], sampleRate: Double, pauseAfter: Double)
        -> (samples: [Float], trimmedSeconds: Double)
    {
        var start = 0
        var end = samples.count
        if let first = samples.firstIndex(where: { abs($0) > 0.001 }),
            let last = samples.lastIndex(where: { abs($0) > 0.001 })
        {
            let guardSamples = Int(sampleRate * 0.04)
            start = max(0, first - guardSamples)
            end = min(samples.count, last + 1 + guardSamples)
        }
        var result = Array(samples[start..<end])
        // Account for the retained edge silence on each side of a join.
        let rest = max(0, pauseAfter - 0.08)
        result.append(contentsOf: repeatElement(0, count: Int(rest * sampleRate)))
        return (result, Double(samples.count - (end - start)) / sampleRate)
    }
}

/// Measures quiet runs surrounded by speech, across model chunk boundaries.
/// Leading/trailing silence is handled separately by the edge trimmer.
struct SpeechSilenceMeter {
    private var heardSpeech = false
    private var quietSamples = 0
    private(set) var longestInternalSeconds = 0.0

    mutating func observe(_ samples: [Float], sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        for sample in samples {
            if abs(sample) <= 0.001 {
                if heardSpeech { quietSamples += 1 }
            } else {
                longestInternalSeconds = max(
                    longestInternalSeconds, Double(quietSamples) / sampleRate)
                quietSamples = 0
                heardSpeech = true
            }
        }
    }
}
