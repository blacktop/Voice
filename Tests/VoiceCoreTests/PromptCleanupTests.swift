import XCTest

@testable import VoiceCore

final class PromptCleanupTests: XCTestCase {
    func testDetectsTechnicalAndSemanticProtectedSpans() {
        let source =
            "Run /usr/local/bin/tool --dry-run for userID and foo_bar at 26.5.2; don't change \"Exact text\" or https://example.com/a?q=1."

        let spans = ProtectedSpanDetector().detect(in: source)
        let detected = Dictionary(uniqueKeysWithValues: spans.map { ($0.text, $0.kind) })

        XCTAssertEqual(detected["/usr/local/bin/tool"], .path)
        XCTAssertEqual(detected["--dry-run"], .commandFlag)
        XCTAssertEqual(detected["userID"], .identifier)
        XCTAssertEqual(detected["foo_bar"], .identifier)
        XCTAssertEqual(detected["26.5.2"], .number)
        XCTAssertEqual(detected["don't"], .negation)
        XCTAssertEqual(detected["\"Exact text\""], .quotedText)
        XCTAssertEqual(detected["https://example.com/a?q=1"], .url)
    }

    func testContainingConstructWinsWhenDetectedSpansOverlap() {
        let source = "Use \"--count=42\" then --endpoint=https://example.com/a/1."

        let spans = ProtectedSpanDetector().detect(in: source)

        XCTAssertTrue(
            spans.contains {
                $0.text == "\"--count=42\"" && $0.kind == .quotedText
            })
        XCTAssertTrue(
            spans.contains {
                $0.text == "--endpoint=https://example.com/a/1" && $0.kind == .commandFlag
            })
        XCTAssertFalse(spans.contains { $0.text == "42" })
        XCTAssertFalse(spans.contains { $0.kind == .url })
    }

    func testDeterministicCleanupRemovesFillers() async {
        let cleaner = DeterministicPromptCleaner()

        let result = await cleaner.clean(
            Transcript(text: "um, i need uh the tests to pass"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "I need the tests to pass.")
        XCTAssertEqual(result.source, .deterministic)
    }

    func testFillerRemovalDoesNotLeaveLeadingPunctuation() async {
        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: "um... okay start"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "Okay start.")
    }

    func testIntentionalLeadingEllipsisIsPreserved() async {
        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: "... okay start"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "... Okay start.")
    }

    func testCleanupPreservesIntentionalRepeatedWords() async {
        let cleaner = DeterministicPromptCleaner()

        let emphasis = await cleaner.clean(
            Transcript(text: "this is very, very important"),
            mode: .conservative,
            protectedSpans: []
        )
        let grammaticalDouble = await cleaner.clean(
            Transcript(text: "the result he had had mattered"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(emphasis.text, "This is very, very important.")
        XCTAssertEqual(grammaticalDouble.text, "The result he had had mattered.")
    }

    func testCapitalizesNonASCIISentenceStarts() async {
        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: "élan is great"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "Élan is great.")
    }

    func testAppendsQuestionMarkToSingleSentenceQuestion() async {
        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: "where is the config"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "Where is the config?")
    }

    func testAbbreviationDoesNotHideInterrogativeOpening() async {
        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: "is Dr. Smith available"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "Is Dr. Smith available?")
    }

    func testTerminalPunctuationFollowsTheFinalSentence() async {
        let cleaner = DeterministicPromptCleaner()

        let statementEnding = await cleaner.clean(
            Transcript(text: "what should I do. it is broken"),
            mode: .conservative,
            protectedSpans: []
        )
        XCTAssertEqual(statementEnding.text, "What should I do. It is broken.")

        let multiline = await cleaner.clean(
            Transcript(text: "what should I do new paragraph here is context"),
            mode: .conservative,
            protectedSpans: []
        )
        XCTAssertEqual(multiline.text, "What should I do\n\nHere is context.")
    }

    func testDeterministicCleanupHandlesSpokenPunctuation() async {
        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: "how do we fix this question mark"),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "How do we fix this?")
    }

    func testDeterministicCleanupPreservesEveryProtectedTokenExactly() async {
        let source =
            "um run /tmp/foo_bar --dry-run with userID 26.5.2 and don't rename \"Exact Thing\" then open https://example.com/a"
        let detector = ProtectedSpanDetector()
        let spans = detector.detect(in: source)

        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: source),
            mode: .conservative,
            protectedSpans: spans
        )

        for span in spans {
            XCTAssertTrue(result.text.contains(span.text), "Missing protected span: \(span.text)")
        }
        XCTAssertTrue(result.text.hasSuffix("https://example.com/a"))
    }

    func testLeadingWhitespaceDoesNotAppendPunctuationToTerminalURL() async {
        let source = "  um open https://example.com/a  "

        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: source),
            mode: .conservative,
            protectedSpans: []
        )

        XCTAssertEqual(result.text, "Open https://example.com/a")
    }

    func testInvalidSuppliedProtectedSpanFailsClosed() async {
        let source = "um hello"
        let invalid = ProtectedSpan(
            range: TextRange(location: 200, length: 5),
            kind: .identifier,
            text: "hello"
        )

        let result = await DeterministicPromptCleaner().clean(
            Transcript(text: source),
            mode: .conservative,
            protectedSpans: [invalid]
        )

        XCTAssertEqual(result.text, source)
    }

    func testAppliesMultipleUTF16EditsInReverseOrder() throws {
        let source = "Fix 🧪 teh code now"
        let sourceString = source as NSString
        let typoRange = sourceString.range(of: "teh")
        let nowRange = sourceString.range(of: "now")
        let edits = [
            TextEdit(
                range: TextRange(location: typoRange.location, length: typoRange.length),
                replacement: "the"
            ),
            TextEdit(
                range: TextRange(location: nowRange.location, length: nowRange.length),
                replacement: "today"
            ),
        ]

        let result = try EditPlanValidator().validateAndApply(
            edits: edits,
            to: source,
            protectedSpans: [],
            mode: .conservative
        )

        XCTAssertEqual(result, "Fix 🧪 the code today")
    }

    func testAnchoredEditsRequireExactOriginalSubstring() throws {
        let source = "Any way you slice it"
        let range = (source as NSString).range(of: "slice")
        let validator = EditPlanValidator()

        XCTAssertThrowsError(
            try validator.validateAndApply(
                anchoredEdits: [
                    AnchoredTextEdit(
                        range: TextRange(
                            location: range.location,
                            length: range.length
                        ),
                        original: "slize",
                        replacement: "dice"
                    )
                ],
                to: source,
                protectedSpans: [],
                mode: .polish
            )
        )

        XCTAssertEqual(
            try validator.validateAndApply(
                anchoredEdits: [
                    AnchoredTextEdit(
                        range: TextRange(
                            location: range.location,
                            length: range.length
                        ),
                        original: "slice",
                        replacement: "dice"
                    )
                ],
                to: source,
                protectedSpans: [],
                mode: .polish
            ),
            "Any way you dice it"
        )
    }

    func testRejectsOutOfBoundsAndOverlappingEdits() {
        let validator = EditPlanValidator()

        XCTAssertThrowsError(
            try validator.validateAndApply(
                edits: [
                    TextEdit(range: TextRange(location: -1, length: 1), replacement: "x")
                ],
                to: "source",
                protectedSpans: [],
                mode: .conservative
            )
        )

        XCTAssertThrowsError(
            try validator.validateAndApply(
                edits: [
                    TextEdit(range: TextRange(location: 0, length: 4), replacement: "that"),
                    TextEdit(range: TextRange(location: 3, length: 3), replacement: "ese"),
                ],
                to: "these",
                protectedSpans: [],
                mode: .conservative
            )
        )
    }

    func testRejectsUTF16RangeThatSplitsAUnicodeCharacter() {
        let source = "A🧪B"

        XCTAssertThrowsError(
            try EditPlanValidator().validateAndApply(
                edits: [
                    TextEdit(range: TextRange(location: 2, length: 1), replacement: "x")
                ],
                to: source,
                protectedSpans: [],
                mode: .conservative
            )
        )
    }

    func testNoOpPlanForEmptySourceReturnsOriginalSource() throws {
        XCTAssertEqual(
            try EditPlanValidator().validateAndApply(
                edits: [],
                to: "",
                protectedSpans: [],
                mode: .conservative
            ),
            ""
        )
    }

    func testRejectsChangesInsideProtectedSpans() {
        let source = "Keep --count=42 and don't rename userID"
        let spans = ProtectedSpanDetector().detect(in: source)
        let sourceString = source as NSString

        for token in ["--count=42", "don't", "userID"] {
            let range = sourceString.range(of: token)
            XCTAssertThrowsError(
                try EditPlanValidator().validateAndApply(
                    edits: [
                        TextEdit(
                            range: TextRange(location: range.location, length: range.length),
                            replacement: "changed"
                        )
                    ],
                    to: source,
                    protectedSpans: spans,
                    mode: .conservative
                ),
                "Expected protected token to reject edits: \(token)"
            )
        }
    }

    func testRejectsInsertionInsideProtectedSpanButAllowsBoundaryInsertion() throws {
        let source = "Open /tmp/file"
        let spans = ProtectedSpanDetector().detect(in: source)
        let path = try XCTUnwrap(spans.first { $0.kind == .path })
        let validator = EditPlanValidator()

        XCTAssertThrowsError(
            try validator.validateAndApply(
                edits: [
                    TextEdit(
                        range: TextRange(location: path.range.location + 2, length: 0),
                        replacement: "x"
                    )
                ],
                to: source,
                protectedSpans: spans,
                mode: .conservative
            )
        )

        let result = try validator.validateAndApply(
            edits: [
                TextEdit(
                    range: TextRange(location: path.range.upperBound, length: 0),
                    replacement: "."
                )
            ],
            to: source,
            protectedSpans: spans,
            mode: .conservative
        )
        XCTAssertEqual(result, "Open /tmp/file.")
    }

    func testConservativeAndPolishModesEnforceDifferentEditBudgets() throws {
        let source = String(repeating: "a", count: 20)
        let edits = (0..<20).map { location in
            TextEdit(
                range: TextRange(location: location, length: 1),
                replacement: "b"
            )
        }
        let validator = EditPlanValidator()

        XCTAssertThrowsError(
            try validator.validateAndApply(
                edits: edits,
                to: source,
                protectedSpans: [],
                mode: .conservative
            )
        )
        XCTAssertEqual(
            try validator.validateAndApply(
                edits: edits,
                to: source,
                protectedSpans: [],
                mode: .polish
            ),
            String(repeating: "b", count: 20)
        )
    }

    func testRejectedPlanCanFailClosedToOriginalSource() {
        let source = "Never change 42"
        let spans = ProtectedSpanDetector().detect(in: source)
        let sourceString = source as NSString
        let protectedRange = sourceString.range(of: "42")

        let output: String
        do {
            output = try EditPlanValidator().validateAndApply(
                edits: [
                    TextEdit(
                        range: TextRange(
                            location: protectedRange.location,
                            length: protectedRange.length
                        ),
                        replacement: "43"
                    )
                ],
                to: source,
                protectedSpans: spans,
                mode: .conservative
            )
        } catch {
            output = source
        }

        XCTAssertEqual(output, source)
    }
}
