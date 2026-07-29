import Foundation

/// Persists lightweight Voice settings without depending on app-layer model types.
/// `UserDefaults` documents its shared instance methods as thread-safe; the
/// unchecked conformance lets a read-only preference closure cross into the
/// MLX recognizer actor without claiming `UserDefaults` is value-semantic.
public struct VoicePreferences: @unchecked Sendable {
    private enum Key {
        static let dictationBackendIdentifier =
            "io.blacktop.Voice.preferences.dictationBackendIdentifier"
        static let speechBackendIdentifier =
            "io.blacktop.Voice.preferences.speechBackendIdentifier"
        static let mlxSpeechVoiceIdentifier =
            "io.blacktop.Voice.preferences.mlxSpeechVoiceIdentifier"
        static let mlxVoiceModeIdentifier =
            "io.blacktop.Voice.preferences.mlxVoiceModeIdentifier"
        static let mlxVoiceStyle =
            "io.blacktop.Voice.preferences.mlxVoiceStyle"
        static let mlxVoiceDescription =
            "io.blacktop.Voice.preferences.mlxVoiceDescription"
        static let mlxCloneReferencePath =
            "io.blacktop.Voice.preferences.mlxCloneReferencePath"
        static let mlxCloneTranscript =
            "io.blacktop.Voice.preferences.mlxCloneTranscript"
        static let acpSessionConfigurationSelections =
            "io.blacktop.Voice.preferences.acpSessionConfigurationSelections"
        static let compatibilityInsertionEnabled =
            "io.blacktop.Voice.preferences.compatibilityInsertionEnabled"
        static let manualSpeechVocabulary =
            "io.blacktop.Voice.preferences.manualSpeechVocabulary"
        static let skipSilentShortMLXAudio =
            "io.blacktop.Voice.preferences.skipSilentShortMLXAudio"
        static let mlxIdleUnloadMinutes =
            "io.blacktop.Voice.preferences.mlxIdleUnloadMinutes"
    }

    private let defaults: UserDefaults

    /// Creates a preference store backed by the supplied defaults domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether PID-targeted Unicode insertion may be used when direct
    /// Accessibility insertion is rejected. Defaults to on: it is a strict
    /// fallback that only runs where the alternative is a failed insertion,
    /// and the editors this is needed for (Zed terminals and similar) are
    /// common targets.
    public var compatibilityInsertionEnabled: Bool {
        defaults.object(forKey: Key.compatibilityInsertionEnabled) as? Bool ?? true
    }

    /// Records an explicit compatibility-insertion choice, in either direction.
    public func setCompatibilityInsertionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.compatibilityInsertionEnabled)
    }

    public var manualSpeechVocabulary: String {
        defaults.string(forKey: Key.manualSpeechVocabulary) ?? ""
    }

    public func setManualSpeechVocabulary(_ vocabulary: String) {
        defaults.set(vocabulary, forKey: Key.manualSpeechVocabulary)
    }

    public var skipSilentShortMLXAudio: Bool {
        defaults.object(forKey: Key.skipSilentShortMLXAudio) as? Bool ?? false
    }

    public func setSkipSilentShortMLXAudio(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.skipSilentShortMLXAudio)
    }

    public var mlxIdleUnloadMinutes: Int {
        defaults.object(forKey: Key.mlxIdleUnloadMinutes) as? Int ?? 0
    }

    public func setMLXIdleUnloadMinutes(_ minutes: Int) {
        defaults.set(minutes, forKey: Key.mlxIdleUnloadMinutes)
    }

    /// The stable identifier for the last successfully selected dictation backend.
    public var dictationBackendIdentifier: String? {
        defaults.string(forKey: Key.dictationBackendIdentifier)
    }

    /// Records the stable identifier for a successfully selected dictation backend.
    public func setDictationBackendIdentifier(_ identifier: String) {
        defaults.set(identifier, forKey: Key.dictationBackendIdentifier)
    }

    /// Removes the persisted dictation backend selection.
    public func clearDictationBackendIdentifier() {
        defaults.removeObject(forKey: Key.dictationBackendIdentifier)
    }

    /// The stable identifier for the last successfully selected speech-output backend.
    public var speechBackendIdentifier: String? {
        defaults.string(forKey: Key.speechBackendIdentifier)
    }

    /// Records the stable identifier for a successfully selected speech-output backend.
    public func setSpeechBackendIdentifier(_ identifier: String) {
        defaults.set(identifier, forKey: Key.speechBackendIdentifier)
    }

    /// The last selected MLX speech voice, if the user chose one.
    public var mlxSpeechVoiceIdentifier: String? {
        defaults.string(forKey: Key.mlxSpeechVoiceIdentifier)
    }

    /// Records the selected MLX speech voice.
    public func setMLXSpeechVoiceIdentifier(_ identifier: String) {
        defaults.set(identifier, forKey: Key.mlxSpeechVoiceIdentifier)
    }

    /// The MLX voice mode (preset, designed, or cloned voice).
    public var mlxVoiceModeIdentifier: String? {
        defaults.string(forKey: Key.mlxVoiceModeIdentifier)
    }

    public func setMLXVoiceModeIdentifier(_ identifier: String) {
        defaults.set(identifier, forKey: Key.mlxVoiceModeIdentifier)
    }

    /// The optional delivery-style instruction ("calm and slow").
    public var mlxVoiceStyle: String? {
        defaults.string(forKey: Key.mlxVoiceStyle)
    }

    public func setMLXVoiceStyle(_ style: String) {
        defaults.set(style, forKey: Key.mlxVoiceStyle)
    }

    /// The natural-language description for a designed voice.
    public var mlxVoiceDescription: String? {
        defaults.string(forKey: Key.mlxVoiceDescription)
    }

    public func setMLXVoiceDescription(_ description: String) {
        defaults.set(description, forKey: Key.mlxVoiceDescription)
    }

    /// The local path of the voice-clone reference clip.
    public var mlxCloneReferencePath: String? {
        defaults.string(forKey: Key.mlxCloneReferencePath)
    }

    public func setMLXCloneReferencePath(_ path: String?) {
        if let path {
            defaults.set(path, forKey: Key.mlxCloneReferencePath)
        } else {
            defaults.removeObject(forKey: Key.mlxCloneReferencePath)
        }
    }

    /// The transcript of the voice-clone reference clip.
    public var mlxCloneTranscript: String? {
        defaults.string(forKey: Key.mlxCloneTranscript)
    }

    public func setMLXCloneTranscript(_ transcript: String) {
        defaults.set(transcript, forKey: Key.mlxCloneTranscript)
    }

    /// Returns select-option preferences scoped to one ACP launcher.
    public func acpSessionConfigurationSelections(
        agentIdentifier: String
    ) -> [String: String] {
        guard
            let agents = defaults.dictionary(
                forKey: Key.acpSessionConfigurationSelections
            ), let selections = agents[agentIdentifier] as? [String: String]
        else {
            return [:]
        }
        return selections
    }

    /// Records one ACP select option without overwriting other agents or options.
    public func setACPConfigurationSelection(
        agentIdentifier: String,
        configID: String,
        value: String
    ) {
        var agents =
            defaults.dictionary(
                forKey: Key.acpSessionConfigurationSelections
            ) ?? [:]
        var selections = agents[agentIdentifier] as? [String: String] ?? [:]
        selections[configID] = value
        agents[agentIdentifier] = selections
        defaults.set(agents, forKey: Key.acpSessionConfigurationSelections)
    }
}
