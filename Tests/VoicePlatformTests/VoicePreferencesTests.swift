import Foundation
import XCTest

@testable import VoicePlatform

final class VoicePreferencesTests: XCTestCase {
    func testCompatibilityInsertionDefaultsToEnabled() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        XCTAssertTrue(fixture.preferences.compatibilityInsertionEnabled)
    }

    func testCompatibilityInsertionDisabledChoiceSurvivesRelaunch() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        // An explicit "off" must not be re-defaulted back to on, which is what
        // distinguishes a stored false from an absent value.
        fixture.preferences.setCompatibilityInsertionEnabled(false)
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let secondPreferences = VoicePreferences(defaults: secondDefaults)

        XCTAssertFalse(secondPreferences.compatibilityInsertionEnabled)
    }

    func testCompatibilityInsertionReEnabledChoiceRoundTrips() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        fixture.preferences.setCompatibilityInsertionEnabled(false)
        fixture.preferences.setCompatibilityInsertionEnabled(true)
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let secondPreferences = VoicePreferences(defaults: secondDefaults)

        XCTAssertTrue(secondPreferences.compatibilityInsertionEnabled)
    }

    func testDictationBackendIdentifierIsAbsentByDefault() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        XCTAssertNil(fixture.preferences.dictationBackendIdentifier)
    }

    func testConservativeSpeechOptionsDefaultOffAndRoundTrip() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        XCTAssertEqual(fixture.preferences.manualSpeechVocabulary, "")
        XCTAssertFalse(fixture.preferences.skipSilentShortMLXAudio)
        XCTAssertEqual(fixture.preferences.mlxIdleUnloadMinutes, 0)

        fixture.preferences.setManualSpeechVocabulary("MLX, AVAudioEngine")
        fixture.preferences.setSkipSilentShortMLXAudio(true)
        fixture.preferences.setMLXIdleUnloadMinutes(15)
        let reopenedDefaults = try XCTUnwrap(
            UserDefaults(suiteName: fixture.suiteName)
        )
        let reopened = VoicePreferences(defaults: reopenedDefaults)

        XCTAssertEqual(reopened.manualSpeechVocabulary, "MLX, AVAudioEngine")
        XCTAssertTrue(reopened.skipSilentShortMLXAudio)
        XCTAssertEqual(reopened.mlxIdleUnloadMinutes, 15)
    }

    func testDictationBackendIdentifierRoundTripsAcrossInstances() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        fixture.preferences.setDictationBackendIdentifier("qwen3-asr-0.6b-8bit")
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let secondPreferences = VoicePreferences(defaults: secondDefaults)

        XCTAssertEqual(
            secondPreferences.dictationBackendIdentifier,
            "qwen3-asr-0.6b-8bit"
        )
    }

    func testSettingDictationBackendIdentifierOverwritesPreviousValue() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        fixture.preferences.setDictationBackendIdentifier("qwen3-asr-0.6b-8bit")
        fixture.preferences.setDictationBackendIdentifier("qwen3-asr-1.7b-8bit")

        XCTAssertEqual(
            fixture.preferences.dictationBackendIdentifier,
            "qwen3-asr-1.7b-8bit"
        )
    }

    func testClearRemovesDictationBackendIdentifier() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }
        fixture.preferences.setDictationBackendIdentifier("qwen3-asr-0.6b-8bit")

        fixture.preferences.clearDictationBackendIdentifier()

        XCTAssertNil(fixture.preferences.dictationBackendIdentifier)
    }

    func testSpeechBackendAndVoiceIdentifiersRoundTripAcrossInstances() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        XCTAssertNil(fixture.preferences.speechBackendIdentifier)
        XCTAssertNil(fixture.preferences.mlxSpeechVoiceIdentifier)

        fixture.preferences.setSpeechBackendIdentifier("qwen3-tts-0.6b-8bit")
        fixture.preferences.setMLXSpeechVoiceIdentifier("Ryan")
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let secondPreferences = VoicePreferences(defaults: secondDefaults)

        XCTAssertEqual(
            secondPreferences.speechBackendIdentifier,
            "qwen3-tts-0.6b-8bit"
        )
        XCTAssertEqual(secondPreferences.mlxSpeechVoiceIdentifier, "Ryan")
    }

    func testACPConfigurationSelectionsAreScopedByAgentAndOption() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.cleanup() }

        fixture.preferences.setACPConfigurationSelection(
            agentIdentifier: "zed-claude",
            configID: "model",
            value: "claude-opus-4-6"
        )
        fixture.preferences.setACPConfigurationSelection(
            agentIdentifier: "zed-claude",
            configID: "effort",
            value: "high"
        )
        fixture.preferences.setACPConfigurationSelection(
            agentIdentifier: "zed-codex",
            configID: "model",
            value: "gpt-5.4"
        )

        XCTAssertEqual(
            fixture.preferences.acpSessionConfigurationSelections(
                agentIdentifier: "zed-claude"
            ),
            ["effort": "high", "model": "claude-opus-4-6"]
        )
        XCTAssertEqual(
            fixture.preferences.acpSessionConfigurationSelections(
                agentIdentifier: "zed-codex"
            ),
            ["model": "gpt-5.4"]
        )
        XCTAssertTrue(
            fixture.preferences.acpSessionConfigurationSelections(
                agentIdentifier: "custom-agent"
            ).isEmpty
        )
    }

    func testSuitesAreIsolatedAndCleanupRemovesPersistedValue() throws {
        let firstFixture = try PreferenceFixture()
        let secondFixture = try PreferenceFixture()
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        firstFixture.preferences.setDictationBackendIdentifier("qwen3-asr-0.6b-8bit")

        XCTAssertNil(secondFixture.preferences.dictationBackendIdentifier)

        firstFixture.cleanup()
        let reopenedDefaults = try XCTUnwrap(
            UserDefaults(suiteName: firstFixture.suiteName)
        )
        let reopenedPreferences = VoicePreferences(defaults: reopenedDefaults)
        XCTAssertNil(reopenedPreferences.dictationBackendIdentifier)
    }
}

private struct PreferenceFixture {
    let suiteName: String
    let defaults: UserDefaults
    let preferences: VoicePreferences

    init() throws {
        let suiteName = "VoicePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        self.suiteName = suiteName
        self.defaults = defaults
        preferences = VoicePreferences(defaults: defaults)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
