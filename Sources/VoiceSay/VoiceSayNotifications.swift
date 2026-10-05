import ArgumentParser
import Foundation
import VoiceMLX
import VoiceNotifications

struct VoiceSayNotificationOptions: ParsableArguments {
    @Flag(help: "Post a native notification when this invocation acquires the speech lock.")
    var notify = false
    @Option(help: "Notification title (default: Voice).") var notifyTitle: String?
    @Option(help: "Notification subtitle.") var notifySubtitle: String?
    @Option(help: "Notification body (default: a bounded preview of the speech).")
    var notifyMessage: String?
    @Option(help: "Notification replacement group (default: voice-say and the pane ID).")
    var notifyGroup: String?
    @Option(help: "Notification tmux pane (default: TMUX_PANE).") var notifyPane: String?
    @Flag(help: "Omit the notification's tmux click target.") var notifyNoPane = false
    @Option(help: "Notification tmux socket.", completion: .file()) var notifyTmuxSocket: String?
    @Flag(help: "Also send the notification through ntfy.") var notifyPush = false

    mutating func validate() throws {
        try validate(environment: ProcessInfo.processInfo.environment)
    }

    func validate(environment: [String: String]) throws {
        if notifyPane != nil, notifyNoPane {
            throw ValidationError("choose --notify-pane or --notify-no-pane")
        }
        if !notify,
            notifyTitle != nil || notifySubtitle != nil || notifyMessage != nil
                || notifyGroup != nil || notifyPane != nil || notifyNoPane
                || notifyTmuxSocket != nil || notifyPush
        {
            throw ValidationError("notification options require --notify")
        }
        do {
            _ = try message(previewParts: ["preview"], environment: environment)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    func message(previewParts: some Sequence<String>, environment: [String: String]) throws
        -> NotificationMessage?
    {
        guard notify else { return nil }
        let context = try NotificationContext(
            pane: notifyPane, noPane: notifyNoPane, tmuxSocket: notifyTmuxSocket,
            push: notifyPush, environment: environment)
        return try context.message(
            title: notifyTitle ?? "Voice", subtitle: notifySubtitle,
            message: notifyMessage ?? NotificationMessage.preview(parts: previewParts),
            group: notifyGroup ?? "voice-say:\(context.pane ?? "global")")
    }
}

enum VoiceSayNotificationFlow {
    static func run(
        message: NotificationMessage?, at lockURL: URL = SpeechLock.defaultURL,
        whenBusy: SpeechLock.Contention, onContended: () -> Void = {},
        report: (String) -> Void,
        post: @escaping @Sendable (NotificationMessage) async throws -> NotificationRPCResponse,
        speak: () async throws -> Void
    ) async throws {
        var delivery: Task<NotificationRPCResponse, any Error>?
        var speechFailure: (any Error)?
        do {
            try await SpeechLock.withLock(at: lockURL, whenBusy: whenBusy, onContended: onContended)
            {
                if let message { delivery = Task { try await post(message) } }
                try await speak()
            }
        } catch { speechFailure = error }

        // The result is still observed, but network delivery cannot delay speech
        // or retain the speech lock after playback finishes.
        var deliveryFailure: VoiceNotificationError?
        if let delivery {
            do { try await delivery.value.check() } catch {
                let failure = VoiceNotificationError(
                    "notification failed: \(error.localizedDescription)")
                report(failure.localizedDescription)
                deliveryFailure = failure
            }
        }
        if let speechFailure { throw speechFailure }
        if let deliveryFailure { throw deliveryFailure }
    }
}
