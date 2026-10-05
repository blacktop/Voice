import Foundation
import Synchronization

/// Transfers a fixed number of scheduled-buffer slots from playback
/// completions back to the synthesis producer.
final class PlaybackBufferQueue: Sendable {
    struct Reservation: Sendable {
        fileprivate let generation: UUID
    }

    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Reservation, Error>
    }

    private struct State: Sendable {
        var pendingCount = 0
        var waiters: [Waiter] = []
        var drainContinuation: CheckedContinuation<Void, Error>?
        var generation = UUID()
        var drainedAt: ContinuousClock.Instant?
        var idleSeconds = 0.0
        var isPaused = false
        var hasPlayed = false
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func reserve() async throws -> Reservation {
        let id = UUID()
        let reservation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Reservation, Error>) in
                let immediateResult: Result<Reservation, Error>? = state.withLock { state in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard state.pendingCount >= capacity else {
                        if state.pendingCount == 0, let drainedAt = state.drainedAt {
                            state.idleSeconds += drainedAt.duration(to: .now) / .seconds(1)
                            state.drainedAt = nil
                        }
                        state.pendingCount += 1
                        return .success(Reservation(generation: state.generation))
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
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
        let (waiter, drain) = state.withLock {
            (state: inout State) -> (
                (CheckedContinuation<Reservation, Error>, Reservation)?,
                CheckedContinuation<Void, Error>?
            ) in
            guard reservation.generation == state.generation, state.pendingCount > 0 else {
                return (nil, nil)
            }
            if !state.waiters.isEmpty {
                let continuation = state.waiters.removeFirst().continuation
                let replacement = Reservation(generation: state.generation)
                return ((continuation, replacement), nil)
            }
            state.pendingCount -= 1
            guard state.pendingCount == 0 else { return (nil, nil) }
            state.hasPlayed = true
            state.drainedAt = state.isPaused ? nil : .now
            let drain = state.drainContinuation
            state.drainContinuation = nil
            return (nil, drain)
        }
        if let (continuation, reservation) = waiter {
            continuation.resume(returning: reservation)
        }
        drain?.resume()
    }

    func awaitDrain() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Result<Void, Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    guard state.pendingCount > 0 || !state.waiters.isEmpty else {
                        return .success(())
                    }
                    state.drainContinuation = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let (waiters, drain) = state.withLock { state in
            let captured = (state.waiters, state.drainContinuation)
            state.waiters.removeAll()
            state.drainContinuation = nil
            state.pendingCount = 0
            state.generation = UUID()
            state.drainedAt = nil
            state.idleSeconds = 0
            state.isPaused = false
            state.hasPlayed = false
            return captured
        }
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        drain?.resume(throwing: CancellationError())
    }

    var pendingBufferCount: Int {
        state.withLock { $0.pendingCount }
    }

    /// Time between an exhausted playback queue and the next audio reservation.
    /// Excludes initial model startup and the final drain after speech finishes.
    var idleSeconds: Double {
        state.withLock { $0.idleSeconds }
    }

    /// A deliberate pause is not synthesis starvation, even when it begins
    /// while the player is waiting for the first chunk of the next segment.
    func setPaused(_ paused: Bool) {
        state.withLock { state in
            guard paused != state.isPaused else { return }
            state.isPaused = paused
            if paused, let drainedAt = state.drainedAt {
                state.idleSeconds += drainedAt.duration(to: .now) / .seconds(1)
                state.drainedAt = nil
            } else if !paused, state.pendingCount == 0, state.hasPlayed {
                state.drainedAt = .now
            }
        }
    }

    var waitingProducerCount: Int {
        state.withLock { $0.waiters.count }
    }

    private func cancelWaiter(id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Reservation, Error>? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
