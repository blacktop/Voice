import ArgumentParser
import XCTest

@testable import VoiceMLX

/// Covers the command surface itself. The parsing configuration regressed once
/// in a way no test could see: `.captureForPassthrough` swallowed `--help`, so
/// asking for help spoke the word "--help" aloud instead of printing it.
final class VoiceSayCommandTests: XCTestCase {
    func testPauseControlsOnlyAnnounceForFileInput() throws {
        XCTAssertTrue(try parse(["--file", "notes.md", "--announce-pause"]).announcePause)
        XCTAssertTrue(try parse(["--file", "notes.md", "--no-controls"]).noControls)
        XCTAssertThrowsError(try parse(["--announce-pause", "hello"]))
        XCTAssertThrowsError(
            try parse(["--file", "notes.md", "--announce-pause", "--no-controls"]))
    }

    func testDocumentFlagsAndConflictingOperands() throws {
        let command = try parse(["--file", "notes.md", "--timings"])
        XCTAssertEqual(command.file, "notes.md")
        XCTAssertTrue(command.timings)
        XCTAssertFalse(command.stream)
        XCTAssertEqual(try parse(["-f", "-"]).file, "-")
        XCTAssertTrue(try parse(["--stream", "hello"]).stream)
        XCTAssertThrowsError(try parse(["--file", "notes.md", "extra text"]))
    }

    func testOperandsStayLiteralAndStreamWhileFilesUseNarration() throws {
        for text in ["# of tests passed: 5", "---", "https://example.test/private?q=1"] {
            let input = try parse(["--", text]).resolveInput()
            XCTAssertEqual(input.blocks, [SpeechNarrationBlock(role: .narrator, text: text)])
            XCTAssertTrue(input.streaming)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "# Title\n\nBody.".write(to: url, atomically: true, encoding: .utf8)
        let document = try parse(["--file", url.path]).resolveInput()
        XCTAssertEqual(document.blocks.map(\.role), [.heading, .narrator])
        XCTAssertFalse(document.streaming)
        let streamed = try parse(["--file", url.path, "--stream"]).resolveInput()
        XCTAssertEqual(streamed.blocks, document.blocks)
        XCTAssertTrue(streamed.streaming)
    }

    func testDocumentReadPreservesParagraphsAndRejectsInvalidInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "First paragraph.\n\nSecond paragraph.\n".write(
            to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try VoiceSay.resolveText([], file: url.path),
            "First paragraph.\n\nSecond paragraph."
        )
        try Data([0xff, 0xfe, 0xff]).write(to: url)
        XCTAssertThrowsError(try VoiceSay.resolveText([], file: url.path))
        XCTAssertThrowsError(try VoiceSay.resolveText([], file: url.path + ".missing"))
        XCTAssertEqual(try VoiceSay.resolveText(["hello", "world"]), "hello world")
    }

    func testDocumentReadsEnforceTheByteLimitForFilesAndStreams() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: VoiceSayInput.maximumBytes).write(to: url)
        XCTAssertEqual(
            try VoiceSay.resolveText([], file: url.path).utf8.count, VoiceSayInput.maximumBytes)

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        XCTAssertEqual(try VoiceSayInput.read(input).utf8.count, VoiceSayInput.maximumBytes)

        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seekToEnd()
        try output.write(contentsOf: Data([0x61]))
        XCTAssertThrowsError(try VoiceSay.resolveText([], file: url.path))
        try input.seek(toOffset: 0)
        XCTAssertThrowsError(try VoiceSayInput.read(input))
    }

    func testDocumentFileRejectsDirectoriesAndDevices() {
        for path in [FileManager.default.temporaryDirectory.path, "/dev/null"] {
            XCTAssertThrowsError(try VoiceSay.resolveText([], file: path)) { error in
                XCTAssertTrue(String(describing: error).contains("regular file"))
            }
        }
    }

    private func parse(_ arguments: [String]) throws -> VoiceSay {
        try VoiceSay.parse(arguments)
    }

    func testTemperatureDefaultsSteadyAndIsRangeChecked() throws {
        XCTAssertEqual(try parse(["hi"]).temperature, 0.6)
        XCTAssertNil(try parse(["hi"]).seed)
        let tuned = try parse(["--temperature", "0.3", "--seed", "7", "hi"])
        XCTAssertEqual(tuned.temperature, 0.3)
        XCTAssertEqual(tuned.seed, 7)
        XCTAssertNoThrow(try parse(["--temperature", "0", "hi"]))
        XCTAssertThrowsError(try parse(["--temperature", "1.6", "hi"]))
        XCTAssertThrowsError(try parse(["--temperature", "-0.1", "hi"]))
        XCTAssertThrowsError(try parse(["--temperature", "nan", "hi"]))
        XCTAssertThrowsError(try parse(["--seed", "-1", "hi"]))
    }

    func testSpeedIsAPitchPreservingMultiplierWithinRange() throws {
        XCTAssertEqual(try parse(["hi"]).speed, 1)
        XCTAssertEqual(try parse(["--speed", "1.25", "hi"]).speed, 1.25)
        XCTAssertNoThrow(try parse(["--speed", "0.5", "hi"]))
        XCTAssertNoThrow(try parse(["--speed", "2", "hi"]))
        XCTAssertThrowsError(try parse(["--speed", "2.5", "hi"]))
        XCTAssertThrowsError(try parse(["--speed", "0.4", "hi"]))
        XCTAssertThrowsError(try parse(["--speed", "inf", "hi"]))
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
