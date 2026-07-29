import Foundation
import VoiceCore
import XCTest

@testable import VoicePlatform

final class SwitchableSpeechOutputTests: XCTestCase {
    func testSpeakAndStopRouteToTheCurrentEngine() async throws {
        let engine = RecordingSpeechOutput()
        let router = SwitchableSpeechOutput(engine: engine)

        try await router.speak("hello", voiceIdentifier: "voice-1")
        await router.stopImmediately()

        let events = await engine.events
        XCTAssertEqual(events, [.spoke("hello", "voice-1"), .stopped])
    }

    func testSwitchingEnginesSilencesThePreviousEngineFirst() async throws {
        let first = RecordingSpeechOutput()
        let second = RecordingSpeechOutput()
        let router = SwitchableSpeechOutput(engine: first)

        await router.setEngine(second)
        try await router.speak("after switch", voiceIdentifier: nil)

        let firstEvents = await first.events
        let secondEvents = await second.events
        XCTAssertEqual(firstEvents, [.stopped])
        XCTAssertEqual(secondEvents, [.spoke("after switch", nil)])
    }

    func testSpeakErrorsPropagateThroughTheRouter() async {
        let engine = RecordingSpeechOutput(speakError: CancellationError())
        let router = SwitchableSpeechOutput(engine: engine)

        do {
            try await router.speak("interrupted", voiceIdentifier: nil)
            XCTFail("Expected the engine's error to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

private actor RecordingSpeechOutput: SpeechOutputting {
    enum Event: Equatable {
        case spoke(String, String?)
        case stopped
    }

    private(set) var events: [Event] = []
    private let speakError: Error?

    init(speakError: Error? = nil) {
        self.speakError = speakError
    }

    func speak(_ text: String, voiceIdentifier: String?) async throws {
        events.append(.spoke(text, voiceIdentifier))
        if let speakError {
            throw speakError
        }
    }

    func stopImmediately() async {
        events.append(.stopped)
    }
}
