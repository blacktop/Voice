import Darwin
import XCTest

@testable import VoiceMLX

/// `flock` is held per open file description, not per process, so two separate
/// `open()` calls contend even in one process. That is what lets these tests
/// exercise real exclusion without spawning subprocesses.
final class SpeechLockTests: XCTestCase {
    private struct LockFixture {
        let url: URL

        init() {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("speech-lock-\(UUID().uuidString).lock")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Takes the lock the way another process would, and releases it at the end
    /// of the test.
    private func holdLock(at url: URL) throws -> Int32 {
        let descriptor = try SpeechLock.openLockFile(url)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0, "could not take the lock")
        addTeardownBlock { close(descriptor) }
        return descriptor
    }

    func testLockFileLivesBesideTheModelStoreNotInsideIt() {
        let lock = SpeechLock.defaultURL
        let store = MLXSpeechRecognizer.modelStoreURL
        XCTAssertEqual(lock.deletingLastPathComponent(), MLXSpeechRecognizer.containerURL)
        XCTAssertFalse(
            lock.path.hasPrefix(store.path + "/"),
            "a lock inside the store could be mistaken for a downloaded model"
        )
    }

    func testUncontendedCallRunsTheBodyAndReleasesTheLock() async throws {
        let fixture = LockFixture()
        defer { fixture.cleanup() }

        var ran = false
        var contended = false
        let didRun = try await SpeechLock.withLock(
            at: fixture.url,
            whenBusy: .skip,
            onContended: { contended = true },
            body: { ran = true }
        )
        XCTAssertTrue(didRun)
        XCTAssertTrue(ran)
        XCTAssertFalse(contended, "an uncontended call must stay silent")

        // Released on exit, so a second acquisition must not report contention.
        let secondRan = try await SpeechLock.withLock(
            at: fixture.url,
            whenBusy: .skip,
            body: {}
        )
        XCTAssertTrue(secondRan, "the lock was not released")
    }

    /// The default policy for announcements: several fired at once collapse to
    /// one rather than queueing minutes of stale speech.
    func testBusyLockSkipsWithoutRunningTheBody() async throws {
        let fixture = LockFixture()
        defer { fixture.cleanup() }
        _ = try holdLock(at: fixture.url)

        var ran = false
        var contended = false
        let didRun = try await SpeechLock.withLock(
            at: fixture.url,
            whenBusy: .skip,
            onContended: { contended = true },
            body: { ran = true }
        )
        XCTAssertFalse(didRun, "skipped work must report that it did not run")
        XCTAssertFalse(ran, "body ran while another process held the lock")
        XCTAssertTrue(contended)
    }

    func testWaitQueuesBehindTheCurrentHolder() async throws {
        let fixture = LockFixture()
        defer { fixture.cleanup() }
        let held = try holdLock(at: fixture.url)

        // Released the moment contention is observed rather than after a fixed
        // sleep, so the test carries no timing assumption.
        let (contention, reachedWait) = AsyncStream<Void>.makeStream()
        let url = fixture.url
        let task = Task {
            try await SpeechLock.withLock(
                at: url,
                whenBusy: .wait,
                onContended: { reachedWait.yield() },
                body: {}
            )
        }
        var observed = contention.makeAsyncIterator()
        await observed.next()
        flock(held, LOCK_UN)

        let didRun = try await task.value
        XCTAssertTrue(didRun, "queued work never ran")
    }

    func testLockIsReleasedWhenTheBodyThrows() async throws {
        let fixture = LockFixture()
        defer { fixture.cleanup() }
        struct Boom: Error {}

        do {
            try await SpeechLock.withLock(at: fixture.url, whenBusy: .skip, body: { throw Boom() })
            XCTFail("expected the body's error to propagate")
        } catch is Boom {
            // expected
        }
        // A leaked lock here would skip every later invocation.
        let didRun = try await SpeechLock.withLock(
            at: fixture.url,
            whenBusy: .skip,
            body: {}
        )
        XCTAssertTrue(didRun, "the lock survived a throwing body")
    }

    func testLockFailureDescribesTheUnderlyingErrno() {
        let error = SpeechLockError.failed("/tmp/x.lock", EOPNOTSUPP)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("/tmp/x.lock"), message)
        XCTAssertTrue(
            message.contains(String(cString: strerror(EOPNOTSUPP))),
            "the reason must name the OS error: \(message)"
        )
    }
}
