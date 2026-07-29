import Foundation

/// Races the first delivered microphone buffer against a bounded timeout.
///
/// Starting an audio engine only proves that Core Audio accepted the start
/// request. Bluetooth and recently disconnected inputs can report success
/// without ever delivering PCM, so callers should not publish a listening
/// state until this returns `true`.
public enum AudioCaptureReadiness {
    /// How long a started engine has to deliver its first buffer before the
    /// capture is treated as failed. Shared so both capture paths agree.
    public static let startupTimeout = Duration.seconds(2)

    public static func wait(
        for stream: AsyncStream<Void>,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                // Cancellation and expiry mean the same thing here: no buffer
                // arrived. Callers distinguish the two themselves.
                try? await ContinuousClock().sleep(for: timeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
