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
    @Option(help: "Absolute local project directory to focus in Zed.", completion: .directory)
    var notifyZedProject: String?
    @Option(help: "Full notification Rex session ID (default: REX_SESSION).")
    var notifyRexSession: String?
    @Option(help: "Full notification Rex block ID (default: REX_BLOCK).")
    var notifyRexBlock: String?
    @Option(help: "Local Rex Unix socket (default: REX_SERVER).", completion: .file())
    var notifyRexServer: String?
    @Option(help: "Full local Rex client ID.") var notifyRexClient: String?
    @Flag(help: "Omit the notification's native Rex click target.") var notifyNoRex = false
    @Flag(help: "Also send the notification through ntfy.") var notifyPush = false

    mutating func validate() throws {
        try validate(environment: ProcessInfo.processInfo.environment)
    }

    func validate(environment: [String: String]) throws {
        if notifyPane != nil, notifyNoPane {
            throw ValidationError("choose --notify-pane or --notify-no-pane")
        }
        let explicitRex =
            notifyRexSession != nil || notifyRexBlock != nil
            || notifyRexServer != nil || notifyRexClient != nil
        if explicitRex, notifyNoRex {
            throw ValidationError("choose a Rex target or --notify-no-rex")
        }
        if explicitRex, notifyPane != nil || notifyTmuxSocket != nil || notifyZedProject != nil {
            throw ValidationError(
                "choose a Rex target or the --notify-pane/--notify-zed-project target")
        }
        if !notify,
            notifyTitle != nil || notifySubtitle != nil || notifyMessage != nil
                || notifyGroup != nil || notifyPane != nil || notifyNoPane
                || notifyTmuxSocket != nil || notifyZedProject != nil || notifyPush
                || notifyRexSession != nil || notifyRexBlock != nil || notifyRexServer != nil
                || notifyRexClient != nil || notifyNoRex
        {
            throw ValidationError("notification options require --notify")
        }
        do {
            _ = try message(previewParts: ["preview"], environment: environment)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    func message(previewParts: some Collection<String>, environment: [String: String]) throws
        -> NotificationMessage?
    {
        guard notify else { return nil }
        let context = try NotificationContext(
            pane: notifyPane, noPane: notifyNoPane, tmuxSocket: notifyTmuxSocket,
            zedProject: notifyZedProject, rexSession: notifyRexSession, rexBlock: notifyRexBlock,
            rexServer: notifyRexServer, rexClient: notifyRexClient, noRex: notifyNoRex,
            push: notifyPush, environment: environment)
        let preview = notifyMessage ?? NotificationMessage.preview(parts: previewParts)
        let details = try NotificationDetails.encodeIfFits(parts: previewParts)
        return try context.message(
            title: notifyTitle ?? "Voice", subtitle: notifySubtitle,
            message: preview,
            group: notifyGroup ?? "voice-say:\(context.pane ?? context.rex?.block ?? "global")",
            details: details)
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
