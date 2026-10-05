import Foundation
import XCTest

@testable import VoiceNotifications

final class ZedNotificationTests: XCTestCase {
    func testProjectPathsAreCanonicalLocalDirectories() throws {
        try withDirectory { root in
            let first = root.appendingPathComponent("first/dotfiles", isDirectory: true)
            let second = root.appendingPathComponent("second/dotfiles", isDirectory: true)
            let alias = root.appendingPathComponent("alias")
            let file = root.appendingPathComponent("plain-file")
            try Data().write(to: file)
            for directory in [first, second] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            let target = try ZedProjectTarget.resolve(alias.path)
            XCTAssertEqual(target, try ZedProjectTarget.resolve(first.path))
            XCTAssertNotEqual(target, try ZedProjectTarget.resolve(second.path))
            for invalid in [
                "relative/path", "file:///tmp", file.path,
                root.appendingPathComponent("missing").path,
                first.path + "\0", "/" + String(repeating: "x", count: 1023),
            ] {
                XCTAssertThrowsError(try ZedProjectTarget.resolve(invalid), invalid)
            }
            try FileManager.default.removeItem(at: first)
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
            XCTAssertThrowsError(try target.revalidate())
        }
    }

    func testClickPayloadSupportsLegacyAndCombinedTargets() throws {
        let tmux = TmuxNotificationTarget(
            pane: "%3", socket: "/tmp/tmux-test",
            server: TmuxProcessIdentity(pid: 123, startSeconds: 456, startMicroseconds: 789))
        let combined = NotificationClickTarget(
            tmux: tmux, zedProject: ZedProjectTarget(path: "/tmp/project"))
        XCTAssertEqual(
            NotificationClickTarget.decode(["voice-click": try JSONEncoder().encode(combined)]),
            combined)
        XCTAssertEqual(
            NotificationClickTarget.decode(["voice-tmux": try JSONEncoder().encode(tmux)]),
            NotificationClickTarget(tmux: tmux))
        XCTAssertNil(
            NotificationClickTarget.decode(["voice-click": Data(repeating: 0, count: 8193)]))
        XCTAssertNil(
            NotificationClickTarget.decode([
                "voice-click": Data("invalid".utf8), "voice-tmux": try JSONEncoder().encode(tmux),
            ]))
        let oldMessage = Data(
            #"{"title":"Build","message":"Passed","group":"build","push":false}"#.utf8)
        XCTAssertNil(
            try JSONDecoder().decode(NotificationMessage.self, from: oldMessage).zedProject)
    }

    @MainActor
    func testZedSelectionUsesFullPathsAndRejectsConflictingInstallations() throws {
        try withDirectory { root in
            let stable = try app("Zed", identifier: "dev.zed.Zed", in: root)
            let preview = try app("Zed Preview", identifier: "dev.zed.Zed-Preview", in: root)
            let absent = root.appendingPathComponent("missing.app")
            func registered(_ identifier: String) -> URL? {
                switch identifier {
                case "dev.zed.Zed": return absent
                case "dev.zed.Zed-Preview": return preview
                default: return nil
                }
            }
            XCTAssertEqual(
                try ZedNotification.application(
                    runningAppURLs: [], installedAppURL: absent, registeredAppURL: registered
                ).url, preview)
            XCTAssertEqual(
                try ZedNotification.application(
                    runningAppURLs: [], installedAppURL: stable, registeredAppURL: registered
                ).url, stable)
            XCTAssertEqual(
                try ZedNotification.application(
                    runningAppURLs: [preview], installedAppURL: stable,
                    registeredAppURL: registered
                ).identifier, "dev.zed.Zed-Preview")
            XCTAssertThrowsError(
                try ZedNotification.application(
                    runningAppURLs: [stable, preview], installedAppURL: stable,
                    registeredAppURL: registered)
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains(preview.path))
            }
            XCTAssertThrowsError(
                try ZedNotification.application(
                    runningAppURLs: [nil], installedAppURL: stable,
                    registeredAppURL: registered))
            XCTAssertThrowsError(
                try ZedNotification.application(
                    runningAppURLs: [], installedAppURL: absent, registeredAppURL: { _ in nil }))
        }
        let app = URL(fileURLWithPath: "/Applications/Zed.app")
        for path in ["/tmp/first/dotfiles", "/tmp/second/dotfiles", "/tmp/quoted ' project:12"] {
            let project = ZedProjectTarget(path: path)
            XCTAssertEqual(
                ZedNotification.arguments(appURL: app, target: project),
                ["--zed", app.path, "--existing", "--", path])
        }
    }

    func testZedProcessPreservesErrorsAndBoundsItsLifetime() async throws {
        func process(_ executable: String, _ arguments: [String] = []) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        try await ZedNotification.run(process("/usr/bin/true"))
        do {
            try await ZedNotification.run(process("/usr/bin/false"))
            XCTFail("nonzero exit was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit status 1"))
        }
        do {
            try await ZedNotification.run(process("/nonexistent/zed-cli"))
            XCTFail("missing executable was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not start Zed's bundled CLI:"))
            XCTAssertTrue(error.localizedDescription.contains("NSCocoaErrorDomain"))
        }
        let timedOut = process("/bin/sleep", ["30"])
        do {
            try await ZedNotification.run(timedOut, timeout: .milliseconds(50))
            XCTFail("timeout was ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("within"))
        }
        timedOut.waitUntilExit()
        XCTAssertNotEqual(timedOut.terminationStatus, 0)

        let cancelled = process("/bin/sleep", ["30"])
        let task = Task { try await ZedNotification.run(cancelled) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !cancelled.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("cancellation was ignored")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        cancelled.waitUntilExit()
        XCTAssertNotEqual(cancelled.terminationStatus, 0)
    }

    @MainActor
    func testCombinedClickPrefersZedAndRetainsTerminalFallback() async throws {
        let identity = TmuxProcessIdentity(pid: 123, startSeconds: 456, startMicroseconds: 789)
        let tmux = TmuxNotificationTarget(pane: "%3", socket: "/tmp/tmux", server: identity)
        let project = ZedProjectTarget(path: "/tmp/project")
        var events: [String] = []
        func select(_ target: TmuxNotificationTarget) async -> TmuxProcessIdentity? {
            XCTAssertEqual(target.pane, "%3")
            events.append("select")
            return identity
        }
        func raise(_ client: TmuxProcessIdentity) {
            XCTAssertEqual(client, identity)
            events.append("raise")
        }
        let combined = NotificationClickTarget(tmux: tmux, zedProject: project)
        try await combined.activate(
            selectTmux: select, openZed: { _ in events.append("zed") }, raiseHost: raise)
        XCTAssertEqual(events, ["select", "zed"])
        events = []
        do {
            try await combined.activate(
                selectTmux: select,
                openZed: { _ in
                    events.append("zed")
                    throw VoiceNotificationError("test failure")
                }, raiseHost: raise)
            XCTFail("Zed failure was swallowed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "test failure")
        }
        XCTAssertEqual(events, ["select", "zed", "raise"])
        events = []
        try await NotificationClickTarget(tmux: tmux).activate(
            selectTmux: select, openZed: { _ in XCTFail("unexpected Zed target") }, raiseHost: raise
        )
        XCTAssertEqual(events, ["select", "raise"])
    }

    func testProjectClickMetadataNeverEntersPushPayload() throws {
        let message = NotificationMessage(
            title: "Build", message: "Passed", group: "build", pane: "%3",
            tmuxSocket: "/tmp/private-server", zedProject: "/tmp/private-project", push: true)
        let configuration = NtfyConfiguration(
            server: "https://example.test", topic: "private", token: "test-token")
        let request = try NtfyPush.request(for: message, configuration: configuration)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, ["topic": "private", "title": "Build", "message": "Passed"])
    }

    func testProjectRequestsCannotSilentlyDowngradeToOldVoice() throws {
        let message = NotificationMessage(
            title: "Build", message: "Passed", group: "build", zedProject: "/tmp/project")
        let (request, failure) = try NotificationClient.prepare(.post(message))
        XCTAssertNil(failure)
        guard case .postWithProject(let prepared) = request else {
            return XCTFail("an old Voice app would ignore the project target")
        }
        XCTAssertEqual(prepared.zedProject, message.zedProject)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func app(_ name: String, identifier: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
            ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
}
