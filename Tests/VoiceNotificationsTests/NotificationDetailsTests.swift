import UserNotifications
import XCTest

@testable import VoiceNotifications

final class NotificationDetailsTests: XCTestCase {
    func testFullTextIsExactAndBounded() throws {
        let text = String(repeating: "A full paragraph 🦉.\n", count: 1000)
        let data = try NotificationDetails.encode(parts: [text, "Last paragraph."])
        XCTAssertEqual(try NotificationDetails.text(from: data), text + "\n\nLast paragraph.")
        XCTAssertEqual(
            try NotificationDetails.text(from: NotificationDetails.encode(parts: ["", "Last"])),
            "\n\nLast")
        for invalid in [
            Data(), Data([0xFF]), Data([0]),
            Data(repeating: 65, count: NotificationDetails.maximumTextBytes + 1),
        ] {
            XCTAssertThrowsError(try NotificationDetails.text(from: invalid))
        }
        XCTAssertThrowsError(
            try NotificationDetails.encode(parts: [
                String(repeating: "a", count: NotificationDetails.maximumTextBytes), "b",
            ]))
        XCTAssertEqual(
            try NotificationDetails.encodeIfFits(parts: [
                String(repeating: "a", count: NotificationDetails.maximumTextBytes)
            ])?.count,
            NotificationDetails.maximumTextBytes)
        XCTAssertNil(
            try NotificationDetails.encodeIfFits(parts: [
                String(repeating: "a", count: NotificationDetails.maximumTextBytes), "b",
            ]))
    }

    func testRedundantDetailsUseCompatibleRPC() throws {
        let context = try NotificationContext(
            pane: nil, noPane: true, tmuxSocket: nil, push: false, environment: [:])
        let message = try context.message(
            title: "Build", subtitle: nil, message: "Passed", group: "build",
            details: Data("Passed".utf8))
        XCTAssertNil(message.details)
        let (request, failure) = try NotificationClient.prepare(.post(message))
        XCTAssertNil(failure)
        guard case .post(let prepared) = request else {
            return XCTFail("ordinary posts must remain compatible with older Voice apps")
        }
        XCTAssertEqual(prepared, message)
    }

    func testFullTextRPCIsVersionedAndFitsItsFrame() throws {
        // These valid UTF-8 bytes produce '/' in base64. Escaping those slashes
        // would exceed a bound calculated from base64's ordinary 4/3 overhead.
        let text = String(repeating: "\u{FFFF}", count: NotificationDetails.maximumTextBytes / 3)
        let message = NotificationMessage(
            title: "Build", message: "Preview", group: "build", zedProject: "/tmp/project",
            details: try NotificationDetails.encode(parts: [text]))
        let (request, failure) = try NotificationClient.prepare(.post(message))
        XCTAssertNil(failure)
        guard case .postWithDetails(let prepared) = request else {
            return XCTFail("an old app could silently discard the details")
        }
        XCTAssertEqual(prepared, message)
        let body = try NotificationSocket.encoded(request)
        XCTAssertLessThanOrEqual(body.count, NotificationSocket.maximumFrame)
        guard
            case .postWithDetails(let decoded) = try JSONDecoder().decode(
                NotificationRPCRequest.self, from: body)
        else { return XCTFail("wrong RPC discriminator") }
        XCTAssertEqual(decoded.details, message.details)
    }

    @MainActor
    func testActionAndLocalMetadataPreserveTheDefaultTarget() throws {
        let target = NotificationClickTarget(
            zedProject: ZedProjectTarget(path: "/tmp/project"))
        let full = try NotificationDetails.encode(parts: [String(repeating: "full ", count: 2000)])
        let message = NotificationMessage(
            title: "Build", subtitle: "Project", message: "Short preview", group: "build",
            details: full)
        let category = VoiceNotificationAppDelegate.messageCategory()
        XCTAssertEqual(category.identifier, NotificationDetails.categoryIdentifier)
        XCTAssertEqual(category.actions.map(\.identifier), [NotificationDetails.actionIdentifier])
        XCTAssertTrue(try XCTUnwrap(category.actions.first).options.contains(.foreground))
        let content = try VoiceNotificationAppDelegate.content(for: message, target: target)
        XCTAssertEqual(content.categoryIdentifier, category.identifier)
        XCTAssertEqual(content.body, "Short preview")
        XCTAssertEqual(content.userInfo[NotificationDetails.userInfoKey] as? Data, full)
        XCTAssertEqual(NotificationClickTarget.decode(content.userInfo), target)
        let details = try VoiceNotificationAppDelegate.details(for: content)
        XCTAssertEqual(details.title, message.title)
        XCTAssertEqual(details.subtitle, message.subtitle)
        XCTAssertEqual(details.text, try NotificationDetails.text(from: full))
        XCTAssertEqual(details.clickTarget, target)
        XCTAssertEqual(details.destination, .zed)
        let legacy = NotificationMessage(title: "Old", message: "Complete body", group: "old")
        let legacyContent = try VoiceNotificationAppDelegate.content(for: legacy, target: target)
        XCTAssertEqual(
            legacyContent.userInfo[NotificationDetails.userInfoKey] as? Data,
            Data("Complete body".utf8))
    }

    func testDetailsNeverEnterPhonePayload() throws {
        let message = NotificationMessage(
            title: "Build", message: "Preview", group: "build", push: true,
            details: try NotificationDetails.encode(parts: ["Private complete text"]))
        let configuration = NtfyConfiguration(
            server: "https://example.test", topic: "private", token: "test-token")
        let request = try NtfyPush.request(for: message, configuration: configuration)
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
        XCTAssertEqual(
            payload as? [String: String],
            ["topic": "private", "title": "Build", "message": "Preview"])
    }

    @MainActor
    func testReplacingAndClosingDetailsCancelReplayInOrder() async throws {
        let firstStarted = expectation(description: "first replay started")
        let secondStarted = expectation(description: "second replay started")
        let secondFinished = expectation(description: "second replay finished")
        var firstContinuation: CheckedContinuation<Void, Never>?
        var secondContinuation: CheckedContinuation<Void, Never>?
        var spoken: [String] = []
        let presentation = NotificationDetailsPresentation { text, _, _ in
            spoken.append(text)
            if text == "first" {
                await withCheckedContinuation {
                    firstContinuation = $0
                    firstStarted.fulfill()
                }
            } else {
                await withCheckedContinuation {
                    secondContinuation = $0
                    secondStarted.fulfill()
                }
                secondFinished.fulfill()
            }
            try Task.checkCancellation()
        }
        presentation.show(NotificationDetails(title: "One", subtitle: "", text: "first"))
        let firstContentID = presentation.contentID
        presentation.startSpeaking()
        await fulfillment(of: [firstStarted], timeout: 2)
        presentation.show(NotificationDetails(title: "Two", subtitle: "", text: "second"))
        XCTAssertNotEqual(presentation.contentID, firstContentID)
        XCTAssertEqual(presentation.details?.text, "second")
        presentation.startSpeaking()
        await Task.yield()
        XCTAssertEqual(spoken, ["first"])
        firstContinuation?.resume()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(spoken, ["first", "second"])
        presentation.close()
        secondContinuation?.resume()
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertNil(presentation.details)
        XCTAssertFalse(presentation.isActive)
        XCTAssertNil(presentation.error)
    }

    @MainActor
    func testReplayFailureIsVisibleAndCanBeRetried() async throws {
        let presentation = NotificationDetailsPresentation { _, _, _ in
            throw VoiceNotificationError("test playback failure")
        }
        presentation.show(NotificationDetails(title: "Build", subtitle: "", text: "Full text"))
        presentation.startSpeaking()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while presentation.isActive, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(presentation.isActive)
        XCTAssertEqual(presentation.error, "test playback failure")
        presentation.show(NotificationDetails(title: "Next", subtitle: "", text: "Next"))
        XCTAssertNil(presentation.error)
    }

    @MainActor
    func testExternalReplayCancellationIsVisible() async {
        let presentation = NotificationDetailsPresentation { _, _, _ in
            throw CancellationError()
        }
        presentation.show(NotificationDetails(title: "Build", subtitle: "", text: "Full text"))
        presentation.startSpeaking()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while presentation.isActive, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(presentation.isActive)
        XCTAssertEqual(presentation.error, "Playback was interrupted. Press Speak to try again.")
    }

    @MainActor
    func testReplayWaitsForAudioAndKeepsTheFastDefault() async throws {
        let requested = expectation(description: "replay requested")
        var started: (@Sendable () -> Void)?
        var finish: CheckedContinuation<Void, Never>?
        var voices: [NotificationReplayVoice] = []
        let presentation = NotificationDetailsPresentation { _, voice, onStarted in
            voices.append(voice)
            started = onStarted
            await withCheckedContinuation {
                finish = $0
                requested.fulfill()
            }
            try Task.checkCancellation()
        }
        presentation.show(NotificationDetails(title: "Title", subtitle: "", text: "Full text"))
        presentation.startSpeaking()
        XCTAssertEqual(presentation.phase, .preparing)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(voices, [.system])
        XCTAssertEqual(presentation.phase, .preparing)
        started?()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while presentation.phase == .preparing, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(presentation.phase, .speaking)
        presentation.stop()
        finish?.resume()
        XCTAssertEqual(presentation.phase, .idle)
    }

    @MainActor
    func testAlternativeVoicesDoNotChangeTheDefault() async throws {
        var voices: [NotificationReplayVoice] = []
        let presentation = NotificationDetailsPresentation { _, voice, started in
            voices.append(voice)
            started()
        }
        presentation.show(NotificationDetails(title: "Title", subtitle: "", text: "Full text"))
        for choice: NotificationReplayVoice? in [.selected, .appleSpeech, nil] {
            presentation.startSpeaking(using: choice)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while presentation.isActive, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(presentation.phase, .idle)
        }
        XCTAssertEqual(voices, [.selected, .appleSpeech, .system])
    }
}
