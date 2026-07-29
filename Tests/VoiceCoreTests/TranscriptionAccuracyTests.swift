import XCTest

@testable import VoiceCore

final class TranscriptionAccuracyTests: XCTestCase {
    func testPerfectMatchHasZeroErrors() {
        let wer = WordErrorRate.compute(
            reference: "hold the hotkey to dictate",
            hypothesis: "hold the hotkey to dictate"
        )
        XCTAssertEqual(wer.errorCount, 0)
        XCTAssertEqual(wer.rate, 0.0)
        XCTAssertEqual(wer.referenceWordCount, 5)
    }

    func testCaseAndPunctuationDoNotCountAsErrors() {
        let wer = WordErrorRate.compute(
            reference: "Hold the hotkey, then speak.",
            hypothesis: "hold the hotkey then speak"
        )
        XCTAssertEqual(wer.errorCount, 0)
    }

    func testSingleSubstitution() {
        let wer = WordErrorRate.compute(
            reference: "run the tests now",
            hypothesis: "run the test now"
        )
        XCTAssertEqual(wer.substitutions, 1)
        XCTAssertEqual(wer.insertions, 0)
        XCTAssertEqual(wer.deletions, 0)
        XCTAssertEqual(wer.rate, 0.25)
    }

    func testInsertionAndDeletionAreCountedSeparately() {
        let inserted = WordErrorRate.compute(
            reference: "open the file",
            hypothesis: "open up the file"
        )
        XCTAssertEqual(inserted.insertions, 1)
        XCTAssertEqual(inserted.errorCount, 1)

        let deleted = WordErrorRate.compute(
            reference: "open up the file",
            hypothesis: "open the file"
        )
        XCTAssertEqual(deleted.deletions, 1)
        XCTAssertEqual(deleted.errorCount, 1)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let wer = WordErrorRate.compute(reference: "three word phrase", hypothesis: "")
        XCTAssertEqual(wer.deletions, 3)
        XCTAssertEqual(wer.rate, 1.0)
    }

    func testEmptyReferenceHasUndefinedRate() {
        let wer = WordErrorRate.compute(reference: "", hypothesis: "spurious words")
        XCTAssertEqual(wer.insertions, 2)
        XCTAssertNil(wer.rate)
    }

    func testRateCanExceedOne() {
        let wer = WordErrorRate.compute(
            reference: "stop",
            hypothesis: "please stop doing that"
        )
        XCTAssertEqual(wer.errorCount, 3)
        XCTAssertEqual(wer.rate, 3.0)
    }

    func testApostrophesStayInsideWords() {
        let wer = WordErrorRate.compute(
            reference: "don't stop",
            hypothesis: "dont stop"
        )
        XCTAssertEqual(wer.errorCount, 1)
    }

    func testAlignmentPrefersCheapestEditPath() {
        // "a b c d" vs "a c d" is one deletion, not two substitutions.
        let wer = WordErrorRate.compute(
            reference: "a b c d",
            hypothesis: "a c d"
        )
        XCTAssertEqual(wer.deletions, 1)
        XCTAssertEqual(wer.substitutions, 0)
        XCTAssertEqual(wer.errorCount, 1)
    }

    func testTotalErrorCountMatchesLevenshteinDistance() {
        // Word-level distance cross-checked against a reference
        // character-free example computed by hand.
        let wer = WordErrorRate.compute(
            reference: "the quick brown fox jumps over the lazy dog",
            hypothesis: "the brown fox jumped over a lazy dog"
        )
        // quick deleted, jumps→jumped, the→a
        XCTAssertEqual(wer.deletions, 1)
        XCTAssertEqual(wer.substitutions, 2)
        XCTAssertEqual(wer.insertions, 0)
    }
}
