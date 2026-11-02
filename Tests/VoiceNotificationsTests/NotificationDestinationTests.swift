import UserNotifications
import XCTest

@testable import VoiceNotifications

final class NotificationDestinationTests: XCTestCase {
    private let tmux = TmuxNotificationTarget(
        pane: "%3", socket: "/tmp/test-tmux",
        server: TmuxProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1))

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
