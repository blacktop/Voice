import ArgumentParser
import Darwin
import Foundation
import VoiceNotifications

enum NotificationDetailsInput {
    static func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try read(STDIN_FILENO) })
            }
        }
    }

    /// The command owns stdin while reading. Restore its shared file-status
    /// flags before returning so a shell using the same input is unaffected.
    static func read(_ descriptor: Int32, timeout: Duration = .seconds(60)) throws -> Data {
        guard isatty(descriptor) == 0 else {
            throw ValidationError("--details-stdin requires piped or redirected text.")
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw inputError()
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let maximum = NotificationDetails.maximumTextBytes
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try wait(descriptor, until: deadline)
            let count = Darwin.read(
                descriptor, &buffer, min(buffer.count, maximum + 1 - data.count))
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw inputError()
            }
            guard count <= maximum - data.count else {
                throw ValidationError("Notification details exceed the 8 MiB limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func wait(_ descriptor: Int32, until deadline: ContinuousClock.Instant) throws {
        while ContinuousClock.now < deadline {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&item, 1, 100)
            if status < 0, errno == EINTR { continue }
            guard status >= 0 else { throw inputError() }
            if status == 0 { continue }
            guard item.revents & Int16(POLLIN | POLLHUP) != 0 else {
                throw VoiceNotificationError("notification details input disconnected")
            }
            return
        }
        throw VoiceNotificationError("notification details input timed out")
    }

    private static func inputError() -> VoiceNotificationError {
        VoiceNotificationError(
            "could not read notification details: \(String(cString: strerror(errno)))")
    }
}
