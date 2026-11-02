import XCTest

@testable import VoicePlatform

@MainActor
final class AccessibilityPasteCommandTests: XCTestCase {
    func testOnlyCommandVMatchesPaste() {
        let cases: [(String?, Int?, Bool)] = [
            ("v", 0, true), ("V", 0, true),
            (nil, 0, false), ("v", nil, false), ("", 0, false),
            ("x", 0, false), ("vv", 0, false),
            ("v", 1, false), ("v", 2, false), ("v", 4, false), ("v", 8, false),
        ]
        for (character, modifiers, expected) in cases {
            XCTAssertEqual(
                AccessibilityPasteCommand.matchesPasteShortcut(
                    character: character, modifiers: modifiers),
                expected,
                "character=\(character ?? "nil"), modifiers=\(String(describing: modifiers))")
        }
    }
}
