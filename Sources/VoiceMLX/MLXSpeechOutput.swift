import AVFAudio
import Foundation
import VoiceCore
import VoiceMLXRuntime

public enum MLXSpeechModelTier: String, CaseIterable, Sendable {
    case small
    case large
}

/// How the spoken voice is defined. Each mode maps to a different Qwen3-TTS
/// checkpoint variant, so changing mode can require a different download.
public enum MLXVoiceConfiguration: Equatable, Sendable {
    /// A built-in speaker, optionally styled ("calm and slow").
    case preset(MLXSpeechVoice, style: String?)
    /// A brand-new voice created from a natural-language description.
    case designed(description: String)
    /// A zero-shot clone of the reference clip; the optional style can steer
    /// delivery (for example an accent) at the cost of per-utterance
    /// reconditioning.
    case cloned(referenceAudioURL: URL, transcript: String, style: String?)
}

/// Opt-in local Qwen3-TTS checkpoints. Selecting one downloads the pinned
/// snapshot from Hugging Face; synthesis then runs entirely on this Mac.
public enum MLXSpeechCheckpoint: String, CaseIterable, Identifiable, Sendable {
    case customVoiceSmall
    case customVoiceLarge
    case baseSmall
    case baseLarge
    case voiceDesignLarge

    public var id: String { rawValue }

    /// VoiceDesign ships only as a 1.7B checkpoint, so described voices ignore
    /// the selected tier.
    public static func checkpoint(
        tier: MLXSpeechModelTier,
        configuration: MLXVoiceConfiguration
    ) -> MLXSpeechCheckpoint {
        switch configuration {
        case .preset:
            tier == .small ? .customVoiceSmall : .customVoiceLarge
        case .designed:
            .voiceDesignLarge
        case .cloned:
            tier == .small ? .baseSmall : .baseLarge
        }
    }

    public var displayName: String {
        switch self {
        case .customVoiceSmall:
            "Qwen3-TTS 0.6B CustomVoice · 8-bit"
        case .customVoiceLarge:
            "Qwen3-TTS 1.7B CustomVoice · 8-bit"
        case .baseSmall:
            "Qwen3-TTS 0.6B Base · 8-bit"
        case .baseLarge:
            "Qwen3-TTS 1.7B Base · 8-bit"
        case .voiceDesignLarge:
            "Qwen3-TTS 1.7B VoiceDesign · 8-bit"
        }
    }

    public var repositoryID: String {
        switch self {
        case .customVoiceSmall:
            "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
        case .customVoiceLarge:
            "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
        case .baseSmall:
            "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        case .baseLarge:
            "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
        case .voiceDesignLarge:
            "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
        }
    }

    /// An immutable Hugging Face snapshot, rather than a moving `main` branch.
    public var revision: String {
        switch self {
        case .customVoiceSmall:
            "049ef77fe8816b536193c0c25f9a214d17921282"
        case .customVoiceLarge:
            "41d3337e8b7f2843a75841595fc14e4b9a7a4b96"
        case .baseSmall:
            "50f45ef0047cde7e84c2ef04326acb8ada2436a7"
        case .baseLarge:
            "e7dd0585652209fa0d7783659aad4e8a324de11c"
        case .voiceDesignLarge:
            "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee"
        }
    }

    public var approximateDownload: String {
        switch self {
        case .customVoiceSmall, .baseSmall:
            "about 1.1 GB"
        case .customVoiceLarge, .baseLarge, .voiceDesignLarge:
            "about 2.4 GB"
        }
    }
}

/// The checkpoints' built-in English speakers.
public enum MLXSpeechVoice: String, CaseIterable, Identifiable, Sendable {
    case ryan = "Ryan"
    case aiden = "Aiden"

    public var id: String { rawValue }

    public var displayName: String { rawValue }
}

public enum MLXSpeechOutputError: LocalizedError, Sendable {
    case noAudioProduced

    public var errorDescription: String? {
        "The MLX voice finished without producing audio."
    }
}

protocol MLXTTSRuntimeServing: Sendable {
    func prepare() async throws
    func synthesize(
        text: String,
        request: MLXTTSVoiceRequest,
        language: String
    ) async throws -> AsyncThrowingStream<MLXTTSAudioChunk, Error>
    func unload() async
}

extension MLXTTSRuntime: MLXTTSRuntimeServing {}

/// Speaks text through a local Qwen3-TTS model. Generation is streamed, so
/// playback of the first audio chunk overlaps synthesis of the rest.
public actor MLXSpeechOutput: SpeechOutputting {
    public typealias PreparationHandler = @Sendable (MLXModelPreparationStage) -> Void

    private let runtime: any MLXTTSRuntimeServing
    private let player = SpeechChunkPlayer()
    private var configuration: MLXVoiceConfiguration
    private var speakTask: Task<Void, Error>?
    private var speakToken: UUID?

    public init(
        checkpoint: MLXSpeechCheckpoint,
        configuration: MLXVoiceConfiguration,
        onPreparation: @escaping PreparationHandler = { _ in }
    ) {
        self.configuration = configuration
        runtime = MLXTTSRuntime(
            configuration: MLXTTSConfiguration(
                repositoryID: checkpoint.repositoryID,
                revision: checkpoint.revision,
                modelStoreURL: MLXSpeechRecognizer.modelStoreURL
            ),
            onPreparation: { stage in
                onPreparation(Self.preparationStage(from: stage))
            }
        )
    }

    init(
        runtime: any MLXTTSRuntimeServing,
        configuration: MLXVoiceConfiguration
    ) {
        self.runtime = runtime
        self.configuration = configuration
    }

    /// Downloads the pinned snapshot if needed and loads it into memory.
    public func prepare() async throws {
        try await runtime.prepare()
    }

    /// Applies a voice change that stays on this engine's checkpoint. Changing
    /// mode across checkpoints requires a new engine.
    public func setConfiguration(_ configuration: MLXVoiceConfiguration) {
        self.configuration = configuration
    }

    /// `voiceIdentifier` selects Apple system voices and is ignored here; the
    /// MLX voice is chosen with `setConfiguration`.
    public func speak(_ text: String, voiceIdentifier _: String?) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await stopImmediately()

        let token = UUID()
        speakToken = token
        // Long text is synthesized in segments: generation drifts if one
        // utterance runs too long. Each segment is enqueued as it is produced,
        // so playback of earlier segments overlaps synthesis of later ones and
        // the speech stays continuous.
        let segments = SpeechTextSegmenter.segments(for: trimmed)
        let request = Self.voiceRequest(for: configuration)
        let runtime = runtime
        let player = player
        let task = Task {
            var producedAudio = false
            for segment in segments {
                try Task.checkCancellation()
                let chunks = try await runtime.synthesize(
                    text: segment,
                    request: request,
                    language: "English"
                )
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    try await player.enqueue(
                        samples: chunk.samples,
                        sampleRate: chunk.sampleRate
                    )
                    producedAudio = true
                }
            }
            try Task.checkCancellation()
            guard producedAudio else {
                throw MLXSpeechOutputError.noAudioProduced
            }
            try await player.awaitPlaybackCompletion()
        }
        speakTask = task
        do {
            try await task.value
        } catch {
            // A different token means a newer speaker already took over the
            // player (and stopped this one); tearing it down here would cut
            // that speaker off.
            if speakToken == token {
                speakTask = nil
                speakToken = nil
                player.stop()
            }
            throw error
        }
        if speakToken == token {
            speakTask = nil
            speakToken = nil
        }
    }

    public func stopImmediately() async {
        let task = speakTask
        speakTask = nil
        speakToken = nil
        task?.cancel()
        player.stop()
        if let task {
            _ = await task.result
        }
    }

    /// Stops playback and releases the model when the user switches back to
    /// the system voice.
    public func unload() async {
        await stopImmediately()
        await runtime.unload()
    }

    /// Builds the runtime request for a configuration. A preset with a style
    /// becomes "Ryan, calm and slow." per the checkpoint's prompt convention.
    static func voiceRequest(
        for configuration: MLXVoiceConfiguration
    ) -> MLXTTSVoiceRequest {
        switch configuration {
        case .preset(let voice, let style):
            guard let style = Self.normalized(style) else {
                return MLXTTSVoiceRequest(voiceInstruction: voice.rawValue)
            }
            let punctuated = style.hasSuffix(".") ? style : style + "."
            return MLXTTSVoiceRequest(
                voiceInstruction: "\(voice.rawValue), \(punctuated)"
            )
        case .designed(let description):
            return MLXTTSVoiceRequest(
                voiceInstruction: Self.normalized(description)
            )
        case .cloned(let referenceAudioURL, let transcript, let style):
            return MLXTTSVoiceRequest(
                voiceInstruction: Self.normalized(style),
                referenceAudioURL: referenceAudioURL,
                referenceTranscript: transcript
            )
        }
    }

    private static func normalized(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preparationStage(
        from stage: MLXTTSPreparationStage
    ) -> MLXModelPreparationStage {
        switch stage {
        case .downloading(let fraction):
            .downloading(fraction: fraction)
        case .loading:
            .loading
        case .ready:
            .ready
        @unknown default:
            .loading
        }
    }
}

/// Schedules Float32 mono chunks onto one AVAudioPlayerNode as they arrive.
/// AVAudioPlayerNode invokes completion handlers on an internal queue, so
/// player and buffer-credit state are independently locked.
final class SpeechChunkPlayer: @unchecked Sendable {
    // Enough queued chunks to hide scheduling jitter without allowing
    // synthesis to retain an entire long response ahead of playback.
    private static let maximumScheduledBufferCount = 4

    private let lock = NSLock()
    private let bufferQueue = PlaybackBufferQueue(
        capacity: SpeechChunkPlayer.maximumScheduledBufferCount
    )
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    func enqueue(samples: [Float], sampleRate: Double) async throws {
        guard !samples.isEmpty else { return }
        let buffer = try Self.makeBuffer(samples: samples, sampleRate: sampleRate)
        let reservation = try await bufferQueue.reserve()
        do {
            try withLock {
                try Task.checkCancellation()
                let node = try activeNode(for: buffer.format)
                node.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: [],
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    self?.bufferQueue.complete(reservation)
                }
                node.play()
            }
        } catch {
            bufferQueue.complete(reservation)
            throw error
        }
    }

    /// Resolves once every scheduled buffer has been played back, or throws
    /// CancellationError if stop() interrupts the wait.
    func awaitPlaybackCompletion() async throws {
        try await bufferQueue.awaitDrain()
    }

    func stop() {
        let (node, engine) = withLock {
            let captured = (self.node, self.engine)
            self.node = nil
            self.engine = nil
            format = nil
            return captured
        }
        // Stopping can fire completion handlers synchronously, so invalidate
        // their reservations before touching the node. They then stay stale
        // even if playback restarts immediately.
        bufferQueue.cancel()
        node?.stop()
        engine?.stop()
    }

    /// Must be called with the lock held.
    private func activeNode(for format: AVAudioFormat) throws -> AVAudioPlayerNode {
        if let node, let engine, engine.isRunning, self.format == format {
            return node
        }
        node?.stop()
        engine?.stop()

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        self.engine = engine
        self.node = node
        self.format = format
        return node
    }

    private static func makeBuffer(
        samples: [Float],
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = buffer.floatChannelData?.pointee
        else {
            throw MLXSpeechRecognizerError.invalidAudioFormat
        }
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
