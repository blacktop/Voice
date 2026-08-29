import Foundation

/// Transfers a fixed number of scheduled-buffer slots from playback
/// completions back to the synthesis producer.
final class PlaybackBufferQueue: @unchecked Sendable {
    struct Reservation: Sendable {
        fileprivate let generation: UUID
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Reservation, Error>
    }

    private let capacity: Int
    private let lock = NSLock()
    private var pendingCount = 0
    private var waiters: [Waiter] = []
    private var drainContinuation: CheckedContinuation<Void, Error>?
    private var generation = UUID()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func reserve() async throws -> Reservation {
        let id = UUID()
        let reservation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Reservation, Error>) in
                let immediateResult: Result<Reservation, Error>? = withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard pendingCount >= capacity else {
                        pendingCount += 1
                        return .success(Reservation(generation: generation))
                    }
                    waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
        do {
            try Task.checkCancellation()
            return reservation
        } catch {
            complete(reservation)
            throw error
        }
    }

    func complete(_ reservation: Reservation) {
        let (waiter, drain) = withLock {
            () -> (
                (CheckedContinuation<Reservation, Error>, Reservation)?,
                CheckedContinuation<Void, Error>?
            ) in
            guard reservation.generation == generation, pendingCount > 0 else {
                return (nil, nil)
            }
            if !waiters.isEmpty {
                let continuation = waiters.removeFirst().continuation
                let replacement = Reservation(generation: generation)
                return ((continuation, replacement), nil)
            }
            pendingCount -= 1
            guard pendingCount == 0 else { return (nil, nil) }
            let drain = drainContinuation
            drainContinuation = nil
            return (nil, drain)
        }
        if let (continuation, reservation) = waiter {
            continuation.resume(returning: reservation)
        }
        drain?.resume()
    }

    func awaitDrain() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let resumeImmediately = withLock {
                guard pendingCount > 0 || !waiters.isEmpty else { return true }
                drainContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func cancel() {
        let (waiters, drain) = withLock {
            let captured = (self.waiters, drainContinuation)
            self.waiters.removeAll()
            drainContinuation = nil
            pendingCount = 0
            generation = UUID()
            return captured
        }
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        drain?.resume(throwing: CancellationError())
    }

    var pendingBufferCount: Int {
        withLock { pendingCount }
    }

    var waitingProducerCount: Int {
        withLock { waiters.count }
    }

    private func cancelWaiter(id: UUID) {
        let continuation = withLock { () -> CheckedContinuation<Reservation, Error>? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
