import ArgumentParser
import Darwin
import Foundation
import VoiceNotifications

struct VoiceNotify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-notify", abstract: "Post a native Voice notification.",
        discussion:
            "Posting is the default command. Use 'voice-notify post --help' for delivery options.",
        version: "0.1.0", subcommands: [PostNotification.self, ConfigurePush.self],
        defaultSubcommand: PostNotification.self)

}

struct PostNotification: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post", abstract: "Post an alert with optional click targets or phone push."
    )

    @Option(help: "Notification title.") var title: String
    @Option(help: "Optional line beneath the title.") var subtitle: String?
    @Option(help: "Notification body.") var message: String
    @Option(help: "Stable replacement group.") var group: String
    @Option(help: "tmux pane ID; defaults to TMUX_PANE.") var pane: String?
    @Flag(help: "Do not attach a tmux click target.") var noPane = false
    @Option(help: "Explicit tmux server socket.", completion: .file()) var tmuxSocket: String?
    @Option(
        help: "Absolute local project directory to open or focus in Zed.", completion: .directory)
    var zedProject: String?
    @Flag(help: "Also publish through the configured ntfy server.") var push = false

    mutating func validate() throws {
        do { _ = try makeMessage(environment: ProcessInfo.processInfo.environment) } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    func makeMessage(environment: [String: String]) throws -> NotificationMessage {
        try NotificationContext(
            pane: pane, noPane: noPane, tmuxSocket: tmuxSocket, zedProject: zedProject, push: push,
            environment: environment
        ).message(title: title, subtitle: subtitle, message: message, group: group)
    }

    func run() async throws {
        let message = try makeMessage(environment: ProcessInfo.processInfo.environment)
        try await NotificationClient.send(.post(message)).check()
    }
}

struct ConfigurePush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure-push",
        abstract: "Save ntfy credentials in Voice's device-bound Keychain.")

    @Option(help: "HTTPS ntfy server URL.") var server: String
    @Option(help: "Private authenticated topic.") var topic: String
    @Flag(help: "Read one token line from stdin instead of a hidden terminal prompt.")
    var tokenStdin = false

    mutating func validate() throws {
        do {
            try NtfyConfiguration(server: server, topic: topic, token: "validation").validate()
        } catch { throw ValidationError(error.localizedDescription) }
    }

    func run() async throws {
        let token = try await NotificationTokenInput.read(stdin: tokenStdin)
        let configuration = NtfyConfiguration(server: server, topic: topic, token: token)
        try configuration.validate()
        try await NotificationClient.send(.configurePush(configuration)).check()
    }
}

enum NotificationTokenInput {
    // readpassphrase must receive terminal signals on the thread blocked in
    // read(), so libc can restore echo before propagating Ctrl-C.
    @MainActor
    static func read(stdin: Bool) throws -> String {
        try stdin ? readStdin() : readHidden()
    }

    @MainActor
    private static func readHidden() throws -> String {
        // One extra input byte lets us reject truncation.
        var buffer = [CChar](repeating: 0, count: 4098)
        defer {
            _ = buffer.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        guard readpassphrase("ntfy token: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
            let reason = String(cString: strerror(errno))
            throw VoiceNotificationError(
                "could not read hidden token (\(reason)); "
                    + "use --token-stdin without a terminal")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard bytes.count <= 4096, let token = String(bytes: bytes, encoding: .utf8) else {
            throw VoiceNotificationError("ntfy token is too long or is not UTF-8")
        }
        return token
    }

    private static func readStdin() throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var bytes: [UInt8] = []
        while bytes.count <= 4096, ContinuousClock.now < deadline {
            switch try nextByte() {
            case .retry: continue
            case .end, .byte(10): return try decodeLine(bytes)
            case .byte(let byte):
                bytes.append(byte)
            }
        }
        throw VoiceNotificationError("ntfy token input exceeded its size or time limit")
    }

    private enum InputByte {
        case byte(UInt8)
        case end
        case retry
    }

    private static func nextByte() throws -> InputByte {
        guard try inputIsReady() else { return .retry }
        var byte: UInt8 = 0
        switch Darwin.read(STDIN_FILENO, &byte, 1) {
        case 0: return .end
        case 1: return .byte(byte)
        default:
            guard errno == EINTR || errno == EAGAIN else {
                throw VoiceNotificationError("could not read ntfy token")
            }
            return .retry
        }
    }

    private static func inputIsReady() throws -> Bool {
        var item = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, 100)
        if ready < 0, errno == EINTR { return false }
        guard ready >= 0 else { throw VoiceNotificationError("could not read ntfy token") }
        return ready > 0
    }

    private static func decodeLine(_ input: [UInt8]) throws -> String {
        let bytes = input.last == 13 ? input.dropLast() : input[...]
        guard let token = String(bytes: bytes, encoding: .utf8) else {
            throw VoiceNotificationError("ntfy token is not UTF-8")
        }
        return token
    }
}
