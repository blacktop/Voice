import ArgumentParser
import Darwin
import Synchronization
import VoiceNotifications
import XCTest

@testable import VoiceMLX

final class VoiceSayNotificationTests: XCTestCase {
    func testOptionsRequireOptInAndPreviewIsBounded() throws {
        XCTAssertThrowsError(try VoiceSay.parse(["--notify-push", "hello"]))
        XCTAssertThrowsError(try VoiceSay.parse(["--notify-title", "Build", "hello"]))
        XCTAssertThrowsError(
            try VoiceSay.parse(["--notify", "--notify-pane", "%2", "--notify-no-pane", "hello"])
        ) { error in
            let message = VoiceSay.message(for: error)
            XCTAssertTrue(message.contains("--notify-pane"))
            XCTAssertTrue(message.contains("--notify-no-pane"))
        }
        let command = try VoiceSay.parse([
            "--notify", "--notify-title", "Build", "--notify-no-pane", "hello",
        ])
        let message = try XCTUnwrap(
            command.notification.message(
                previewParts: [String(repeating: "x", count: 5000)], environment: [:]))
        XCTAssertEqual(message.title, "Build")
        XCTAssertEqual(message.message.utf8.count, 1024)
        XCTAssertNil(message.pane)
    }

    func testInvalidInheritedTmuxContextIsAUsageError() throws {
        var options = try VoiceSayNotificationOptions.parse(["--notify", "--notify-no-pane"])
        options.notifyNoPane = false
        for environment in [
            ["TMUX_PANE": "not-a-pane"],
            ["TMUX": "/" + String(repeating: "x", count: 104) + ",123,0"],
        ] {
            XCTAssertThrowsError(try options.validate(environment: environment)) { error in
                XCTAssertEqual(VoiceSay.exitCode(for: error).rawValue, 64)
            }
        }
    }

    func testSkippedSpeechDoesNotPost() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let held = try SpeechLock.openLockFile(url)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        try await VoiceSayNotificationFlow.run(
            message: NotificationMessage(title: "x", message: "x", group: "x"),
            at: url, whenBusy: .skip, report: { _ in XCTFail("reported skipped notification") },
            post: { _ in
                XCTFail("posted without lock")
                return NotificationRPCResponse()
            },
            speak: { XCTFail("spoke without lock") })
    }

    func testNotificationFailureStillSpeaksThenFails() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let started = expectation(description: "speech started before notification reply")
        let releaseReply = AsyncStream<Void>.makeStream()
        let events = Mutex<[String]>([])
        let operation = Task {
            try await VoiceSayNotificationFlow.run(
                message: NotificationMessage(title: "x", message: "x", group: "x"),
                at: url, whenBusy: .skip,
                report: { _ in events.withLock { $0.append("reported") } },
                post: { _ in
                    for await _ in releaseReply.stream {}
                    return NotificationRPCResponse(failures: ["push failed"])
                },
                speak: {
                    events.withLock { $0.append("spoke") }
                    started.fulfill()
                })
        }
        await fulfillment(of: [started], timeout: 2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var lockReleased = false
        while !lockReleased, ContinuousClock.now < deadline {
            lockReleased = try await SpeechLock.withLock(at: url, whenBusy: .skip) {}
            if !lockReleased { try await Task.sleep(for: .milliseconds(10)) }
        }
        releaseReply.continuation.finish()
        XCTAssertTrue(lockReleased, "notification delivery retained the speech lock")
        do {
            try await operation.value
            XCTFail("delivery failure must escape after speech")
        } catch {
            XCTAssertEqual(events.withLock { $0 }, ["spoke", "reported"])
            XCTAssertTrue(error.localizedDescription.contains("push failed"))
        }
    }
}
