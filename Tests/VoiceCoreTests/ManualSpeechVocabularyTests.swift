import VoiceCore
import XCTest

final class ManualSpeechVocabularyTests: XCTestCase {
    func testParsesExplicitTermsWithoutChangingPreferredSpelling() {
        XCTAssertEqual(
            ManualSpeechVocabulary.terms(
                from: " MLX\nAVAudioEngine, mlx,  Café , cafe "
            ),
            ["MLX", "AVAudioEngine", "Café"]
        )
    }

    func testPreferredTermsWinDuringBoundedMerge() {
        XCTAssertEqual(
            ManualSpeechVocabulary.merge(
                preferredTerms: ["Codex", "Voice"],
                projectTerms: ["voice", "Swift", "AppKit"],
                limit: 3
            ),
            ["Codex", "Voice", "Swift"]
        )
    }
}
