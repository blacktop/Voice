import XCTest

@testable import VoiceMLX
@testable import VoicePlatform

/// Covers the preferences→defaults mapping. This is the function whose wrong
/// UserDefaults domain shipped as a real bug: the CLI silently spoke in the
/// built-in voice instead of the one Settings was configured with.
final class VoiceSayDefaultsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "voice-say-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    private func resolve() -> VoiceSayDefaults {
        VoiceSayDefaults.fromAppPreferences(VoicePreferences(defaults: defaults))
    }

    func testEmptyPreferencesYieldBuiltInDefaults() {
        let result = resolve()
        XCTAssertEqual(result.tier, .small)
        XCTAssertEqual(result.voice, .ryan)
        XCTAssertNil(result.style)
        XCTAssertNil(result.description)
        XCTAssertNil(result.cloneURL)
    }

    func testSpeechBackendSelectsTier() {
        let preferences = VoicePreferences(defaults: defaults)
        preferences.setSpeechBackendIdentifier("qwen3-tts-1.7b-8bit")
        XCTAssertEqual(resolve().tier, .large)
        preferences.setSpeechBackendIdentifier("qwen3-tts-0.6b-8bit")
        XCTAssertEqual(resolve().tier, .small)
    }

    func testSystemSpeechBackendLeavesTierAtDefault() {
        VoicePreferences(defaults: defaults).setSpeechBackendIdentifier("system")
        XCTAssertEqual(resolve().tier, .small)
    }

    func testVoiceIdentifierIsRestored() {
        VoicePreferences(defaults: defaults).setMLXSpeechVoiceIdentifier("Aiden")
        XCTAssertEqual(resolve().voice, .aiden)
    }

    func testPresetModeCarriesStyleOnly() {
        let preferences = VoicePreferences(defaults: defaults)
        preferences.setMLXVoiceModeIdentifier("preset")
        preferences.setMLXVoiceStyle("calm and unhurried")
        preferences.setMLXVoiceDescription("a raspy narrator")

        let result = resolve()
        XCTAssertEqual(result.style, "calm and unhurried")
        // A description left over from a previous mode must not leak into a
        // preset voice.
        XCTAssertNil(result.description)
    }

    func testDesignedModeCarriesDescriptionOnly() {
        let preferences = VoicePreferences(defaults: defaults)
        preferences.setMLXVoiceModeIdentifier("designed")
        preferences.setMLXVoiceDescription("a raspy narrator")
        preferences.setMLXVoiceStyle("calm")

        let result = resolve()
        XCTAssertEqual(result.description, "a raspy narrator")
        XCTAssertNil(result.style)
    }

    func testClonedModeCarriesClipTranscriptAndStyle() {
        let preferences = VoicePreferences(defaults: defaults)
        preferences.setMLXVoiceModeIdentifier("cloned")
        preferences.setMLXCloneReferencePath("/tmp/ref.wav")
        preferences.setMLXCloneTranscript("the exact words")
        preferences.setMLXVoiceStyle("with an accent")

        let result = resolve()
        XCTAssertEqual(result.cloneURL, URL(fileURLWithPath: "/tmp/ref.wav"))
        XCTAssertEqual(result.cloneTranscript, "the exact words")
        XCTAssertEqual(result.style, "with an accent")
        XCTAssertNil(result.description)
    }

    func testWhitespaceOnlyValuesAreTreatedAsAbsent() {
        let preferences = VoicePreferences(defaults: defaults)
        preferences.setMLXVoiceModeIdentifier("preset")
        preferences.setMLXVoiceStyle("   ")
        XCTAssertNil(resolve().style)
    }

    func testUnknownVoiceIdentifierFallsBackRatherThanCrashing() {
        VoicePreferences(defaults: defaults).setMLXSpeechVoiceIdentifier("Siri")
        XCTAssertEqual(resolve().voice, .ryan)
    }
}
