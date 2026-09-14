import CoreGraphics
import XCTest

@testable import VoicePlatform

final class TargetFingerprintTests: XCTestCase {
    private let editor = TargetFingerprint(
        role: "AXTextArea",
        subrole: nil,
        frame: CGRect(x: 100, y: 200, width: 800, height: 600)
    )

    func testSameRoleAndFrameMatches() {
        XCTAssertTrue(editor.matches(editor))
    }

    func testGrownInputBoxStillMatches() {
        let grown = TargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            frame: CGRect(x: 100, y: 150, width: 800, height: 650)
        )

        XCTAssertTrue(editor.matches(grown))
        XCTAssertTrue(grown.matches(editor))
    }

    func testDifferentRoleDoesNotMatch() {
        let button = TargetFingerprint(role: "AXButton", subrole: nil, frame: editor.frame)

        XCTAssertFalse(editor.matches(button))
    }

    func testDifferentSubroleDoesNotMatch() {
        let search = TargetFingerprint(
            role: "AXTextArea",
            subrole: "AXSearchField",
            frame: editor.frame
        )

        XCTAssertFalse(editor.matches(search))
    }

    func testDisjointFrameDoesNotMatch() {
        let sidebar = TargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            frame: CGRect(x: 0, y: 0, width: 90, height: 900)
        )

        XCTAssertFalse(editor.matches(sidebar))
    }

    func testMissingRoleOrFrameNeverMatches() {
        let roleless = TargetFingerprint(role: nil, subrole: nil, frame: editor.frame)
        let frameless = TargetFingerprint(role: "AXTextArea", subrole: nil, frame: nil)

        XCTAssertFalse(roleless.matches(roleless))
        XCTAssertFalse(frameless.matches(frameless))
        XCTAssertFalse(editor.matches(roleless))
        XCTAssertFalse(editor.matches(frameless))
    }
}
