import CoreGraphics
import XCTest

@testable import VoicePlatform

final class TextInsertionCompatibilityPolicyTests: XCTestCase {
    func testNamedTerminalHostsAutomaticallyAllowUnicodeFallback() {
        let bundleIdentifiers = [
            "com.cmuxterm.app",
            "com.mitchellh.ghostty",
        ]

        for bundleIdentifier in bundleIdentifiers {
            XCTAssertTrue(
                TextInsertionCompatibilityPolicy.allowsUnicodeEventFallback(
                    manualFallbackEnabled: false,
                    bundleIdentifier: bundleIdentifier
                ),
                bundleIdentifier
            )
        }
    }

    func testZedRequiresManualUnicodeFallback() {
        let bundleIdentifiers = ["dev.zed.Zed", "dev.zed.Zed-Preview"]

        for bundleIdentifier in bundleIdentifiers {
            XCTAssertFalse(
                TextInsertionCompatibilityPolicy.allowsUnicodeEventFallback(
                    manualFallbackEnabled: false,
                    bundleIdentifier: bundleIdentifier
                ),
                bundleIdentifier
            )
            XCTAssertTrue(
                TextInsertionCompatibilityPolicy.allowsUnicodeEventFallback(
                    manualFallbackEnabled: true,
                    bundleIdentifier: bundleIdentifier
                ),
                bundleIdentifier
            )
        }
    }

    func testUnknownAppRequiresManualUnicodeFallback() {
        XCTAssertFalse(
            TextInsertionCompatibilityPolicy.allowsUnicodeEventFallback(
                manualFallbackEnabled: false,
                bundleIdentifier: "com.apple.TextEdit"
            )
        )
        XCTAssertFalse(
            TextInsertionCompatibilityPolicy.allowsUnicodeEventFallback(
                manualFallbackEnabled: false,
                bundleIdentifier: nil
            )
        )
    }

    func testManualFallbackAllowsUnknownApp() {
        XCTAssertTrue(
            TextInsertionCompatibilityPolicy.allowsUnicodeEventFallback(
                manualFallbackEnabled: true,
                bundleIdentifier: "example.UnknownEditor"
            )
        )
    }
}

final class UnicodeEventPayloadPlanTests: XCTestCase {
    @MainActor
    func testTextEventsClearInheritedModifierFlags() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        )
        event.flags = [.maskCommand, .maskControl, .maskShift]

        AccessibilityTargetInjector.clearInheritedModifiers(on: event)

        XCTAssertTrue(event.flags.isEmpty)
    }

    func testNewlineRunsBecomeSingleSpaces() {
        let source = "\n\rfirst\r\n\nsecond\u{0085}\u{2028}third\u{2029}"

        XCTAssertEqual(
            UnicodeEventPayloadPlan.sanitizedText(source),
            "first second third"
        )
        let chunks = UnicodeEventPayloadPlan.chunks(for: source) ?? []
        XCTAssertEqual(
            chunks.map { String(decoding: $0, as: UTF16.self) }.joined(),
            "first second third"
        )
    }

    func testASCIIUsesOnePayloadPerGrapheme() throws {
        let chunks = try XCTUnwrap(
            UnicodeEventPayloadPlan.chunks(for: String(repeating: "a", count: 21))
        )

        XCTAssertEqual(chunks.count, 21)
        XCTAssertTrue(chunks.allSatisfy { $0.count == 1 })
    }

    func testChunksPreserveExtendedGraphemeClusters() throws {
        let family = "👨‍👩‍👧‍👦"
        let source = String(repeating: "a", count: 19) + family + "tail"
        let chunks = try XCTUnwrap(UnicodeEventPayloadPlan.chunks(for: source))
        let decoded = chunks.map { String(decoding: $0, as: UTF16.self) }

        XCTAssertEqual(decoded.count, 24)
        XCTAssertEqual(decoded[19], family)
        XCTAssertEqual(decoded.joined(), source)
    }

    func testCombiningEmojiModifierFlagAndZWJCharactersStayWhole() throws {
        let prefix = String(repeating: "a", count: 18) + "e\u{0301}"
        let emoji = "👍🏽🇺🇸👨‍👩‍👧‍👦"
        let chunks = try XCTUnwrap(UnicodeEventPayloadPlan.chunks(for: prefix + emoji))
        let decoded = chunks.map { String(decoding: $0, as: UTF16.self) }

        XCTAssertEqual(decoded.joined(), prefix + emoji)
        XCTAssertTrue(decoded.contains("e\u{0301}"))
        XCTAssertTrue(decoded.contains("👍🏽"))
        XCTAssertTrue(decoded.contains("🇺🇸"))
        XCTAssertTrue(decoded.contains("👨‍👩‍👧‍👦"))
    }

    func testPlannerRejectsOversizedGraphemeBeforeDispatch() {
        let oversized = "a" + String(repeating: "\u{0301}", count: 21)

        XCTAssertNil(UnicodeEventPayloadPlan.chunks(for: oversized))
    }
}

@MainActor
final class VerifiedChunkDispatcherTests: XCTestCase {
    func testVerifiesAndPausesBetweenChunks() async throws {
        var operations: [String] = []

        try await VerifiedChunkDispatcher.dispatch(
            [1, 2],
            verifyTarget: { operations.append("verify") },
            postChunk: { operations.append("post \($0)") },
            pauseBetweenChunks: { operations.append("pause") }
        )

        XCTAssertEqual(
            operations,
            ["verify", "post 1", "pause", "verify", "post 2"]
        )
    }

    func testFocusChangeStopsBeforeSecondChunk() async {
        var verificationCount = 0
        var posted: [Int] = []

        do {
            try await VerifiedChunkDispatcher.dispatch(
                [1, 2, 3],
                verifyTarget: {
                    verificationCount += 1
                    if verificationCount == 2 {
                        throw TargetInjectionError.targetChanged
                    }
                },
                postChunk: { posted.append($0) }
            )
            XCTFail("Expected target verification to fail")
        } catch TargetInjectionError.targetChanged {
            // Expected.
        } catch {
            XCTFail("Unexpected dispatcher error: \(error)")
        }
        XCTAssertEqual(verificationCount, 2)
        XCTAssertEqual(posted, [1])
    }
}
