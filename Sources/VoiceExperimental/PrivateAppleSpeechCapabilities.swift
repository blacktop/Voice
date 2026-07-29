import Foundation
import VoiceCore

public struct PrivateAppleCapability: Hashable, Sendable {
    public let framework: String
    public let isPresent: Bool
    public let notes: String

    public init(framework: String, isPresent: Bool, notes: String) {
        self.framework = framework
        self.isPresent = isPresent
        self.notes = notes
    }
}

/// Capability discovery only. No private framework is a linked dependency.
public enum PrivateAppleSpeechCapabilities {
    public static func probe() -> [PrivateAppleCapability] {
        guard UserDefaults.standard.bool(forKey: "EnablePrivateAppleCapabilityProbes") else {
            return []
        }
        return [
            probeFrameworkPresence(
                "CoreEmbeddedSpeechRecognition",
                notes:
                    "Experimental embedded speech recognizer; service access may require private entitlements."
            ),
            probeFrameworkPresence(
                "SpeechRecognitionCore",
                notes:
                    "Experimental recognition service; public SpeechAnalyzer remains the required fallback."
            ),
            probeFrameworkPresence(
                "TextToSpeech",
                notes:
                    "Experimental Siri-quality voices; AVSpeechSynthesizer remains the required fallback."
            ),
            probeFrameworkPresence(
                "SiriTTS",
                notes: "Research-only unless ordinary Developer ID signing can use the service."
            ),
        ]
    }

    private static func probeFrameworkPresence(
        _ name: String,
        notes: String
    ) -> PrivateAppleCapability {
        let binary = "/System/Library/PrivateFrameworks/\(name).framework/\(name)"
        return PrivateAppleCapability(
            framework: name,
            isPresent: FileManager.default.isExecutableFile(atPath: binary),
            notes: notes
        )
    }
}
