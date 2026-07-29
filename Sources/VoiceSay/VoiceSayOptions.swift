import Foundation
import VoiceMLX
import VoicePlatform

/// The voice the app is configured to use. Reusing it means `voice-say` speaks
/// in the same voice as Voice itself, and reuses the checkpoint the app has
/// already downloaded, instead of pulling a second one.
struct VoiceSayDefaults: Equatable {
    var tier: MLXSpeechModelTier = .small
    var voice: MLXSpeechVoice = .ryan
    var style: String?
    var description: String?
    var cloneURL: URL?
    var cloneTranscript: String?

    /// The app's preference domain. A CLI's `UserDefaults.standard` is its own
    /// domain, so reading the app's settings requires naming the suite; without
    /// this the CLI silently falls back to built-in defaults and speaks in the
    /// wrong voice with a checkpoint the app never downloaded.
    static let appPreferenceSuite = "io.blacktop.Voice"

    static func fromAppPreferences() -> VoiceSayDefaults {
        // UserDefaults(suiteName:) returns nil when the suite matches the main
        // bundle's own identifier, which is the case for the copy embedded in
        // Voice.app. There `.standard` already is the app's domain, so falling
        // back to it keeps the embedded tool reading the same settings as the
        // standalone one instead of silently reverting to built-in defaults.
        let defaults = UserDefaults(suiteName: appPreferenceSuite) ?? .standard
        return fromAppPreferences(VoicePreferences(defaults: defaults))
    }

    static func fromAppPreferences(_ preferences: VoicePreferences) -> VoiceSayDefaults {
        var defaults = VoiceSayDefaults()
        if let identifier = preferences.speechBackendIdentifier,
            let backend = MLXSpeechBackendPreference(rawValue: identifier)
        {
            defaults.tier = backend.tier
        }
        if let name = preferences.mlxSpeechVoiceIdentifier,
            let voice = MLXSpeechVoice(rawValue: name)
        {
            defaults.voice = voice
        }
        // Only the mode the app last used contributes its fields, so a stale
        // description does not silently override a preset voice.
        switch preferences.mlxVoiceModeIdentifier {
        case "designed":
            defaults.description = nonEmpty(preferences.mlxVoiceDescription)
        case "cloned":
            defaults.cloneURL = preferences.mlxCloneReferencePath.map {
                URL(fileURLWithPath: $0)
            }
            defaults.cloneTranscript = nonEmpty(preferences.mlxCloneTranscript)
            defaults.style = nonEmpty(preferences.mlxVoiceStyle)
        default:
            defaults.style = nonEmpty(preferences.mlxVoiceStyle)
        }
        return defaults
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Mirrors the app's speech-backend identifiers so the CLI can map a stored
/// preference onto a tier without depending on the app target.
enum MLXSpeechBackendPreference: String {
    case small = "qwen3-tts-0.6b-8bit"
    case large = "qwen3-tts-1.7b-8bit"

    var tier: MLXSpeechModelTier {
        switch self {
        case .small: .small
        case .large: .large
        }
    }
}

/// Whatever the caller named on the command line. Nil means "keep the app's
/// setting", which is what makes a bare invocation match the app.
struct VoiceSayOverrides: Equatable {
    var voice: MLXSpeechVoice?
    var tier: MLXSpeechModelTier?
    var style: String?
    var description: String?
    var cloneURL: URL?
    var cloneTranscript: String?
}

/// The resolved voice for one invocation. Separated from argument parsing so
/// the precedence rules are testable without loading a multi-gigabyte model.
struct VoiceSayOptions: Equatable {
    let tier: MLXSpeechModelTier
    let configuration: MLXVoiceConfiguration

    init(overrides: VoiceSayOverrides, defaults: VoiceSayDefaults) {
        tier = overrides.tier ?? defaults.tier
        let style = overrides.style ?? defaults.style

        // An explicit mode replaces an inherited one, and asking for a preset
        // voice means a preset is wanted rather than the app's described or
        // cloned voice. Two explicit modes are rejected before this point.
        if let description = overrides.description {
            configuration = .designed(description: description)
        } else if let cloneURL = overrides.cloneURL {
            configuration = .cloned(
                referenceAudioURL: cloneURL,
                transcript: overrides.cloneTranscript ?? defaults.cloneTranscript ?? "",
                style: style
            )
        } else if overrides.voice != nil {
            configuration = .preset(overrides.voice ?? defaults.voice, style: style)
        } else if let description = defaults.description {
            configuration = .designed(description: description)
        } else if let cloneURL = defaults.cloneURL {
            configuration = .cloned(
                referenceAudioURL: cloneURL,
                // An explicit transcript still wins over the stored one, so the
                // caller can correct a wrong transcript without also re-passing
                // the clip path they did not change.
                transcript: overrides.cloneTranscript ?? defaults.cloneTranscript ?? "",
                style: style
            )
        } else {
            configuration = .preset(defaults.voice, style: style)
        }
    }

    /// Described voices only exist as the 1.7B VoiceDesign checkpoint, so the
    /// tier does not apply there.
    var checkpoint: MLXSpeechCheckpoint {
        MLXSpeechCheckpoint.checkpoint(tier: tier, configuration: configuration)
    }
}
