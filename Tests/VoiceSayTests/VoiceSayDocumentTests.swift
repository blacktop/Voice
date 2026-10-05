import VoiceMLX
import XCTest

final class VoiceSayDocumentTests: XCTestCase {
    /// Each block as "role: text", with narrator prose left bare.
    private func cast(_ source: String) -> [String] {
        VoiceSayDocument.blocks(from: source).map { block in
            block.role == .narrator ? block.text : "\(block.role.rawValue): \(block.text)"
        }
    }

    func testMarkdownTablesBecomeOneCueWithoutReadingCells() {
        let source =
            "Before.\n\n| Name | Value |\n| :--- | ---: |\n| secret | 12345 |\n| other | 67890 |\n\nAfter."
        XCTAssertEqual(cast(source), ["Before.", "aside: Table.", "After."])
        XCTAssertEqual(
            cast("Name | Value\n- | -\nA | B\n\nDone."), ["aside: Table.", "Done."]
        )
    }

    func testTableDetectionDoesNotEatOrdinaryPipesOrCode() {
        let prose = "Use a | b to describe the choice.\nThen continue."
        XCTAssertEqual(cast(prose), [prose])
        XCTAssertEqual(cast("```\nA | B\n--- | ---\nX | Y\n```"), ["aside: Code block."])
        XCTAssertEqual(
            cast("Before.\n<table><tr><td>hidden</td></tr></table>\nAfter."),
            ["Before.", "aside: Table.", "After."]
        )
        XCTAssertEqual(
            cast("Before.\n<table>\n<tr><td>hidden</td></tr>\n</table>\nAfter."),
            ["Before.", "aside: Table.", "After."]
        )
        XCTAssertEqual(
            cast("The `<table>` tag is mentioned here.\nStill prose."),
            ["The `<table>` tag is mentioned here.\nStill prose."]
        )
    }

    func testFencedCodeIsOmittedAndProseKeepsParagraphBoundaries() {
        let source = """
            First thought.
            ```swift
            print("never speak this")
            ```
            Second thought.

            ~~~~python
            print("nor this")
            ~~~
            still_code()
            ~~~~
            Last thought.
            """
        XCTAssertEqual(
            cast(source),
            [
                "First thought.", "aside: Swift code.", "Second thought.",
                "aside: Python code.", "Last thought.",
            ]
        )
    }

    func testUnclosedFenceDoesNotLeakCodeIntoSpeech() {
        XCTAssertEqual(
            cast("Read this.\n```rust\nfn main() {}"), ["Read this.", "aside: Rust code."])
    }

    func testOnlyExplicitFencesOmitCode() {
        let source =
            "Before.\r\n\r\n    let hidden = 1\r\n\tmore_code()\r\n\r\n> ```js\r\n> hidden()\r\n> ```\r\nAfter."
        XCTAssertEqual(
            cast(source),
            ["Before.", "let hidden = 1\n\tmore_code()", "aside: JavaScript code.", "After."])
    }

    func testIndentedParagraphsAndErrorsStaySpeakable() {
        let source = "Line one\n    continued here.\n\n    hidden()\nAfter."
        XCTAssertEqual(cast(source), ["Line one\n    continued here.", "hidden()\nAfter."])
        XCTAssertEqual(
            cast("Failed:\n\n    error: compilation failed"),
            [
                "Failed:", "error: compilation failed",
            ])
        XCTAssertEqual(
            cast("- First item\n\n    Continuation paragraph.\n    Still relevant."),
            [
                "First item.", "Continuation paragraph.\n    Still relevant.",
            ])
    }

    func testBlockquotesAreQuotesWithMarkersDroppedAndParagraphBreaksKept() {
        XCTAssertEqual(
            cast("Intro.\n> A quote.\n>\n> Second.\n\nOutro."),
            ["Intro.", "quote: A quote.", "quote: Second.", "Outro."]
        )
    }

    func testParagraphThatIsEntirelyAQuotationIsReadAsAQuote() {
        XCTAssertEqual(
            cast("“Whole paragraph quoted.”"), ["quote: “Whole paragraph quoted.”"])
        XCTAssertEqual(cast("\"Plain quotes too.\""), ["quote: \"Plain quotes too.\""])
        let dialogue = "\"Hello,\" she said. \"Goodbye.\""
        XCTAssertEqual(cast(dialogue), [dialogue], "dialogue with narration stays prose")
        XCTAssertEqual(cast("\"Trailing period\"."), ["\"Trailing period\"."])
    }

    func testHeadingsAreTheirOwnBlocksWithoutMarkers() {
        let source = "# Title ##\nIntro line.\n\n## Section\n\n#hashtag stays prose.\n####### not"
        XCTAssertEqual(
            cast(source),
            [
                "heading: Title", "Intro line.", "heading: Section",
                "#hashtag stays prose.\n####### not",
            ]
        )
        XCTAssertEqual(
            cast("Setext\n======\nBody.\n\nAnother\n---\nMore."),
            ["heading: Setext", "Body.", "heading: Another", "More."])
        XCTAssertEqual(
            cast("> # Quoted heading\n> Body."), ["heading: Quoted heading", "quote: Body."])
        XCTAssertEqual(cast("#\n\nAfter empty heading."), ["After empty heading."])
    }

    func testThematicBreaksAreSilentParagraphBreaks() {
        XCTAssertEqual(cast("One.\n\n---\n\nTwo.\n* * *\nThree."), ["One.", "Two.", "Three."])
    }

    func testLeadingClosedFrontMatterIsOmitted() {
        XCTAssertEqual(
            cast("---\ntitle: front matter\n---\nBody."),
            ["Body."])
        XCTAssertEqual(cast("---\ntitle: hidden\n...\nBody."), ["Body."])
        XCTAssertEqual(cast("---\nNo closing delimiter."), ["No closing delimiter."])
    }

    func testListItemsLoseMarkersAndHaveSentenceBoundaries() {
        XCTAssertEqual(
            cast("Tasks:\n- Install deps\n- Run tests!\n  1. Check output\n    * [x] Done"),
            ["Tasks:", "Install deps.", "Run tests!", "Check output.", "Done."])
        XCTAssertEqual(
            cast("> - Quoted item\n> - Another."), ["quote: Quoted item.", "quote: Another."])
        XCTAssertEqual(cast("- \n- [ ] \n- Actual item"), ["Actual item."])
    }

    func testLinksKeepLabelsAndRemoveDestinationsAndBareURLs() {
        let source = """
            See [the guide](https://example.com/guide_(new)) and [the notes][n].
            Visit https://example.com/a?q=1 or www.example.org.
            Also <https://example.net> and example.com/path.
            [n]: https://example.com/notes
            """
        let result = VoiceSayDocument.blocks(from: source).map(\.text).joined(separator: "\n\n")
        XCTAssertTrue(result.contains("See the guide and the notes."))
        XCTAssertFalse(result.contains("https"))
        XCTAssertTrue(result.contains("example dot com"))
        XCTAssertFalse(result.contains("www"))
        XCTAssertFalse(result.contains("[n]"))
    }

    func testAParagraphThatIsOnlyAURLIsAnAside() {
        XCTAssertEqual(
            cast(
                "Reference:\n\nhttps://github.com/blacktop/voice/blob/main/README.md?plain=1"
                    + "\n\nDone."
            ),
            ["Reference:", "aside: github URL", "Done."]
        )
        XCTAssertEqual(cast("Mail me@example.com now."), ["Mail me@example.com now."])
    }

    func testOrdinaryProseAndInlineCodeNamesAreKept() {
        let source = "Use `voice-say` with Swift 6.2.\n\nThen review the results."
        XCTAssertEqual(
            cast(source), ["Use `voice-say` with Swift 6.2.", "Then review the results."])
    }

    func testShortCodeOnlyDocumentAnnouncesTheOmission() {
        XCTAssertEqual(cast("```\nsecret_code()\n```"), ["aside: Code block."])
    }

    func testLongCodeBlocksAnnounceLanguageWithoutReadingBody() {
        let source = "Before.\n```c\nint main() {\nreturn 0;\n}\n```\nAfter."
        XCTAssertEqual(cast(source), ["Before.", "aside: C code.", "After."])
        XCTAssertEqual(
            cast("```\n" + String(repeating: "x", count: 120)), ["aside: Code block."]
        )
    }

    func testShortURLsSpeakDomainAndLongURLsAnnounceHost() {
        XCTAssertEqual(cast("https://google.com"), ["aside: google dot com"])
        XCTAssertEqual(cast("www.google.com"), ["aside: google dot com"])
        XCTAssertEqual(
            cast("https://google.com/search?q=very-long-search-terms-and-tracking&x=1"),
            ["aside: google URL"]
        )
        XCTAssertEqual(
            cast("https://docs.example.co.uk/path?q=tracking"),
            ["aside: docs dot example dot co dot uk URL"]
        )
        XCTAssertEqual(
            cast("See [the guide](https://google.com/long/path?q=tracking)."), ["See the guide."]
        )
    }

    func testAddressesGetLabelsButSmallHexConstantsAndIdentifiersSurvive() {
        XCTAssertEqual(
            cast("Jump to 0xFFFFFF23423423, then 0xdeadbeef. Mask 0xFF; symbol foo0x12345678."),
            ["Jump to code address, then code address. Mask 0xFF; symbol foo0x12345678."]
        )
    }
}
