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
    private var detailsHandler: @MainActor @Sendable (NotificationDetails) -> Void = { _ in }

    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        // Installed before applicationWillFinishLaunching, so a launch caused
        // by clicking an old notification cannot lose its response callback.
        center.delegate = self
        center.setNotificationCategories([Self.messageCategory()])
    }

    static func messageCategory() -> UNNotificationCategory {
        let details = UNNotificationAction(
            identifier: NotificationDetails.actionIdentifier, title: "Details…",
            options: [.foreground])
        return UNNotificationCategory(
            identifier: NotificationDetails.categoryIdentifier, actions: [details],
            intentIdentifiers: [], options: [])
    }

    public func setDetailsHandler(
        _ handler: @escaping @MainActor @Sendable (NotificationDetails) -> Void
    ) {
        detailsHandler = handler
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
        case .post(let message), .postWithProject(let message), .postWithDetails(let message),
            .postWithRex(let message):
            do { try message.validate() } catch {
                return NotificationRPCResponse(failures: [error.localizedDescription])
            }
            var click = NotificationClickTarget()
            var clickFailures: [String] = []
            if let rex = message.rex {
                do { click.rex = try await RexNotification.capture(rex) } catch {
                    clickFailures.append("Rex: \(error.localizedDescription)")
                }
            }
            if let pane = message.pane {
                do {
                    click.tmux = try await TmuxNotification.capture(
                        pane: pane, socket: message.tmuxSocket)
                } catch { clickFailures.append("tmux: \(error.localizedDescription)") }
            }
            if let project = message.zedProject {
                do {
                    click.zedProject = try await BlockingCall.run {
                        try ZedProjectTarget.resolve(project)
                    }
                } catch { clickFailures.append("Zed: \(error.localizedDescription)") }
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
            response.failures.append(contentsOf: clickFailures)
            return response
        }
    }

    private func post(_ message: NotificationMessage, target: NotificationClickTarget) async throws
    {
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw VoiceNotificationError(
                "notifications are disabled; enable Voice in System Settings → Notifications")
        }
        let content = try Self.content(for: message, target: target)
        try await center.add(
            UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil))
    }

    static func content(
        for message: NotificationMessage, target: NotificationClickTarget
    ) throws -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle ?? ""
        content.body = message.message
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = message.identifier
        content.categoryIdentifier = NotificationDetails.categoryIdentifier
        content.userInfo = [
            "voice-click": try JSONEncoder().encode(target),
            NotificationDetails.userInfoKey: message.details ?? Data(message.message.utf8),
        ]
        return content
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) { completionHandler([.banner, .list, .sound]) }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == NotificationDetails.actionIdentifier {
            let content = response.notification.request.content
            do {
                await detailsHandler(try Self.details(for: content))
            } catch {
                await reportClickFailure(
                    error.localizedDescription, subtitle: "Could not open notification",
                    identifier: response.notification.request.identifier)
            }
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let target = NotificationClickTarget.decode(
                response.notification.request.content.userInfo)
        else { return }
        await activate(target, identifier: response.notification.request.identifier)
    }

    nonisolated static func details(for content: UNNotificationContent) throws
        -> NotificationDetails
    {
        guard let data = content.userInfo[NotificationDetails.userInfoKey] as? Data else {
            throw VoiceNotificationError("the full notification text is unavailable")
        }
        return NotificationDetails(
            title: content.title, subtitle: content.subtitle,
            text: try NotificationDetails.text(from: data),
            clickTarget: NotificationClickTarget.decode(content.userInfo))
    }

    private func activate(_ target: NotificationClickTarget, identifier: String) async {
        do {
            try await target.activate()
        } catch {
            await reportClickFailure(
                error.localizedDescription,
                subtitle: target.rex == nil ? "Could not focus Zed" : "Could not focus Rex",
                identifier: identifier)
        }
    }

    private func reportClickFailure(_ reason: String, subtitle: String, identifier: String) async {
        logger.error("Notification click failed: \(reason)")
        let content = UNMutableNotificationContent()
        content.title = "Voice"
        content.subtitle = subtitle
        content.body = reason
        content.interruptionLevel = .active
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: identifier + ".click-error", content: content, trigger: nil))
        } catch {
            logger.error("Could not post notification click failure: \(error.localizedDescription)")
        }
    }
}
