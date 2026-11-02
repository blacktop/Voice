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
        XCTAssertEqual(message.details, Data(String(repeating: "x", count: 5000).utf8))
        XCTAssertNil(message.pane)
    }

    func testPreviewOverrideKeepsCompleteSpeechForDetails() throws {
        let command = try VoiceSay.parse([
            "--notify", "--notify-no-pane", "--notify-message", "Summary", "hello",
        ])
        let message = try XCTUnwrap(
            command.notification.message(previewParts: ["First", "Last"], environment: [:]))
        XCTAssertEqual(message.message, "Summary")
        XCTAssertEqual(message.details, Data("First\n\nLast".utf8))
    }

    func testOversizedDetailsStillPostPreviewAndSpeak() async throws {
        let command = try VoiceSay.parse(["--notify", "--notify-no-pane", "hello"])
        let message = try XCTUnwrap(
            command.notification.message(
                previewParts: [
                    String(repeating: "a", count: NotificationDetails.maximumTextBytes), "last",
                ], environment: [:]))
        XCTAssertNil(message.details)
        XCTAssertEqual(message.message.utf8.count, 1024)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let posted = expectation(description: "preview posted")
        let spoken = expectation(description: "speech completed")
        try await VoiceSayNotificationFlow.run(
            message: message, at: url, whenBusy: .skip,
            report: { _ in XCTFail("reported preview-only notification") },
            post: { received in
                XCTAssertEqual(received, message)
                posted.fulfill()
                return NotificationRPCResponse()
            },
            speak: { spoken.fulfill() })
        await fulfillment(of: [posted, spoken], timeout: 2)
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

    func testZedProjectRequiresNotifyAndKeepsTmuxDefaults() throws {
        let project = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertThrowsError(try VoiceSay.parse(["--notify-zed-project", project, "hello"]))
        let command = try VoiceSay.parse([
            "--notify", "--notify-zed-project", project, "hello",
        ])
        let message = try XCTUnwrap(
            command.notification.message(
                previewParts: ["hello"],
                environment: ["TMUX_PANE": "%3", "TMUX": "/tmp/server,123,0"]))
        XCTAssertEqual(message.zedProject, project)
        XCTAssertEqual(message.pane, "%3")
        XCTAssertEqual(message.tmuxSocket, "/tmp/server")
        XCTAssertFalse(message.push)
    }

    func testNativeRexNotificationOptionsAndGroup() throws {
        let session = "session:00000000-0000-0000-0000-000000000001"
        let block = "block:00000000-0000-0000-0000-000000000002"
        let environment = [
            "REX_SESSION": session, "REX_BLOCK": block, "REX_SERVER": "/tmp/rex.sock",
        ]
        let options = try VoiceSayNotificationOptions.parse(["--notify", "--notify-no-pane"])
        let message = try XCTUnwrap(
            options.message(previewParts: ["hello"], environment: environment))
        XCTAssertEqual(message.rex?.block, block)
        XCTAssertEqual(message.group, "voice-say:" + block)
        let disabled = try VoiceSayNotificationOptions.parse([
            "--notify", "--notify-no-pane", "--notify-no-rex",
        ])
        XCTAssertNil(try disabled.message(previewParts: ["hello"], environment: environment)?.rex)
        for flags in [
            ["--notify-rex-session", session, "--notify-rex-block", block],
            [
                "--notify", "--notify-rex-session", session, "--notify-rex-block", block,
                "--notify-pane", "%2",
            ],
            [
                "--notify", "--notify-rex-session", session, "--notify-rex-block", block,
                "--notify-no-rex",
            ],
        ] {
            XCTAssertThrowsError(try VoiceSayNotificationOptions.parse(flags)) {
                XCTAssertEqual(VoiceSay.exitCode(for: $0).rawValue, 64)
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
