import AVFAudio
import Foundation
import VoiceCore

@MainActor
public final class AppleSpeechOutput: NSObject, SpeechOutputting {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var completion: CheckedContinuation<Void, Error>?
    private lazy var delegateProxy = AppleSpeechDelegateProxy(
        onStart: { [weak self] id in
            Task { @MainActor [weak self] in
                self?.handleStart(utteranceID: id)
            }
        },
        onCompletion: { [weak self] id, cancelled in
            Task { @MainActor [weak self] in
                self?.finish(
                    utteranceID: id,
                    error: cancelled ? CancellationError() : nil
                )
            }
        }
    )

    public override init() {
        super.init()
        synthesizer.delegate = delegateProxy
    }

    // `SpeechOutputting`'s requirements run on the caller's actor (Swift 6.2
    // caller isolation), so the witnesses stay nonisolated and hop to the main
    // actor, where AVSpeechSynthesizer must be driven.
    public nonisolated func speak(_ text: String, voiceIdentifier: String?) async throws {
        try await performSpeak(text, voiceIdentifier: voiceIdentifier)
    }

    public nonisolated func stopImmediately() async {
        await performStop()
    }

    private func performSpeak(_ text: String, voiceIdentifier: String?) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        performStop()

        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier,
            let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        {
            utterance.voice = voice
        } else {
            utterance.voice =
                Self.bestAvailableEnglishVoice
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.52
        activeUtterance = utterance

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    activeUtterance = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                completion = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.performStop()
            }
        }
    }

    private func performStop() {
        let continuation = completion
        completion = nil
        self.activeUtterance = nil
        // Stopping before AVSpeechSynthesizer has started the utterance does not
        // dequeue it; handleStart(utteranceID:) catches that escape when the
        // orphaned utterance eventually starts.
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume(throwing: CancellationError())
    }

    public static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The highest-quality installed English voice (Premium > Enhanced >
    /// default, preferring en-US within a tier). Siri voices are not exposed
    /// to third-party apps; Premium/Enhanced voices downloaded in System
    /// Settings › Accessibility › Spoken Content appear here automatically.
    public static var bestAvailableEnglishVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { lhs, rhs in
                if lhs.quality != rhs.quality {
                    return lhs.quality.rawValue < rhs.quality.rawValue
                }
                let lhsUS = lhs.language == "en-US"
                let rhsUS = rhs.language == "en-US"
                if lhsUS != rhsUS {
                    return rhsUS
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            }
    }

    private func handleStart(utteranceID _: ObjectIdentifier) {
        // An utterance cancelled before it started stays queued and begins
        // playing later. Kill it as soon as it starts — unless a newer speak()
        // is already pending behind it, in which case stopping would cancel
        // that one too.
        guard activeUtterance == nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finish(utteranceID: ObjectIdentifier, error: Error?) {
        guard let activeUtterance,
            ObjectIdentifier(activeUtterance) == utteranceID
        else {
            return
        }
        self.activeUtterance = nil
        let continuation = completion
        completion = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

private final class AppleSpeechDelegateProxy: NSObject, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    private let onStart: @Sendable (ObjectIdentifier) -> Void
    private let onCompletion: @Sendable (ObjectIdentifier, Bool) -> Void

    init(
        onStart: @escaping @Sendable (ObjectIdentifier) -> Void,
        onCompletion: @escaping @Sendable (ObjectIdentifier, Bool) -> Void
    ) {
        self.onStart = onStart
        self.onCompletion = onCompletion
    }

    func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        onStart(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onCompletion(ObjectIdentifier(utterance), false)
    }

    func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onCompletion(ObjectIdentifier(utterance), true)
    }
}
