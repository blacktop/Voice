import AppKit
import Foundation
import OSLog
import UserNotifications

@MainActor
public final class VoiceNotificationAppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    private var server: NotificationServer?
    private let center: UNUserNotificationCenter
    private let keychain = NtfyKeychain()
    private let logger = Logger(subsystem: "io.blacktop.Voice", category: "notifications")

    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        // Installed before applicationWillFinishLaunching, so a launch caused
        // by clicking an old notification cannot lose its response callback.
        center.delegate = self
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            server = try NotificationServer { [weak self] request in
                guard let self else {
                    return NotificationRPCResponse(failures: ["Voice is shutting down"])
                }
                return await self.handle(request)
            }
        } catch {
            let reason = error.localizedDescription
            logger.error(
                "Notification service failed to start: \(reason, privacy: .public)"
            )
        }
    }

    public func applicationWillTerminate(_ notification: Notification) { server = nil }

    private func handle(_ request: NotificationRPCRequest) async -> NotificationRPCResponse {
        switch request {
        case .configurePush(let configuration):
            do {
                try keychain.save(configuration)
                return NotificationRPCResponse()
            } catch { return NotificationRPCResponse(failures: [error.localizedDescription]) }
        case .post(let message):
            do { try message.validate() } catch {
                return NotificationRPCResponse(failures: [error.localizedDescription])
            }
            var click: TmuxNotificationTarget?
            var clickFailure: String?
            if let pane = message.pane {
                do {
                    click = try await TmuxNotification.capture(
                        pane: pane, socket: message.tmuxSocket)
                } catch { clickFailure = "tmux: \(error.localizedDescription)" }
            }
            let target = click
            var response = await NotificationDelivery.perform(push: message.push) {
                try await self.post(message, target: target)
            } remote: {
                let overrides = message.pushOverrides ?? NtfyOverrides()
                // Fully supplied overrides do not need to unlock/read Keychain.
                let stored =
                    overrides.server != nil && overrides.topic != nil && overrides.token != nil
                    ? nil : try self.keychain.load()
                try await NtfyPush.send(message, configuration: overrides.resolve(stored: stored))
            }
            if let clickFailure { response.failures.append(clickFailure) }
            return response
        }
    }

    private func post(_ message: NotificationMessage, target: TmuxNotificationTarget?) async throws
    {
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw VoiceNotificationError(
                "notifications are disabled; enable Voice in System Settings → Notifications")
        }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle ?? ""
        content.body = message.message
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = message.identifier
        if let target { content.userInfo = ["voice-tmux": try JSONEncoder().encode(target)] }
        try await center.add(
            UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil))
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) { completionHandler([.banner, .list, .sound]) }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let data = response.notification.request.content.userInfo["voice-tmux"] as? Data,
            data.count <= 4096,
            let target = try? JSONDecoder().decode(TmuxNotificationTarget.self, from: data)
        else { return }
        await TmuxNotification.activate(target)
    }
}
