import XCTest

@testable import VoiceMLX

/// Argument parsing itself is ArgumentParser's job; these cover the precedence
/// rules between command-line overrides and the app's configured voice.
final class VoiceSayOptionsTests: XCTestCase {
    private var appDefaults: VoiceSayDefaults {
        var defaults = VoiceSayDefaults()
        defaults.tier = .large
        defaults.voice = .aiden
        defaults.style = "curious and nervous"
        return defaults
    }

    private func resolve(
        _ overrides: VoiceSayOverrides = VoiceSayOverrides(),
        defaults: VoiceSayDefaults = VoiceSayDefaults()
    ) -> VoiceSayOptions {
        VoiceSayOptions(overrides: overrides, defaults: defaults)
    }

    func testBreezeEngineSelectsTheSingleBreezeCheckpoint() {
        var breezeDefaults = appDefaults
        breezeDefaults.family = .breeze
        breezeDefaults.description = "a narrator"
        let inherited = resolve(defaults: breezeDefaults)
        XCTAssertEqual(inherited.family, .breeze)
        XCTAssertEqual(inherited.checkpoint, .breezeExperimental)
        XCTAssertEqual(inherited.configuration, .designed(description: "a narrator"))

        let described = resolve(
            VoiceSayOverrides(family: .breeze, description: "a narrator"),
            defaults: appDefaults
        )
        XCTAssertEqual(described.checkpoint, .breezeExperimental)

        // The described voice carries over, so Qwen3-TTS serves it with VoiceDesign.
        let backToQwen = resolve(VoiceSayOverrides(family: .qwen3), defaults: breezeDefaults)
        XCTAssertEqual(backToQwen.checkpoint, .voiceDesignLarge)
    }

    func testBreezeWithAnInheritedPresetVoiceIsRejected() {
        var breezeDefaults = appDefaults
        breezeDefaults.family = .breeze
        let inheritedPreset = resolve(defaults: breezeDefaults)
        XCTAssertThrowsError(try inheritedPreset.validated()) { error in
            XCTAssertEqual(error as? VoiceSayOptionsError, .presetUnsupportedByBreeze)
        }

        let described = resolve(
            VoiceSayOverrides(family: .breeze, description: "a narrator"),
            defaults: appDefaults
        )
        XCTAssertNoThrow(try described.validated())

        let qwenPreset = resolve(defaults: appDefaults)
        XCTAssertNoThrow(try qwenPreset.validated())
    }

    func testAppPreferenceMapsBreezeIdentifier() {
        XCTAssertEqual(MLXSpeechBackendPreference(rawValue: "breeze-tts-2-4bit")?.family, .breeze)
        XCTAssertEqual(MLXSpeechBackendPreference(rawValue: "qwen3-tts-1.7b-8bit")?.family, .qwen3)
        XCTAssertEqual(MLXSpeechBackendPreference(rawValue: "qwen3-tts-1.7b-8bit")?.tier, .large)
    }

    func testNoOverridesUsesTheAppsVoiceAndTier() {
        let options = resolve(defaults: appDefaults)
        XCTAssertEqual(options.tier, .large)
        XCTAssertEqual(options.configuration, .preset(.aiden, style: "curious and nervous"))
        XCTAssertEqual(options.checkpoint, .customVoiceLarge)
    }

    func testBuiltInDefaultsWhenTheAppHasNoPreferences() {
        let options = resolve()
        XCTAssertEqual(options.tier, .small)
        XCTAssertEqual(options.configuration, .preset(.ryan, style: nil))
        XCTAssertEqual(options.checkpoint, .customVoiceSmall)
    }

    func testOverridesReplaceTheAppsSettings() {
        let options = resolve(
            VoiceSayOverrides(voice: .ryan, tier: .small, style: "flat"),
            defaults: appDefaults
        )
        XCTAssertEqual(options.configuration, .preset(.ryan, style: "flat"))
        XCTAssertEqual(options.checkpoint, .customVoiceSmall)
    }

    func testEachOverrideAppliesIndependently() {
        let tierOnly = resolve(VoiceSayOverrides(tier: .small), defaults: appDefaults)
        XCTAssertEqual(tierOnly.checkpoint, .customVoiceSmall)
        // The speaker and style still come from the app.
        XCTAssertEqual(tierOnly.configuration, .preset(.aiden, style: "curious and nervous"))

        let voiceOnly = resolve(VoiceSayOverrides(voice: .ryan), defaults: appDefaults)
        XCTAssertEqual(voiceOnly.tier, .large)
        XCTAssertEqual(voiceOnly.configuration, .preset(.ryan, style: "curious and nervous"))
    }

    func testDescribedVoiceAlwaysUsesTheVoiceDesignCheckpoint() {
        let options = resolve(
            VoiceSayOverrides(tier: .small, description: "a warm narrator")
        )
        XCTAssertEqual(options.configuration, .designed(description: "a warm narrator"))
        XCTAssertEqual(options.checkpoint, .voiceDesignLarge)
    }

    func testInheritedDescribedVoiceIsUsedWhenNothingOverridesIt() {
        var defaults = VoiceSayDefaults()
        defaults.description = "a raspy old smoker"
        XCTAssertEqual(
            resolve(defaults: defaults).configuration,
            .designed(description: "a raspy old smoker")
        )
    }

    func testExplicitPresetVoiceOverridesAnInheritedDescribedVoice() {
        var defaults = VoiceSayDefaults()
        defaults.description = "a raspy old smoker"
        // Asking for a preset must not keep speaking in the app's described voice.
        XCTAssertEqual(
            resolve(VoiceSayOverrides(voice: .ryan), defaults: defaults).configuration,
            .preset(.ryan, style: nil)
        )
    }

    func testExplicitCloneOverridesAnInheritedDescribedVoice() {
        var defaults = VoiceSayDefaults()
        defaults.description = "a raspy old smoker"
        let options = resolve(
            VoiceSayOverrides(
                cloneURL: URL(fileURLWithPath: "/tmp/r.wav"),
                cloneTranscript: "words"
            ),
            defaults: defaults
        )
        XCTAssertEqual(
            options.configuration,
            .cloned(
                referenceAudioURL: URL(fileURLWithPath: "/tmp/r.wav"),
                transcript: "words",
                style: nil
            )
        )
        XCTAssertEqual(options.checkpoint, .baseSmall)
    }

    func testInheritedCloneSuppliesItsStoredTranscript() {
        var defaults = VoiceSayDefaults()
        defaults.cloneURL = URL(fileURLWithPath: "/tmp/ref.wav")
        defaults.cloneTranscript = "stored words"
        XCTAssertEqual(
            resolve(defaults: defaults).configuration,
            .cloned(
                referenceAudioURL: URL(fileURLWithPath: "/tmp/ref.wav"),
                transcript: "stored words",
                style: nil
            )
        )
    }

    func testExplicitTranscriptOverridesTheStoredOneForAnInheritedClip() {
        var defaults = VoiceSayDefaults()
        defaults.cloneURL = URL(fileURLWithPath: "/tmp/ref.wav")
        defaults.cloneTranscript = "stored words"
        // Correcting a wrong stored transcript must not require re-passing the
        // clip path that did not change.
        let options = resolve(
            VoiceSayOverrides(cloneTranscript: "the words actually spoken"),
            defaults: defaults
        )
        XCTAssertEqual(
            options.configuration,
            .cloned(
                referenceAudioURL: URL(fileURLWithPath: "/tmp/ref.wav"),
                transcript: "the words actually spoken",
                style: nil
            )
        )
    }

    func testStyleOverrideAppliesToAClonedVoice() {
        var defaults = VoiceSayDefaults()
        defaults.cloneURL = URL(fileURLWithPath: "/tmp/ref.wav")
        defaults.cloneTranscript = "stored words"
        let options = resolve(VoiceSayOverrides(style: "with an accent"), defaults: defaults)
        XCTAssertEqual(
            options.configuration,
            .cloned(
                referenceAudioURL: URL(fileURLWithPath: "/tmp/ref.wav"),
                transcript: "stored words",
                style: "with an accent"
            )
        )
    }

    func testBackendPreferenceMapsToTier() {
        XCTAssertEqual(MLXSpeechBackendPreference(rawValue: "qwen3-tts-0.6b-8bit")?.tier, .small)
        XCTAssertEqual(MLXSpeechBackendPreference(rawValue: "qwen3-tts-1.7b-8bit")?.tier, .large)
        XCTAssertNil(MLXSpeechBackendPreference(rawValue: "system"))
    }
}
