import ArgumentParser
import XCTest

@testable import VoiceMLX

/// Covers the command surface itself. The parsing configuration regressed once
/// in a way no test could see: `.captureForPassthrough` swallowed `--help`, so
/// asking for help spoke the word "--help" aloud instead of printing it.
final class VoiceSayCommandTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> VoiceSay {
        try VoiceSay.parse(arguments)
    }

    func testFlagsAreParsedRatherThanTreatedAsText() throws {
        let command = try parse(["--voice", "Aiden", "--tier", "large", "hello", "there"])
        XCTAssertEqual(command.voice, "Aiden")
        XCTAssertEqual(command.tier, "large")
        XCTAssertEqual(command.words, ["hello", "there"])
    }

    func testHelpIsNotSwallowedIntoTheSpokenText() {
        // ArgumentParser signals --help by throwing; the failure mode this
        // guards is --help being captured as words and spoken.
        XCTAssertThrowsError(try parse(["--help"])) { error in
            XCTAssertTrue(VoiceSay.exitCode(for: error) == .success)
        }
    }

    func testTextIsOptionalSoStdinCanSupplyIt() throws {
        XCTAssertEqual(try parse([]).words, [])
    }

    func testUnknownFlagIsRejectedRatherThanSpoken() {
        XCTAssertThrowsError(try parse(["--vioce", "Ryan"]))
    }

    func testUnknownVoiceIsRejected() {
        XCTAssertThrowsError(try parse(["--voice", "Siri", "hi"])) { error in
            XCTAssertTrue("\(error)".contains("Unknown voice"))
        }
    }

    func testVoiceMatchingIsCaseInsensitive() throws {
        for name in ["aiden", "AIDEN", "Aiden"] {
            XCTAssertNoThrow(try parse(["--voice", name, "hi"]), "rejected \(name)")
        }
    }

    func testUnknownTierIsRejected() {
        XCTAssertThrowsError(try parse(["--tier", "huge", "hi"])) { error in
            XCTAssertTrue("\(error)".contains("Unknown tier"))
        }
    }

    func testDescribeAndCloneTogetherIsRejected() {
        XCTAssertThrowsError(
            try parse([
                "--describe", "a narrator",
                "--clone", "/tmp/a.wav",
                "--clone-transcript", "words",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("only one"))
        }
    }

    func testCloneRequiresATranscript() {
        XCTAssertThrowsError(try parse(["--clone", "/tmp/a.wav", "hi"])) { error in
            XCTAssertTrue("\(error)".contains("clone-transcript"))
        }
    }

    func testCloneRejectsAnUnreadableClipBeforeAnyModelLoad() {
        let missing = "/tmp/voice-say-missing-\(UUID().uuidString).wav"
        XCTAssertThrowsError(
            try parse(["--clone", missing, "--clone-transcript", "words", "hi"])
        ) { error in
            XCTAssertTrue("\(error)".contains("Cannot read"))
        }
    }

    func testCloneAcceptsAReadableClip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-say-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(
            try parse(["--clone", url.path, "--clone-transcript", "words", "hi"])
        )
    }

    func testTextAfterSeparatorMayStartWithADash() throws {
        let command = try parse(["--", "-dash-leading text"])
        XCTAssertEqual(command.words, ["-dash-leading text"])
    }

    func testQuietAndListVoicesFlags() throws {
        XCTAssertTrue(try parse(["-q", "hi"]).quiet)
        XCTAssertFalse(try parse(["hi"]).quiet)
        XCTAssertTrue(try parse(["--list-voices"]).listVoices)
    }
}
