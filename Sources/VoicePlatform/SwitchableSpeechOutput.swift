import Foundation
import VoiceCore

/// Routes speech output to the engine the user selected. VoiceSession holds
/// one SpeechOutputting for its lifetime, so switching between the system
/// synthesizer and an opt-in local model happens here instead of rebuilding
/// the session.
public actor SwitchableSpeechOutput: SpeechOutputting {
    private var engine: any SpeechOutputting

    public init(engine: any SpeechOutputting) {
        self.engine = engine
    }

    /// Silences the previous engine before routing to the new one so a switch
    /// during playback cannot leave two voices speaking.
    public func setEngine(_ newEngine: any SpeechOutputting) async {
        await engine.stopImmediately()
        engine = newEngine
    }

    public func speak(_ text: String, voiceIdentifier: String?) async throws {
        try await engine.speak(text, voiceIdentifier: voiceIdentifier)
    }

    public func stopImmediately() async {
        await engine.stopImmediately()
    }
}
