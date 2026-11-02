import UserNotifications
import XCTest

@testable import VoiceNotifications

final class NotificationDestinationTests: XCTestCase {
    private let tmux = TmuxNotificationTarget(
        pane: "%3", socket: "/tmp/test-tmux",
        server: TmuxProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1))

    func testDetailsDecodeBothClickFormatsWithoutLosingTheTarget() throws {
        let project = ZedProjectTarget(path: "/tmp/project")
        let combined = NotificationClickTarget(tmux: tmux, zedProject: project)
        let content = UNMutableNotificationContent()
        content.userInfo = [
            NotificationDetails.userInfoKey: Data("Full text".utf8),
            "voice-click": try JSONEncoder().encode(combined),
        ]
        var details = try VoiceNotificationAppDelegate.details(for: content)
        XCTAssertEqual(details.clickTarget, combined)
        XCTAssertEqual(details.destination, .zed)

        content.userInfo = [
            NotificationDetails.userInfoKey: Data("Full text".utf8),
            "voice-tmux": try JSONEncoder().encode(tmux),
        ]
        details = try VoiceNotificationAppDelegate.details(for: content)
        XCTAssertEqual(details.clickTarget, NotificationClickTarget(tmux: tmux))
        XCTAssertEqual(details.destination, .terminal)
    }

    @MainActor
    func testAbsentAndUnreadableTargetsOfferNoAction() throws {
        let content = UNMutableNotificationContent()
        for target in [Data("invalid".utf8), Data(repeating: 0, count: 8193), Data("{}".utf8)] {
            content.userInfo = [
                NotificationDetails.userInfoKey: Data("Full text".utf8),
                "voice-click": target,
            ]
            let details = try VoiceNotificationAppDelegate.details(for: content)
            XCTAssertNil(details.destination)
            let presentation = NotificationDetailsPresentation(
                openDestination: { _ in XCTFail("opened an absent target") },
                speak: { _, _, _ in })
            presentation.show(details)
            presentation.goToDestination()
            XCTAssertFalse(presentation.isOpeningDestination)
        }
        XCTAssertNil(NotificationDetails(title: "Title", subtitle: "", text: "Text").destination)
    }

    @MainActor
    func testDestinationFailureIsVisibleAndCanBeRetried() async {
        let target = NotificationClickTarget(tmux: tmux)
        var opened: [NotificationClickTarget] = []
        let presentation = NotificationDetailsPresentation(
            openDestination: {
                opened.append($0)
                if opened.count == 1 { throw VoiceNotificationError("test destination failure") }
            }, speak: { _, _, _ in })
        presentation.show(details(target))
        presentation.goToDestination()
        presentation.goToDestination()
        await waitForDestination(presentation)
        XCTAssertEqual(opened, [target])
        XCTAssertEqual(presentation.destinationError, "test destination failure")
        presentation.goToDestination()
        XCTAssertNil(presentation.destinationError)
        await waitForDestination(presentation)
        XCTAssertEqual(opened, [target, target])
        XCTAssertNil(presentation.destinationError)
    }

    @MainActor
    func testReplacementAndCloseCancelObsoleteDestinationWork() async {
        let first = NotificationClickTarget(tmux: tmux)
        let second = NotificationClickTarget(zedProject: ZedProjectTarget(path: "/tmp/project"))
        let firstStarted = expectation(description: "first destination started")
        let secondStarted = expectation(description: "second destination started")
        let secondFinished = expectation(description: "second destination finished")
        var firstFinish: CheckedContinuation<Void, Never>?
        var secondFinish: CheckedContinuation<Void, Never>?
        var opened: [NotificationClickTarget] = []
        let presentation = NotificationDetailsPresentation(
            openDestination: { target in
                opened.append(target)
                if target == first {
                    await withCheckedContinuation {
                        firstFinish = $0
                        firstStarted.fulfill()
                    }
                } else {
                    await withCheckedContinuation {
                        secondFinish = $0
                        secondStarted.fulfill()
                    }
                    secondFinished.fulfill()
                }
                try Task.checkCancellation()
            }, speak: { _, _, _ in })
        presentation.show(details(first))
        presentation.goToDestination()
        await fulfillment(of: [firstStarted], timeout: 2)
        presentation.show(details(second))
        presentation.goToDestination()
        await Task.yield()
        XCTAssertEqual(opened, [first])
        firstFinish?.resume()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(opened, [first, second])
        XCTAssertTrue(presentation.isOpeningDestination)
        XCTAssertNil(presentation.destinationError)
        presentation.close()
        secondFinish?.resume()
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertFalse(presentation.isOpeningDestination)
        XCTAssertNil(presentation.destinationError)
    }

    @MainActor
    func testCancelledSelectionDoesNotOpenOrRaiseAnObsoleteDestination() async {
        let selected = expectation(description: "tmux selection started")
        var finish: CheckedContinuation<Void, Never>?
        let target = NotificationClickTarget(
            tmux: tmux, zedProject: ZedProjectTarget(path: "/tmp/project"))
        let operation = Task {
            try await target.activate(
                selectTmux: { target in
                    await withCheckedContinuation {
                        finish = $0
                        selected.fulfill()
                    }
                    return target.server
                }, openZed: { _ in XCTFail("opened an obsolete project") },
                raiseHost: { _ in XCTFail("raised an obsolete terminal") })
        }
        await fulfillment(of: [selected], timeout: 2)
        operation.cancel()
        finish?.resume()
        do {
            try await operation.value
            XCTFail("cancelled selection succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func details(_ target: NotificationClickTarget) -> NotificationDetails {
        NotificationDetails(title: "Title", subtitle: "", text: "Full text", clickTarget: target)
    }

    @MainActor
    private func waitForDestination(_ presentation: NotificationDetailsPresentation) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while presentation.isOpeningDestination, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(presentation.isOpeningDestination)
    }
}
