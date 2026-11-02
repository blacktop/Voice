import Darwin
import Foundation

/// Uses the user's macOS Read & Speak voice, including voices that the
/// AVSpeechSynthesizer voice picker does not expose.
public enum NotificationSystemSpeech {
    public static func speak(
        _ text: String, onStarted: @escaping @Sendable () -> Void
    ) async throws {
        try await NotificationSpeechReplay.speak(text, onStarted: onStarted) { chunk, started in
            try await speakChunk(chunk, onStarted: started)
        }
    }

    private static func speakChunk(
        _ text: String, onStarted: @escaping @Sendable () -> Void
    ) async throws {
        let data = Data(text.utf8)
        let input = try await BlockingCall.run { try inputFile(data) }
        defer { try? input.close() }
        let process = command(input: input)
        // One second per input byte is generous at ordinary speaking rates.
        // The absolute bound still stops a wedged speech process.
        let timeout = Duration.seconds(max(60, data.count))
        try await run(process, timeout: timeout, onStarted: onStarted)
    }

    static func command(input: FileHandle) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-f", "-"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// An unlinked, private file avoids pipe backpressure, SIGPIPE, argument
    /// size limits, and a named text file surviving an interrupted replay.
    static func inputFile(_ data: Data) throws -> FileHandle {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-speech-\(UUID().uuidString)").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard unlink(path) == 0 else {
            let code = errno
            try? input.close()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        do {
            try input.write(contentsOf: data)
            try input.seek(toOffset: 0)
            return input
        } catch {
            try? input.close()
            throw error
        }
    }

    static func run(
        _ process: Process, timeout: Duration,
        onStarted: @escaping @Sendable () -> Void
    ) async throws {
        try Task.checkCancellation()
        let (exits, continuation) = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        defer {
            process.terminationHandler = nil
            continuation.finish()
        }
        try await withTaskCancellationHandler {
            do {
                try await BlockingCall.run { try process.run() }
                try Task.checkCancellation()
                // say has no public first-audio callback. This reports the
                // handoff to macOS, which owns speech startup and playback.
                onStarted()
                let status = try await terminationStatus(exits, timeout: timeout)
                try Task.checkCancellation()
                guard status == 0 else {
                    throw VoiceNotificationError("macOS speech failed (exit status \(status))")
                }
            } catch {
                await stop(process)
                throw error
            }
        } onCancel: {
            if process.isRunning { process.interrupt() }
        }
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = try? await BlockingCall.run { process.waitUntilExit() }
    }

    private static func terminationStatus(_ exits: AsyncStream<Int32>, timeout: Duration)
        async throws -> Int32
    {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                for await status in exits { return status }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VoiceNotificationError("macOS speech exceeded its time limit")
            }
            defer { group.cancelAll() }
            guard let status = try await group.next() else { throw CancellationError() }
            return status
        }
    }
}
