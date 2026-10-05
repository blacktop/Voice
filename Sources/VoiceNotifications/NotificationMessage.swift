import CryptoKit
import Foundation

public struct VoiceNotificationError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// Shared CLI context; constructing it never reads unrelated shell settings.
public struct NotificationContext: Sendable {
    public let pane: String?
    private let tmuxSocket: String?
    private let zedProject: String?
    private let push: Bool
    private let pushOverrides: NtfyOverrides?

    public init(
        pane: String?, noPane: Bool, tmuxSocket: String?, zedProject: String? = nil, push: Bool,
        environment: [String: String]
    ) throws {
        self.pane = try TmuxNotificationContext.pane(
            explicit: pane, disabled: noPane, environment: environment)
        self.tmuxSocket = TmuxNotificationContext.socket(
            explicit: tmuxSocket, environment: environment)
        self.zedProject = try zedProject.map { try ZedProjectTarget.resolve($0).path }
        self.push = push
        pushOverrides =
            push
            ? NtfyOverrides(
                server: environment["VOICE_NOTIFY_NTFY_SERVER"],
                topic: environment["VOICE_NOTIFY_NTFY_TOPIC"],
                token: environment["VOICE_NOTIFY_NTFY_TOKEN"]) : nil
    }

    public func message(title: String, subtitle: String?, message: String, group: String) throws
        -> NotificationMessage
    {
        let result = NotificationMessage(
            title: title, subtitle: subtitle, message: message, group: group,
            pane: pane, tmuxSocket: tmuxSocket, zedProject: zedProject,
            push: push, pushOverrides: pushOverrides)
        try result.validate()
        return result
    }
}

public struct NotificationMessage: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var message: String
    public var group: String
    public var pane: String?
    public var tmuxSocket: String?
    public var zedProject: String?
    public var push: Bool
    public var pushOverrides: NtfyOverrides?

    public init(
        title: String, subtitle: String? = nil, message: String, group: String,
        pane: String? = nil, tmuxSocket: String? = nil, zedProject: String? = nil,
        push: Bool = false,
        pushOverrides: NtfyOverrides? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.group = group
        self.pane = pane
        self.tmuxSocket = tmuxSocket
        self.zedProject = zedProject
        self.push = push
        self.pushOverrides = pushOverrides
    }

    public func validate() throws {
        try Self.check(title, name: "title", maximum: 512)
        try Self.check(message, name: "message", maximum: 8192)
        try Self.check(group, name: "group", maximum: 1024)
        if let subtitle { try Self.check(subtitle, name: "subtitle", maximum: 1024, empty: true) }
        if let pane, !Self.isPane(pane) {
            throw VoiceNotificationError("pane must be a tmux pane ID such as %3")
        }
        if let tmuxSocket {
            try Self.check(tmuxSocket, name: "tmux socket", maximum: 103)
            guard tmuxSocket.hasPrefix("/") else {
                throw VoiceNotificationError("tmux socket must be an absolute path")
            }
        }
        if let zedProject { try ZedProjectTarget.validatePath(zedProject) }
    }

    public var identifier: String {
        "voice-notify."
            + SHA256.hash(data: Data(group.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
    }

    public static func isPane(_ value: String) -> Bool {
        value.first == "%" && isDigits(String(value.dropFirst()))
    }

    static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func check(_ value: String, name: String, maximum: Int, empty: Bool = false) throws {
        guard empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= maximum, !value.utf8.contains(0)
        else {
            throw VoiceNotificationError(
                "\(name) must contain \(empty ? "0" : "1")–\(maximum) UTF-8 bytes")
        }
    }

    /// A preview never splits a Unicode scalar and remains small even for a
    /// multi-megabyte narration document.
    public static func preview(parts: some Sequence<String>) -> String {
        let maximum = 1024
        var bytes: [UInt8] = []
        var first = true
        for part in parts {
            if !first { bytes.append(contentsOf: [10, 10].prefix(maximum + 1 - bytes.count)) }
            first = false
            bytes.append(contentsOf: part.utf8.prefix(maximum + 1 - bytes.count))
            if bytes.count > maximum { break }
        }
        let truncated = bytes.count > maximum
        if truncated { bytes.removeLast(bytes.count - (maximum - 3)) }
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self) + (truncated ? "…" : "")
    }
}

public enum NotificationRPCRequest: Codable, Sendable {
    case post(NotificationMessage)
    // Older Voice versions reject this discriminator instead of silently
    // accepting a post while discarding its unknown project field.
    case postWithProject(NotificationMessage)
    case configurePush(NtfyConfiguration)
}

public struct NotificationRPCResponse: Codable, Sendable, Equatable {
    public var failures: [String]
    public var accepted: Bool { failures.isEmpty }
    public init(failures: [String] = []) { self.failures = failures }

    public func check() throws {
        guard accepted else {
            throw VoiceNotificationError(failures.joined(separator: "; "))
        }
    }
}

public enum NotificationDelivery {
    /// Always attempt each requested channel. In particular, a rejected push
    /// never retracts a notification already accepted by macOS.
    public static func perform(
        push: Bool,
        isolation: isolated (any Actor)? = #isolation,
        local: () async throws -> Void,
        remote: () async throws -> Void
    ) async -> NotificationRPCResponse {
        var failures: [String] = []
        do { try await local() } catch { failures.append("Mac: \(error.localizedDescription)") }
        if push {
            do { try await remote() } catch {
                failures.append("push: \(error.localizedDescription)")
            }
        }
        return NotificationRPCResponse(failures: failures)
    }
}
