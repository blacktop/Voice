import AppKit
import Darwin
import Foundation

struct TmuxProcessIdentity: Codable, Sendable, Equatable {
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64

    static func read(_ pid: Int32) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_uid == getuid()
        else { return nil }
        return Self(
            pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

struct TmuxNotificationTarget: Codable, Sendable, Equatable {
    var pane: String
    var socket: String
    var server: TmuxProcessIdentity
}

struct TmuxClient: Sendable, Equatable {
    var pid: Int32
    var activity: UInt64
    var session: String
}

struct TmuxClickPlan: Sendable, Equatable {
    var clientPID: Int32?
    var commands: [[String]]

    static func make(pane: String, currentSession: String?, clients: [TmuxClient]) -> Self {
        guard NotificationMessage.isPane(pane) else { return Self(clientPID: nil, commands: []) }
        let ordered = clients.sorted {
            $0.activity == $1.activity ? $0.pid > $1.pid : $0.activity > $1.activity
        }
        if let currentSession, let client = ordered.first(where: { $0.session == currentSession }) {
            return Self(
                clientPID: client.pid,
                commands: [["select-window", "-t", pane], ["select-pane", "-t", pane]])
        }
        return Self(clientPID: ordered.first?.pid, commands: [])
    }
}

public enum TmuxNotificationContext {
    public static func pane(explicit: String?, disabled: Bool, environment: [String: String]) throws
        -> String?
    {
        if disabled, explicit != nil { throw VoiceNotificationError("choose --pane or --no-pane") }
        let pane = disabled ? nil : explicit ?? environment["TMUX_PANE"]
        if let pane, !NotificationMessage.isPane(pane) {
            throw VoiceNotificationError("pane must be a tmux pane ID such as %3")
        }
        return pane
    }

    public static func socket(explicit: String?, environment: [String: String]) -> String? {
        if let explicit { return explicit }
        guard let tmux = environment["TMUX"] else { return nil }
        let components = tmux.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return nil }
        return components.dropLast(2).joined(separator: ",")
    }
}

enum TmuxNotification {
    private static let executableCandidates = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
    ]

    static func run(_ arguments: [String], socket: String?) throws -> String {
        let (process, output) = try start(arguments, socket: socket)
        defer {
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        return try readOutput(process: process, output: output)
    }

    private static func start(_ arguments: [String], socket: String?) throws -> (Process, Pipe) {
        guard
            let executable = executableCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw VoiceNotificationError("tmux is not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-N"] + (socket.map { ["-S", $0] } ?? []) + arguments
        process.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw VoiceNotificationError("cannot configure tmux output")
        }
        do { try process.run() } catch { throw VoiceNotificationError("cannot start tmux") }
        try? output.fileHandleForWriting.close()
        return (process, output)
    }

    private static func readOutput(process: Process, output: Pipe) throws -> String {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            let endOfFile = try readAvailable(descriptor, into: &bytes, buffer: &buffer)
            if endOfFile, !process.isRunning {
                return try completedOutput(process: process, bytes: bytes)
            }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&item, 1, 20)
        }
        throw VoiceNotificationError("tmux command exceeded its time or output limit")
    }

    private static func readAvailable(
        _ descriptor: Int32, into bytes: inout Data,
        buffer: inout [UInt8]
    ) throws -> Bool {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            guard count <= 65_536 - bytes.count else {
                throw VoiceNotificationError("tmux command exceeded its time or output limit")
            }
            bytes.append(contentsOf: buffer.prefix(count))
        } else if count < 0, errno != EINTR && errno != EAGAIN {
            throw VoiceNotificationError("tmux command exceeded its time or output limit")
        }
        return count == 0
    }

    private static func completedOutput(process: Process, bytes: Data) throws -> String {
        guard process.terminationStatus == 0,
            let result = String(data: bytes, encoding: .utf8)
        else { throw VoiceNotificationError("tmux target is unavailable") }
        return result.trimmingCharacters(in: .newlines)
    }

    static func capture(pane: String, socket: String?) async throws -> TmuxNotificationTarget {
        try await BlockingCall.run { try resolveTarget(pane: pane, socket: socket) }
    }

    private static func resolveTarget(pane: String, socket: String?) throws
        -> TmuxNotificationTarget
    {
        guard NotificationMessage.isPane(pane) else {
            throw VoiceNotificationError("invalid tmux pane")
        }
        let output = try run(
            ["display-message", "-p", "-t", pane, "#{pid}\t#{socket_path}\t#{pane_id}"],
            socket: socket)
        let fields = output.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2] == pane, let pid = Int32(fields[0]),
            let identity = TmuxProcessIdentity.read(pid)
        else { throw VoiceNotificationError("could not identify the tmux server") }
        let path = String(fields[1])
        try NotificationMessage(title: "x", message: "x", group: "x", pane: pane, tmuxSocket: path)
            .validate()
        return TmuxNotificationTarget(pane: pane, socket: path, server: identity)
    }

    static func clients(socket: String) throws -> [TmuxClient] {
        let output = try run(
            ["list-clients", "-F", "#{client_pid}\t#{client_activity}\t#{session_id}"],
            socket: socket)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 1,
                let activity = UInt64(fields[1]), fields[2].first == "$",
                NotificationMessage.isDigits(String(fields[2].dropFirst()))
            else { return nil }
            return TmuxClient(pid: pid, activity: activity, session: String(fields[2]))
        }
    }

    private static func serverMatches(_ target: TmuxNotificationTarget) -> Bool {
        guard TmuxProcessIdentity.read(target.server.pid) == target.server,
            let value = try? run(["display-message", "-p", "#{pid}"], socket: target.socket),
            let pid = Int32(value)
        else { return false }
        return TmuxProcessIdentity.read(pid) == target.server
    }

    static func select(_ target: TmuxNotificationTarget) async -> TmuxProcessIdentity? {
        let clientPID = try? await BlockingCall.run { selectPane(target) }
        return clientPID.flatMap(TmuxProcessIdentity.read)
    }

    /// Selects the pane and returns the tmux client whose host app to raise,
    /// or nil when the target no longer belongs to the same tmux server.
    private static func selectPane(_ target: TmuxNotificationTarget) -> Int32? {
        guard NotificationMessage.isPane(target.pane), target.socket.hasPrefix("/"),
            target.socket.utf8.count <= 103, !target.socket.utf8.contains(0),
            serverMatches(target)
        else { return nil }
        // Re-resolve the pane: it may have moved to another window/session
        // after the notification was posted.
        guard let clients = try? clients(socket: target.socket) else { return nil }
        let session = try? run(
            ["display-message", "-p", "-t", target.pane, "#{session_id}"], socket: target.socket)
        let plan = TmuxClickPlan.make(pane: target.pane, currentSession: session, clients: clients)
        guard serverMatches(target) else { return nil }
        for command in plan.commands {
            guard serverMatches(target),
                (try? run(command, socket: target.socket)) != nil
            else { return nil }
        }
        return plan.clientPID
    }

    @MainActor
    static func raiseHost(of client: TmuxProcessIdentity) {
        guard TmuxProcessIdentity.read(client.pid) == client else { return }
        var pid = client.pid
        var seen = Set<Int32>()
        for _ in 0..<64 {
            guard pid > 1, seen.insert(pid).inserted else { return }
            if let application = NSRunningApplication(processIdentifier: pid),
                application.bundleURL != nil
            {
                NSApp.yieldActivation(to: application)
                application.activate(options: [])
                return
            }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                info.pbi_uid == getuid()
            else { return }
            pid = Int32(exactly: info.pbi_ppid) ?? 0
        }
    }
}
