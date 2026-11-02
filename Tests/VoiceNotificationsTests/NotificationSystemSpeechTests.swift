import Darwin
import Foundation
import XCTest

@testable import VoiceNotifications

final class NotificationSystemSpeechTests: XCTestCase {
    func testSystemDefaultsAndFullPrivateInput() throws {
        let data = Data(String(repeating: "Full text 🦉.\n", count: 20_000).utf8)
        let input = try NotificationSystemSpeech.inputFile(data)
        defer { try? input.close() }
        var info = stat()
        XCTAssertEqual(fstat(input.fileDescriptor, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_nlink, 0)
        let command = NotificationSystemSpeech.command(input: input)
        XCTAssertEqual(command.executableURL?.path, "/usr/bin/say")
        XCTAssertEqual(command.arguments, ["-f", "-"])
        let stdin = try XCTUnwrap(command.standardInput as? FileHandle)
        XCTAssertEqual(try stdin.readToEnd(), data)
    }

    func testInputIsValidatedBeforeLaunchingSpeech() async {
        for text in ["", "embedded\0null", String(repeating: "a", count: 8 * 1024 * 1024 + 1)] {
            do {
                try await NotificationSystemSpeech.speak(text) {
                    XCTFail("invalid input launched speech")
                }
                XCTFail("invalid input was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("invalid or exceed 8 MiB"))
            }
        }
    }

    func testProcessExitAndLaunchErrors() async throws {
        let started = expectation(description: "process started")
        try await NotificationSystemSpeech.run(
            process("/usr/bin/true"), timeout: .seconds(2), onStarted: { started.fulfill() })
        await fulfillment(of: [started], timeout: 2)
        do {
            try await NotificationSystemSpeech.run(
                process("/usr/bin/false"), timeout: .seconds(2), onStarted: {})
            XCTFail("nonzero exit was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit status 1"))
        }
        do {
            try await NotificationSystemSpeech.run(
                process("/nonexistent/voice-speech-test"), timeout: .seconds(2),
                onStarted: { XCTFail("missing executable was reported as started") })
            XCTFail("missing executable was accepted")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
    }

    func testTimeoutAndCancellationStopTheOwnedProcess() async throws {
        let timedOut = process("/bin/sleep", ["30"])
        do {
            try await NotificationSystemSpeech.run(
                timedOut, timeout: .milliseconds(50), onStarted: {})
            XCTFail("timeout was ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("time limit"))
        }
        XCTAssertFalse(timedOut.isRunning)
        XCTAssertNotEqual(timedOut.terminationStatus, 0)

        let cancelled = process("/bin/sleep", ["30"])
        let started = expectation(description: "cancellable process started")
        let task = Task {
            try await NotificationSystemSpeech.run(
                cancelled, timeout: .seconds(5), onStarted: { started.fulfill() })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("cancellation was ignored")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertFalse(cancelled.isRunning)
        XCTAssertNotEqual(cancelled.terminationStatus, 0)
    }

    private func process(_ executable: String, _ arguments: [String] = []) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
