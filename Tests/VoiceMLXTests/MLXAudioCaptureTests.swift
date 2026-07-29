import AVFAudio
import Foundation
import XCTest

@testable import VoiceMLX

final class MLXAudioCaptureTests: XCTestCase {
    func testStereoInputDownmixPreservesRightChannelAudio() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let input = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480)
        )
        input.frameLength = 480
        let channels = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<Int(input.frameLength) {
            channels[0][frame] = 0
            channels[1][frame] = 1
        }
        let converter = try XCTUnwrap(
            AVAudioConverter(from: inputFormat, to: outputFormat)
        )
        converter.downmix = inputFormat.channelCount > outputFormat.channelCount

        let output = try MLXAudioCapture.convert(
            input,
            using: converter,
            outputFormat: outputFormat
        )
        let samples = try MLXAudioCapture.monoSamples(from: output)

        XCTAssertFalse(samples.isEmpty)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    func testUnspecifiedCoreAudioFailureRecreatesEngineAndRetriesOnce() throws {
        var attempts = 0
        var recoveries = 0

        let result: String = try MLXAudioCapture.startWithOneRecovery(
            start: {
                attempts += 1
                if attempts == 1 {
                    throw unspecifiedCoreAudioError
                }
                return "started"
            },
            recover: {
                recoveries += 1
            }
        )

        XCTAssertEqual(result, "started")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(recoveries, 1)
    }

    func testRepeatedUnspecifiedCoreAudioFailureUsesActionableError() {
        var attempts = 0

        XCTAssertThrowsError(
            try MLXAudioCapture.startWithOneRecovery(
                start: {
                    attempts += 1
                    throw unspecifiedCoreAudioError
                },
                recover: {}
            ) as Void
        ) { error in
            guard case MLXSpeechRecognizerError.audioEngineUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(attempts, 2)
    }

    func testOtherAudioFailureIsNotRetried() {
        let originalError = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: -10_877
        )
        var attempts = 0
        var recoveries = 0

        XCTAssertThrowsError(
            try MLXAudioCapture.startWithOneRecovery(
                start: {
                    attempts += 1
                    throw originalError
                },
                recover: {
                    recoveries += 1
                }
            ) as Void
        ) { error in
            XCTAssertEqual(error as NSError, originalError)
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(recoveries, 0)
    }

    private var unspecifiedCoreAudioError: NSError {
        NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: 2_003_329_396
        )
    }

    // MARK: - Configuration-change race guards

    func testConfigurationChangeMidCaptureFailsSession() {
        XCTAssertTrue(
            MLXAudioCapture.shouldFailSessionOnConfigurationChange(
                notifiedEngineIsCurrent: true,
                isEngineStarted: true,
                isStopping: false,
                hasActiveGeneration: true,
                hasTerminalError: false
            )
        )
    }

    func testConfigurationChangeDuringFailedStartAttemptIsIgnored() {
        // Capture state (generation, failure handler) is installed before
        // engine.start(); a notification racing a start that then throws must
        // not fail the session the recovery retry is about to establish.
        XCTAssertFalse(
            MLXAudioCapture.shouldFailSessionOnConfigurationChange(
                notifiedEngineIsCurrent: true,
                isEngineStarted: false,
                isStopping: false,
                hasActiveGeneration: true,
                hasTerminalError: false
            )
        )
    }

    func testConfigurationChangeFromReplacedEngineIsIgnored() {
        // An in-flight delivery for the engine that recovery discarded must
        // not cancel the fresh session running on the replacement engine.
        XCTAssertFalse(
            MLXAudioCapture.shouldFailSessionOnConfigurationChange(
                notifiedEngineIsCurrent: false,
                isEngineStarted: true,
                isStopping: false,
                hasActiveGeneration: true,
                hasTerminalError: false
            )
        )
    }

    func testConfigurationChangeWhileStoppingIsIgnored() {
        XCTAssertFalse(
            MLXAudioCapture.shouldFailSessionOnConfigurationChange(
                notifiedEngineIsCurrent: true,
                isEngineStarted: true,
                isStopping: true,
                hasActiveGeneration: true,
                hasTerminalError: false
            )
        )
    }

    func testConfigurationChangeWithoutActiveSessionIsIgnored() {
        XCTAssertFalse(
            MLXAudioCapture.shouldFailSessionOnConfigurationChange(
                notifiedEngineIsCurrent: true,
                isEngineStarted: true,
                isStopping: false,
                hasActiveGeneration: false,
                hasTerminalError: false
            )
        )
    }

    func testConfigurationChangeAfterTerminalErrorIsIgnored() {
        XCTAssertFalse(
            MLXAudioCapture.shouldFailSessionOnConfigurationChange(
                notifiedEngineIsCurrent: true,
                isEngineStarted: true,
                isStopping: false,
                hasActiveGeneration: true,
                hasTerminalError: true
            )
        )
    }
}
