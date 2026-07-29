import Darwin
import Foundation

/// Cross-process mutual exclusion for speech synthesis, covering the shared
/// model store.
///
/// Two speakers at once each load their own copy of the checkpoint (about
/// 3.2 GB resident for the 1.7B tier) and play through separate audio engines,
/// so the utterances overlap. If both fetch the same checkpoint they also race
/// inside the Hugging Face cache, which resumes into one shared
/// `<etag>.incomplete` file with no locking of its own.
///
/// `flock(2)` is used rather than `NSDistributedLock` or a named semaphore
/// because the kernel releases it when the descriptor closes, including when
/// the holder is killed; the alternatives leave a stale lock that a later run
/// has to detect and break. Swift's `Synchronization.Mutex` does not apply:
/// it is an in-process primitive.
///
/// The lock is advisory, so it excludes only participants that take it. Today
/// that is `voice-say`; the app still downloads and speaks without it, so an
/// app-and-CLI race remains possible until it adopts this type.
public enum SpeechLock {
    /// What to do when another process already holds the lock. The choice
    /// belongs to the caller: it depends on whether the utterance matters more
    /// than its timing, which a lock cannot know.
    public enum Contention {
        /// Give up and let the caller move on.
        case skip
        /// Queue behind the current holder.
        case wait
    }

    /// A lock covering the model store, which is what concurrent callers
    /// contend for. Kept beside the store rather than inside it so it is never
    /// mistaken for a downloaded model.
    public static var defaultURL: URL {
        MLXSpeechRecognizer.containerURL
            .appendingPathComponent("speech.lock", isDirectory: false)
    }

    /// Runs `body` while holding the lock, returning whether it ran. False
    /// means `.skip` was chosen and another process held the lock.
    ///
    /// `onContended` fires only when the lock is actually taken, so an
    /// uncontended call stays silent. A `.wait` acquisition blocks the calling
    /// thread, which suits a command-line caller with nothing else to run; an
    /// interactive caller should prefer `.skip`.
    @discardableResult
    public static func withLock(
        at url: URL = defaultURL,
        whenBusy: Contention,
        onContended: () -> Void = {},
        body: () async throws -> Void
    ) async throws -> Bool {
        // Closing the descriptor releases the lock, which is the property that
        // makes flock crash-safe; an explicit unlock would add nothing.
        let descriptor = try openLockFile(url)
        defer { close(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            // Only contention may be silently skipped. Treating every failure
            // as busy would turn an unusable lock — an unsupported filesystem,
            // a bad descriptor — into a caller that never speaks and never
            // says why.
            guard code == EWOULDBLOCK else {
                throw SpeechLockError.failed(url.path(percentEncoded: false), code)
            }
            onContended()
            if whenBusy == .skip {
                return false
            }
            try waitForLock(descriptor, url: url)
        }
        try await body()
        return true
    }

    /// Opens the lock file, creating it and its directory when absent.
    static func openLockFile(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw SpeechLockError.failed(url.path(percentEncoded: false), errno)
        }
        return descriptor
    }

    /// Blocking acquisition, retrying when a signal interrupts the wait.
    private static func waitForLock(_ descriptor: Int32, url: URL) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            guard code == EINTR else {
                throw SpeechLockError.failed(url.path(percentEncoded: false), code)
            }
        }
    }
}

public enum SpeechLockError: LocalizedError, Equatable {
    case failed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .failed(let path, let code):
            let reason = String(cString: strerror(code))
            return "Could not take the speech lock at \(path): \(reason)."
        }
    }
}
