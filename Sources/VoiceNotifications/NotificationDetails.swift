import Foundation
import Observation

/// Full local text, distinct from the short banner and optional phone payload.
public struct NotificationDetails: Equatable, Sendable {
    public static let maximumTextBytes = 8 * 1024 * 1024
    static let categoryIdentifier = "voice-notify.message"
    static let actionIdentifier = "voice-notify.details"
    static let userInfoKey = "voice-details"

    public let title: String
    public let subtitle: String
    public let text: String
    let clickTarget: NotificationClickTarget?

    public var destination: NotificationDestination? {
        if clickTarget?.zedProject != nil { return .zed }
        if clickTarget?.tmux != nil { return .terminal }
        return nil
    }

    public init(title: String, subtitle: String, text: String) {
        self.init(title: title, subtitle: subtitle, text: text, clickTarget: nil)
    }

    init(title: String, subtitle: String, text: String, clickTarget: NotificationClickTarget?) {
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.clickTarget = clickTarget
    }

    /// Keep all narration blocks, rejecting excessive input instead of silently
    /// discarding the end. Data has predictable base64 overhead in JSON RPC.
    public static func encode(parts: some Sequence<String>) throws -> Data {
        guard let data = try encodeIfFits(parts: parts) else {
            throw VoiceNotificationError("notification details exceed the 8 MiB limit")
        }
        return data
    }

    /// Oversized details are optional; callers can retain their short preview.
    public static func encodeIfFits(parts: some Sequence<String>) throws -> Data? {
        var data = Data()
        var first = true
        for part in parts {
            let separator = first ? 0 : 2
            guard part.utf8.count <= maximumTextBytes - data.count - separator else {
                return nil
            }
            if separator != 0 { data.append(contentsOf: [10, 10]) }
            data.append(contentsOf: part.utf8)
            first = false
        }
        guard !data.isEmpty, !data.contains(0) else {
            throw VoiceNotificationError("notification details are invalid or exceed 8 MiB")
        }
        return data
    }

    static func text(from data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumTextBytes,
            let text = String(data: data, encoding: .utf8), !data.contains(0)
        else { throw VoiceNotificationError("notification details are invalid or exceed 8 MiB") }
        return text
    }
}

public enum NotificationDestination: Equatable, Sendable {
    case zed
    case terminal
}

public enum NotificationReplayVoice: Equatable, Sendable {
    case system
    case appleSpeech
    case selected
}

public enum NotificationReplayPhase: Equatable, Sendable {
    case idle
    case preparing
    case speaking
}

/// Owns replay cancellation independently of the window and notification API.
@MainActor
@Observable
public final class NotificationDetailsPresentation {
    public typealias Speak =
        @MainActor @Sendable (
            String, NotificationReplayVoice, @escaping @Sendable () -> Void
        ) async throws -> Void
    typealias OpenDestination = @MainActor @Sendable (NotificationClickTarget) async throws -> Void

    public private(set) var details: NotificationDetails?
    public private(set) var contentID = UUID()
    public private(set) var phase: NotificationReplayPhase = .idle
    public private(set) var playbackVoice: NotificationReplayVoice = .system
    public private(set) var error: String?
    public private(set) var isOpeningDestination = false
    public private(set) var destinationError: String?
    public let defaultVoice: NotificationReplayVoice
    public var isActive: Bool { phase != .idle }
    @ObservationIgnored
    private var operation: Task<Void, Never>?
    @ObservationIgnored
    private var generation = UUID()
    @ObservationIgnored
    private var destinationOperation: Task<Void, Never>?
    private let speak: Speak
    private let openDestination: OpenDestination

    public convenience init(
        defaultVoice: NotificationReplayVoice = .system, speak: @escaping Speak
    ) {
        self.init(
            defaultVoice: defaultVoice, openDestination: { try await $0.activate() }, speak: speak)
    }

    init(
        defaultVoice: NotificationReplayVoice = .system,
        openDestination: @escaping OpenDestination, speak: @escaping Speak
    ) {
        self.defaultVoice = defaultVoice
        self.openDestination = openDestination
        self.speak = speak
    }

    public func show(_ details: NotificationDetails) {
        stop()
        cancelDestination()
        contentID = UUID()
        self.details = details
        error = nil
    }

    public func goToDestination() {
        guard !isOpeningDestination, let details, details.destination != nil,
            let target = details.clickTarget
        else { return }
        let previous = destinationOperation
        let contentID = contentID
        isOpeningDestination = true
        destinationError = nil
        destinationOperation = Task { [weak self, openDestination] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await openDestination(target)
            } catch {
                if self?.contentID == contentID, !Task.isCancelled {
                    self?.destinationError = error.localizedDescription
                }
            }
            guard self?.contentID == contentID else { return }
            self?.isOpeningDestination = false
            self?.destinationOperation = nil
        }
    }

    private func cancelDestination() {
        destinationOperation?.cancel()
        isOpeningDestination = false
        destinationError = nil
    }

    public func startSpeaking(using voice: NotificationReplayVoice? = nil) {
        guard let details else { return }
        let voice = voice ?? defaultVoice
        let previous = operation
        previous?.cancel()
        let generation = UUID()
        self.generation = generation
        playbackVoice = voice
        phase = .preparing
        error = nil
        operation = Task { [weak self, speak] in
            // The previous engine must finish cancellation before a new replay
            // starts, or its delayed stop could silence the new utterance.
            await previous?.value
            do {
                try Task.checkCancellation()
                try await speak(details.text, voice) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard self?.generation == generation, self?.phase == .preparing else {
                            return
                        }
                        self?.phase = .speaking
                    }
                }
            } catch is CancellationError {
                if self?.generation == generation {
                    self?.error = "Playback was interrupted. Press Speak to try again."
                }
            } catch {
                if self?.generation == generation { self?.error = error.localizedDescription }
            }
            guard self?.generation == generation else { return }
            self?.phase = .idle
            self?.operation = nil
        }
    }

    public func stop() {
        generation = UUID()
        operation?.cancel()
        phase = .idle
    }

    public func close() {
        stop()
        cancelDestination()
        contentID = UUID()
        details = nil
        error = nil
    }
}
