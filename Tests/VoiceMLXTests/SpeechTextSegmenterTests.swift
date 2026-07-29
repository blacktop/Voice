import XCTest

@testable import VoiceMLX

final class SpeechTextSegmenterTests: XCTestCase {
    private func segments(_ text: String, budget: Int = 60) -> [String] {
        SpeechTextSegmenter.segments(for: text, budget: budget)
    }

    // MARK: - Leaving short text alone

    func testTextWithinBudgetStaysOneSegment() {
        XCTAssertEqual(segments("Build finished successfully."), ["Build finished successfully."])
    }

    func testSeveralShortSentencesAreGroupedNotSplitPerSentence() {
        // The point of packing: per-sentence synthesis would restart prosody
        // constantly and sound clipped.
        let text = "One. Two. Three."
        XCTAssertEqual(segments(text), [text])
    }

    func testEmptyAndWhitespaceTextProduceNoSegments() {
        XCTAssertTrue(segments("").isEmpty)
        XCTAssertTrue(segments("   \n\n  ").isEmpty)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(segments("  hello there  "), ["hello there"])
    }

    // MARK: - Breaking only when over budget

    func testGroupsSentencesUpToTheBudget() {
        // Each sentence is 18 characters plus a joining space; three fit in 60,
        // the fourth does not.
        let sentence = "Sentence number x."
        let text = Array(repeating: sentence, count: 5).joined(separator: " ")
        let result = segments(text, budget: 60)
        XCTAssertGreaterThan(result.count, 1, "over-budget text must be split")
        for segment in result {
            XCTAssertLessThanOrEqual(segment.count, 60, "segment over budget: \(segment)")
        }
    }

    func testSplitsHappenAtSentenceBoundaries() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        for segment in segments(text, budget: 45) {
            XCTAssertTrue(
                segment.hasSuffix(".") || segment.hasSuffix("!") || segment.hasSuffix("?"),
                "segment does not end at a sentence boundary: \(segment)"
            )
        }
    }

    func testASegmentEndsAtASentenceEvenWhenMoreWordsWouldFit() {
        // Packing by word would start the second segment with "This is a
        // considerably", filling the budget more completely but cutting mid
        // sentence. Only a sentence-aware split produces this.
        let text = "Short one. This is a considerably longer sentence."
        XCTAssertEqual(
            segments(text, budget: 40),
            ["Short one.", "This is a considerably longer sentence."]
        )
    }

    func testSegmentAtExactlyTheBudgetIsNotSplit() {
        let text = String(repeating: "a", count: 39) + "."
        XCTAssertEqual(text.count, 40)
        XCTAssertEqual(segments(text, budget: 40), [text])
    }

    func testTwoSentencesAreSplitOneCharacterOverTheBudget() {
        // "Aaaa. Bbbb." is 11 characters, so a budget of 10 must split it while
        // a budget of 11 must not.
        let text = "Aaaa. Bbbb."
        XCTAssertEqual(segments(text, budget: 11), [text])
        XCTAssertEqual(segments(text, budget: 10), ["Aaaa.", "Bbbb."])
    }

    func testParagraphsAreNotMergedAcrossBlankLines() {
        let text = "First paragraph.\n\nSecond paragraph."
        XCTAssertEqual(segments(text, budget: 400), ["First paragraph.", "Second paragraph."])
    }

    func testQuestionAndExclamationEndSentences() {
        // The break lands after "It is!", so both marks were read as sentence
        // ends; packing then groups the first two rather than splitting on the
        // question mark.
        let text = "Is the build green? It is! Ship it now please friends."
        XCTAssertEqual(
            segments(text, budget: 30),
            ["Is the build green? It is!", "Ship it now please friends."]
        )
    }

    // MARK: - Fallbacks for text with no usable boundary

    func testOverlongSentenceFallsBackToClauseBoundaries() {
        // Exact segments, because splitting on words would satisfy a count and
        // budget check too — only clause breaks keep the commas at the ends.
        let text = "one thing, another thing, a third thing, and finally a fourth thing"
        XCTAssertEqual(
            segments(text, budget: 30),
            ["one thing, another thing,", "a third thing,", "and finally a fourth thing"]
        )
    }

    func testOverlongRunWithNoPunctuationFallsBackToWords() {
        let text = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let result = segments(text, budget: 30)
        XCTAssertGreaterThan(result.count, 1)
        for segment in result {
            XCTAssertLessThanOrEqual(segment.count, 30, segment)
        }
    }

    func testSingleUnbreakableTokenIsEmittedRatherThanDropped() {
        // Nothing to split on; speaking it beats silently losing it.
        let text = String(repeating: "x", count: 100)
        XCTAssertEqual(segments(text, budget: 30), [text])
    }

    // MARK: - Invariants that must hold for any input

    func testNoSegmentIsEmptyAndAllWordsSurvive() {
        let samples = [
            "Build finished successfully.",
            "First paragraph.\n\nSecond paragraph with more words in it.",
            "one thing, another thing, a third thing, and a fourth",
            String(repeating: "Sentence number x. ", count: 12),
            "Mixed! Punctuation? Yes. \n\n And a new paragraph follows here.",
        ]
        for sample in samples {
            let result = segments(sample, budget: 40)
            for segment in result {
                XCTAssertFalse(
                    segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "empty segment from: \(sample)"
                )
            }
            // Segmenting must not lose or invent words.
            let original = sample.split(whereSeparator: \.isWhitespace).map(String.init)
            let rejoined = result.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertEqual(rejoined, original, "words changed for: \(sample)")
        }
    }

    func testDefaultBudgetIsTheCalibratedValue() {
        // Pinned because the announcement test below only means something
        // relative to a known budget.
        XCTAssertEqual(SpeechTextSegmenter.defaultBudget, 400)
    }

    func testDefaultBudgetKeepsATypicalAnnouncementWhole() {
        let announcement =
            "All done with the authentication system. Added login, logout, and "
            + "session management. Created five new files and updated the main router."
        XCTAssertEqual(SpeechTextSegmenter.segments(for: announcement).count, 1)
    }
}
