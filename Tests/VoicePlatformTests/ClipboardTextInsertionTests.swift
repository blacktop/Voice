import AppKit
import XCTest

@testable import VoicePlatform

@MainActor
final class ClipboardTextInsertionTests: XCTestCase {
    func testClipboardTextCannotContainTerminalControls() {
        let source = "hello\r\nworld\t\u{1B}[31m\u{03}\u{7F} 👩‍💻"
        XCTAssertEqual(ClipboardTextInsertion.safeText(source), "hello world[31m 👩‍💻")
    }

    func testPasteRestoresEveryOriginalRepresentation() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let html = NSPasteboard.PasteboardType.html
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("original", forType: .string))
        XCTAssertTrue(item.setString("<b>original</b>", forType: html))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let insertion = ClipboardTextInsertion()
        var pasted = false

        try await insertion.perform(
            "new\ntext", on: pasteboard, verifyTarget: {},
            paste: {
                XCTAssertEqual(pasteboard.string(forType: .string), "new text")
                XCTAssertTrue(
                    pasteboard.types?.contains(ClipboardTextInsertion.transientType) == true)
                XCTAssertTrue(
                    pasteboard.types?.contains(ClipboardTextInsertion.concealedType) == true)
                pasted = true
            }, settle: {})

        XCTAssertTrue(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.string(forType: html), "<b>original</b>")
        XCTAssertFalse(pasteboard.types?.contains(ClipboardTextInsertion.transientType) == true)
    }

    func testEmptyClipboardIsRestoredAfterPaste() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        var pasted = false

        try await ClipboardTextInsertion().perform(
            "dictation", on: pasteboard, maximumSnapshotBytes: 0, verifyTarget: {},
            paste: {
                XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
                pasted = true
            }, settle: {})

        XCTAssertTrue(pasted)
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testConcurrentCopyIsNotOverwritten() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        try await ClipboardTextInsertion().perform(
            "dictation", on: pasteboard, verifyTarget: {},
            paste: { XCTAssertEqual(pasteboard.string(forType: .string), "dictation") },
            settle: {
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("new user copy", forType: .string))
            })
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testFocusFailurePreservesClipboardAtEitherCheck() async throws {
        for rejectedCheck in [1, 2] {
            let pasteboard = try makePasteboard()
            defer { pasteboard.releaseGlobally() }
            let before = pasteboard.changeCount
            var checks = 0
            do {
                try await ClipboardTextInsertion().perform(
                    "dictation", on: pasteboard,
                    verifyTarget: {
                        checks += 1
                        if checks == rejectedCheck { throw TargetInjectionError.targetChanged }
                    },
                    paste: { XCTFail("a rejected target must not receive a paste") },
                    settle: { XCTFail("a rejected paste must not wait for delivery") })
                XCTFail("focus failure was swallowed")
            } catch TargetInjectionError.targetChanged {
            }
            XCTAssertEqual(checks, rejectedCheck)
            if rejectedCheck == 1 { XCTAssertEqual(pasteboard.changeCount, before) }
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
        }
    }

    func testOversizedSnapshotDoesNotChangeClipboard() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let before = pasteboard.changeCount
        do {
            try await ClipboardTextInsertion().perform(
                "dictation", on: pasteboard, maximumSnapshotBytes: 1,
                verifyTarget: {},
                paste: { XCTFail("oversized backup must not paste") }, settle: {})
            XCTFail("oversized backup was accepted")
        } catch ClipboardInsertionError.tooLarge {
        }
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testOverlappingPasteIsRejectedWithoutChangingClipboard() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let insertion = ClipboardTextInsertion()
        try await insertion.perform(
            "first", on: pasteboard, verifyTarget: {}, paste: {},
            settle: {
                do {
                    try await insertion.perform(
                        "second", on: pasteboard, verifyTarget: {}, paste: {})
                    XCTFail("overlapping paste was accepted")
                } catch ClipboardInsertionError.busy {
                } catch {
                    XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(pasteboard.string(forType: .string), "first")
            })
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testClipboardChangeDuringFocusCheckPreventsPaste() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var checks = 0
        do {
            try await ClipboardTextInsertion().perform(
                "dictation", on: pasteboard,
                verifyTarget: {
                    checks += 1
                    guard checks == 2 else { return }
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("replacement", forType: .string))
                },
                paste: { XCTFail("changed clipboard must not be pasted") },
                settle: { XCTFail("an aborted paste must not wait for delivery") })
            XCTFail("changed clipboard was accepted")
        } catch ClipboardInsertionError.changed {
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }

    func testPasteValidationPrecedesFinalClipboardOwnershipCheck() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        do {
            try await ClipboardTextInsertion().perform(
                "dictation", on: pasteboard, verifyTarget: {},
                validatePaste: {
                    XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("replacement", forType: .string))
                },
                paste: { XCTFail("changed clipboard must not be pasted") },
                settle: { XCTFail("an aborted paste must not wait for delivery") })
            XCTFail("changed clipboard was accepted")
        } catch ClipboardInsertionError.changed {
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }

    func testAttemptedPasteSettlesBeforeErrorRestoresClipboard() async throws {
        let pasteboard = try makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var settled = false
        do {
            try await ClipboardTextInsertion().perform(
                "dictation", on: pasteboard, verifyTarget: {},
                paste: { throw TargetInjectionError.insertionFailed(.cannotComplete) },
                settle: {
                    XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
                    settled = true
                })
            XCTFail("paste failure was swallowed")
        } catch TargetInjectionError.insertionFailed(let error) {
            XCTAssertEqual(error, .cannotComplete)
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    private func makePasteboard() throws -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        guard pasteboard.setString("original", forType: .string) else {
            pasteboard.releaseGlobally()
            throw XCTSkip("The host pasteboard service is unavailable")
        }
        return pasteboard
    }
}
