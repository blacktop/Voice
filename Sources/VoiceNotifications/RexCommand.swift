import Darwin
import Foundation

/// Runs only the fixed Rex control methods used by notification targeting.
struct RexCommand: Sendable {
    private let executable: URL
    private let socket: String

    init(socket: String) throws {
        self.socket = try RexNotificationContext.socketPath(socket)
        let candidates = [
            NSHomeDirectory() + "/.local/bin/rex", "/opt/homebrew/bin/rex", "/usr/local/bin/rex",
            "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
            "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile) else {
            throw VoiceNotificationError("the Rex CLI is not installed")
        }
        executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    func run(_ method: RexMethod, arguments: Data) async throws -> Data {
        guard arguments.count <= 8192, let json = String(data: arguments, encoding: .utf8) else {
            throw VoiceNotificationError("Rex request exceeds its size limit")
        }
        return try await BlockingCall.run {
            try Self.checkSocket(socket)
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "--autostart=false", "--timeout", "2s", "--color", "never",
                "--server", socket, "api", "call", method.rawValue, json,
            ]
            process.environment = [
                "HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
            ]
            process.standardInput = FileHandle.nullDevice
            return try Self.output(of: process)
        }
    }

    private static func checkSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
            info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else {
            throw VoiceNotificationError(
                "Rex server socket is unavailable or not private to this user")
        }
    }

    static func output(
        of process: Process, timeout: Duration = .seconds(3),
        maximumOutput: Int = 2 * 1024 * 1024
    ) throws -> Data {
        guard timeout > .zero, maximumOutput >= 0 else {
            throw VoiceNotificationError("invalid Rex process limits")
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let outputDescriptor = output.fileHandleForReading.fileDescriptor
        let errorDescriptor = errors.fileHandleForReading.fileDescriptor
        var launched = false
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
            if launched {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }
        guard fcntl(outputDescriptor, F_SETFL, O_NONBLOCK) == 0,
            fcntl(errorDescriptor, F_SETFL, O_NONBLOCK) == 0
        else { throw VoiceNotificationError("cannot configure Rex output") }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do { try process.run() } catch {
            throw VoiceNotificationError(
                "could not start the Rex CLI: \(error.localizedDescription)")
        }
        launched = true
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        var bytes = Data()
        var diagnostics = Data()
        var remaining = maximumOutput
        var buffer = [UInt8](repeating: 0, count: 8192)
        var outputEnded = false
        var errorsEnded = false
        var descriptors = [
            pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: errorDescriptor, events: Int16(POLLIN), revents: 0),
        ]
        while ContinuousClock.now < deadline {
            if !outputEnded {
                outputEnded = try read(
                    outputDescriptor, into: &bytes, remaining: &remaining, buffer: &buffer)
            }
            if !errorsEnded {
                errorsEnded = try read(
                    errorDescriptor, into: &diagnostics, remaining: &remaining, buffer: &buffer)
            }
            if outputEnded && errorsEnded && !process.isRunning {
                guard process.terminationStatus == 0 else {
                    throw failure(
                        exitStatus: process.terminationStatus, output: bytes,
                        diagnostics: diagnostics)
                }
                return bytes
            }
            descriptors[0].fd = outputEnded ? -1 : outputDescriptor
            descriptors[1].fd = errorsEnded ? -1 : errorDescriptor
            _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, 2, 20) }
        }
        throw VoiceNotificationError("Rex request exceeded its time limit")
    }

    private static func read(
        _ descriptor: Int32, into bytes: inout Data, remaining: inout Int,
        buffer: inout [UInt8]
    ) throws -> Bool {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            guard count <= remaining else {
                throw VoiceNotificationError("Rex output exceeded its size limit")
            }
            remaining -= count
            bytes.append(contentsOf: buffer.prefix(count))
        } else if count < 0, errno != EINTR && errno != EAGAIN {
            throw VoiceNotificationError("could not read the Rex response")
        }
        return count == 0
    }

    private static func failure(exitStatus: Int32, output: Data, diagnostics: Data)
        -> VoiceNotificationError
    {
        let remoteControl = Data("Rex.app is not accepting actions".utf8)
        if output.range(of: remoteControl) != nil || diagnostics.range(of: remoteControl) != nil {
            return VoiceNotificationError(
                "enable Remote Control in Rex Settings → Rex Server, then try the notification again"
            )
        }
        return VoiceNotificationError("Rex request failed (exit status \(exitStatus))")
    }
}
