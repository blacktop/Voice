import Foundation
import Synchronization
import XCTest

@testable import VoiceNotifications

final class NotificationSpeechReplayTests: XCTestCase {
    func testChunksPreserveTextAndPreferSentenceBoundaries() throws {
        let first = String(repeating: "word ", count: 150) + "Done."
        let text = first + " More " + String(repeating: "🦉", count: 1000)
        var chunks = try NotificationSpeechChunks(text)
        XCTAssertEqual(chunks.next(), first)
        var rebuilt = first
        while let chunk = chunks.next() {
            XCTAssertLessThanOrEqual(chunk.utf8.count, NotificationSpeechChunks.maximumBytes)
            rebuilt += chunk
        }
        XCTAssertEqual(rebuilt, text)
    }

    func testLargeReplayIsSequentialAndReportsStartOnce() async throws {
        let line = "Synthetic notification speech.\n"
        let limit = NotificationDetails.maximumTextBytes
        let text =
            String(repeating: line, count: limit / line.utf8.count)
            + String(repeating: "x", count: limit % line.utf8.count)
        let received = Mutex(Data())
        let starts = Mutex(0)
        try await NotificationSpeechReplay.speak(
            text, onStarted: { starts.withLock { $0 += 1 } },
            using: { chunk, started in
                XCTAssertLessThanOrEqual(chunk.utf8.count, NotificationSpeechChunks.maximumBytes)
                received.withLock { $0.append(contentsOf: chunk.utf8) }
                started()
                started()
            })
        XCTAssertEqual(received.withLock { $0 }, Data(text.utf8))
        XCTAssertEqual(starts.withLock { $0 }, 1)
    }

    func testCancellationDoesNotStartTheNextChunk() async throws {
        let entered = expectation(description: "first chunk entered")
        let release = AsyncStream<Void>.makeStream()
        let calls = Mutex(0)
        let task = Task {
            try await NotificationSpeechReplay.speak(
                String(repeating: "word ", count: 2000), onStarted: {}
            ) { _, _ in
                let count = calls.withLock {
                    $0 += 1
                    return $0
                }
                XCTAssertEqual(count, 1)
                entered.fulfill()
                for await _ in release.stream {}
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        release.continuation.finish()
        do {
            try await task.value
            XCTFail("cancelled replay completed normally")
        } catch is CancellationError {
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testInvalidInputNeverReachesTheSpeaker() async {
        for text in ["", "embedded\0null", String(repeating: "x", count: 8 * 1024 * 1024 + 1)] {
            do {
                try await NotificationSpeechReplay.speak(
                    text, onStarted: {},
                    using: { _, _ in XCTFail("invalid text reached the speaker") })
                XCTFail("invalid text was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("invalid or exceed 8 MiB"))
            }
        }
    }
}
