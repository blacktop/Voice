import AppKit
import Darwin
import Foundation

struct ZedProjectTarget: Codable, Sendable, Equatable {
    let path: String

    static func validatePath(_ path: String) throws {
        try NotificationMessage.check(path, name: "Zed project", maximum: 1023)
        guard path.hasPrefix("/") else {
            throw VoiceNotificationError("Zed project must be an absolute local directory")
        }
    }

    static func resolve(_ path: String) throws -> Self {
        try validatePath(path)
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        try validatePath(url.path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        } catch {
            throw VoiceNotificationError(
                "could not inspect Zed project \(url.path): \(error.localizedDescription)")
        }
        guard values.isDirectory == true, values.volumeIsLocal == true else {
            throw VoiceNotificationError("Zed project must be an existing local directory")
        }
        return Self(path: url.path)
    }

    func revalidate() throws {
        guard try Self.resolve(path) == self else {
            throw VoiceNotificationError("Zed project directory changed since the notification")
        }
    }
}

struct NotificationClickTarget: Codable, Sendable, Equatable {
    var tmux: TmuxNotificationTarget?
    var zedProject: ZedProjectTarget?

    static func decode(_ userInfo: [AnyHashable: Any]) -> Self? {
        if let data = userInfo["voice-click"] as? Data {
            guard data.count <= 8192 else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        guard let data = userInfo["voice-tmux"] as? Data, data.count <= 4096,
            let tmux = try? JSONDecoder().decode(TmuxNotificationTarget.self, from: data)
        else { return nil }
        return Self(tmux: tmux)
    }

    @MainActor
    func activate(
        selectTmux: (TmuxNotificationTarget) async -> TmuxProcessIdentity?,
        openZed: (ZedProjectTarget) async throws -> Void,
        raiseHost: (TmuxProcessIdentity) -> Void
    ) async throws {
        var client: TmuxProcessIdentity?
        if let tmux { client = await selectTmux(tmux) }
        if let zedProject {
            do {
                try await openZed(zedProject)
                return
            } catch {
                if let client { raiseHost(client) }
                throw error
            }
        }
        if let client { raiseHost(client) }
    }
}

enum ZedNotification {
    private static let bundleIdentifiers = [
        "dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly", "dev.zed.Zed-Dev",
    ]

    @MainActor
    static func activate(_ target: ZedProjectTarget) async throws {
        try await BlockingCall.run { try target.revalidate() }
        let running = bundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { !$0.isTerminated }
        let app = try application(
            runningAppURLs: running.map(\.bundleURL),
            installedAppURL: URL(fileURLWithPath: "/Applications/Zed.app", isDirectory: true),
            registeredAppURL: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            })
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: app.identifier)
        try await run(
            process(appURL: app.url, arguments: arguments(appURL: app.url, target: target)))
    }

    static func arguments(appURL: URL, target: ZedProjectTarget) -> [String] {
        ["--zed", appURL.path, "--existing", "--", target.path]
    }

    @MainActor
    static func application(
        runningAppURLs: [URL?], installedAppURL: URL, registeredAppURL: (String) -> URL?
    ) throws -> (url: URL, identifier: String) {
        let candidate =
            (runningAppURLs.first ?? nil)
            ?? (Bundle(url: installedAppURL)?.bundleIdentifier == "dev.zed.Zed"
                ? installedAppURL : nil)
            ?? bundleIdentifiers.compactMap { identifier -> URL? in
                guard let url = registeredAppURL(identifier),
                    Bundle(url: url)?.bundleIdentifier == identifier
                else { return nil }
                return url
            }.first
        guard let candidate, let identifier = Bundle(url: candidate)?.bundleIdentifier,
            bundleIdentifiers.contains(identifier)
        else {
            throw VoiceNotificationError("Zed is not installed")
        }
        let url = candidate.resolvingSymlinksInPath().standardizedFileURL
        try NotificationClient.checkLaunch(
            appURL: url, runningAppURLs: runningAppURLs, applicationName: "Zed")
        return (url, identifier)
    }

    private static func process(appURL: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = appURL.appendingPathComponent("Contents/MacOS/cli")
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    static func run(_ process: Process, timeout: Duration = .seconds(10)) async throws {
        try Task.checkCancellation()
        let (exits, continuation) = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        defer {
            if process.isRunning {
                process.terminate()
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            process.terminationHandler = nil
            continuation.finish()
        }
        do { try await BlockingCall.run { try process.run() } } catch {
            let failure = error as NSError
            throw VoiceNotificationError(
                "could not start Zed's bundled CLI: \(failure.localizedDescription) "
                    + "(\(failure.domain) \(failure.code))")
        }
        let status = try await terminationStatus(exits, timeout: timeout)
        guard status == 0 else {
            throw VoiceNotificationError("Zed could not open the project (exit status \(status))")
        }
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
                throw VoiceNotificationError("Zed did not accept the project within \(timeout)")
            }
            defer { group.cancelAll() }
            guard let status = try await group.next() else { throw CancellationError() }
            return status
        }
    }
}
