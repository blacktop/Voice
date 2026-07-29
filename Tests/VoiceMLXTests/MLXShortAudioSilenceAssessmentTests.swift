import XCTest

@testable import VoiceMLX

final class MLXShortAudioSilenceAssessmentTests: XCTestCase {
    func testRejectsShortNearSilence() {
        XCTAssertTrue(
            MLXShortAudioSilenceAssessment.isSilent(
                samples: Array(repeating: 0.001, count: 16_000),
                sampleRate: 16_000
            )
        )
    }

    func testKeepsShortSpeechLikeBurst() {
        var samples = Array(repeating: Float.zero, count: 16_000)
        for index in 4_000..<4_400 {
            samples[index] = 0.1
        }
        XCTAssertFalse(
            MLXShortAudioSilenceAssessment.isSilent(
                samples: samples,
                sampleRate: 16_000
            )
        )
    }

    func testFailsOpenForLongOrNonFiniteAudio() {
        XCTAssertFalse(
            MLXShortAudioSilenceAssessment.isSilent(
                samples: Array(repeating: 0, count: 64_000),
                sampleRate: 16_000
            )
        )
        XCTAssertFalse(
            MLXShortAudioSilenceAssessment.isSilent(
                samples: [0, .nan, 0],
                sampleRate: 16_000
            )
        )
    }
}
