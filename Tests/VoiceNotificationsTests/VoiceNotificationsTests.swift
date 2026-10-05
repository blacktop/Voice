import Darwin
import Security
import XCTest

@testable import VoiceNotifications

final class VoiceNotificationsTests: XCTestCase {
    private let message = NotificationMessage(
        title: "Build", subtitle: "Tests", message: "Passed", group: "abc")

    func testReplacementIdentifierUsesOnlyGroupAndStableSHA256() {
        XCTAssertEqual(
            message.identifier,
            "voice-notify.ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var changed = message
        changed.message = "Failed"
        XCTAssertEqual(changed.identifier, message.identifier)
        changed.group = "different"
        XCTAssertNotEqual(changed.identifier, message.identifier)
    }

    func testServiceDirectoryIsOwnedByTheCurrentUserAndPrivate() throws {
        let path = try NotificationSocket.path()
        var info = stat()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o077, 0)
        XCTAssertLessThanOrEqual(path.utf8.count, 103)
    }

    func testLaunchRejectsAnotherRunningInstallation() throws {
        let app = URL(fileURLWithPath: "/Applications/Voice.app")
        XCTAssertNoThrow(try NotificationClient.checkLaunch(appURL: app, runningAppURLs: []))
        XCTAssertNoThrow(
            try NotificationClient.checkLaunch(appURL: app, runningAppURLs: [app]))
        let other = URL(fileURLWithPath: "/tmp/old/Voice.app")
        XCTAssertThrowsError(
            try NotificationClient.checkLaunch(appURL: app, runningAppURLs: [other])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "quit the Voice running at \(other.resolvingSymlinksInPath().path), then retry")
        }
        XCTAssertThrowsError(
            try NotificationClient.checkLaunch(appURL: app, runningAppURLs: [nil]))
    }

    @MainActor
    func testApplicationSelectionPrefersContainingThenInstalledApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, identifier: String = "io.blacktop.Voice") throws -> URL {
            let url = root.appendingPathComponent(name + ".app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
                ],
                format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let installed = try app("Installed")
        let embedded = try app("Embedded")
        let unrelated = try app("Unrelated", identifier: "example.Unrelated")
        let registered = root.appendingPathComponent("OldRegistered.app")
        let executable = embedded.appendingPathComponent("Contents/MacOS/voice-notify")
        XCTAssertEqual(
            try NotificationClient.applicationURL(
                executableURL: executable, installedAppURL: installed,
                registeredAppURL: { registered }), embedded)
        XCTAssertEqual(
            try NotificationClient.applicationURL(
                executableURL: nil, installedAppURL: installed,
                registeredAppURL: { registered }), installed)
        XCTAssertEqual(
            try NotificationClient.applicationURL(
                executableURL: nil, installedAppURL: unrelated,
                registeredAppURL: { registered }), registered)
        XCTAssertThrowsError(
            try NotificationClient.applicationURL(
                executableURL: nil, installedAppURL: unrelated, registeredAppURL: { nil }))
    }

    func testInputBoundsAndUnicodePreview() throws {
        XCTAssertNoThrow(try message.validate())
        for pane in ["", "3", "%", "%1;kill-server", "%١"] {
            var invalid = message
            invalid.pane = pane
            XCTAssertThrowsError(try invalid.validate(), pane)
        }
        var oversized = message
        oversized.message = String(repeating: "x", count: 8193)
        XCTAssertThrowsError(try oversized.validate())
        let preview = NotificationMessage.preview(parts: [String(repeating: "🦉", count: 1000)])
        XCTAssertLessThanOrEqual(preview.utf8.count, 1024)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertFalse(preview.contains("�"))
    }

    func testClickPlanUsesCurrentSessionAndOnlyPermittedMutations() {
        let clients = [
            TmuxClient(pid: 10, activity: 500, session: "$1"),
            TmuxClient(pid: 11, activity: 300, session: "$2"),
            TmuxClient(pid: 12, activity: 400, session: "$2"),
        ]
        XCTAssertEqual(
            TmuxClickPlan.make(pane: "%3", currentSession: "$2", clients: clients),
            TmuxClickPlan(
                clientPID: 12,
                commands: [["select-window", "-t", "%3"], ["select-pane", "-t", "%3"]]))
        XCTAssertEqual(
            TmuxClickPlan.make(pane: "%3", currentSession: "$9", clients: clients),
            TmuxClickPlan(clientPID: 10, commands: []))
        XCTAssertEqual(
            TmuxClickPlan.make(pane: "%3", currentSession: nil, clients: clients).commands, [])
        XCTAssertNil(TmuxClickPlan.make(pane: "%3", currentSession: "$2", clients: []).clientPID)
        XCTAssertEqual(
            TmuxClickPlan.make(pane: "bad", currentSession: "$2", clients: clients).commands, [])
    }

    func testNtfyPayloadKeepsTitleAndPutsSubtitleAboveMessage() throws {
        let config = NtfyConfiguration(
            server: "https://example.test", topic: "private-topic", token: "test-token")
        let request = try NtfyPush.request(for: message, configuration: config)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(
            payload, ["topic": "private-topic", "title": "Build", "message": "Tests\nPassed"])
        XCTAssertThrowsError(try NtfyPush.checkStatus(401))
        XCTAssertThrowsError(try NtfyPush.checkStatus(403))
        XCTAssertThrowsError(try NtfyPush.checkStatus(302))
        XCTAssertNoThrow(try NtfyPush.checkStatus(200))
    }

    func testMissingAndCrossServerCredentialsFailClosed() throws {
        XCTAssertThrowsError(try NtfyOverrides().resolve(stored: nil))
        let stored = NtfyConfiguration(
            server: "https://example.test", topic: "private", token: "saved-token")
        XCTAssertEqual(
            try NtfyOverrides(topic: "next").resolve(stored: stored).token, "saved-token")
        XCTAssertThrowsError(
            try NtfyOverrides(server: "https://other.test").resolve(stored: stored))
        XCTAssertEqual(
            try NtfyOverrides(server: "https://other.test", token: "explicit").resolve(
                stored: stored
            ).token, "explicit")
        for url in [
            "http://example.test", "https://user:pass@example.test", "https://example.test/?q=1",
            "https://example.test/#x",
        ] {
            XCTAssertThrowsError(
                try NtfyConfiguration(server: url, topic: "x", token: "token").validate())
        }
        XCTAssertThrowsError(
            try NtfyConfiguration(server: stored.server, topic: "../x", token: "token").validate())
        XCTAssertThrowsError(
            try NtfyConfiguration(server: stored.server, topic: "x", token: "token\nheader")
                .validate())
    }

    func testKeychainErrorsExplainMissingProvisioning() {
        for operation in ["read", "save"] {
            XCTAssertThrowsError(
                try NtfyKeychain.checkStatus(errSecMissingEntitlement, operation: operation)
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("provisioning profile"))
                XCTAssertTrue(error.localizedDescription.contains("reinstall"))
            }
        }
        XCTAssertNoThrow(try NtfyKeychain.checkStatus(errSecSuccess, operation: "save"))
        XCTAssertThrowsError(
            try NtfyKeychain.checkStatus(errSecInteractionNotAllowed, operation: "save")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "could not save ntfy configuration in Keychain (\(errSecInteractionNotAllowed))")
        }
    }

    func testPartialFailureDoesNotUndoOrSkipOtherChannel() async {
        var local = 0
        var remote = 0
        let response = await NotificationDelivery.perform(push: true) {
            local += 1
        } remote: {
            remote += 1
            throw VoiceNotificationError("rejected")
        }
        XCTAssertEqual(local, 1)
        XCTAssertEqual(remote, 1)
        XCTAssertEqual(response.failures, ["push: rejected"])
        let disabled = await NotificationDelivery.perform(
            push: false, local: {}, remote: { XCTFail("push was not requested") })
        XCTAssertTrue(disabled.accepted)
    }

    func testTransportBoundsPreserveTheMacChannel() throws {
        var requested = NotificationMessage(
            title: String(repeating: "\u{1}", count: 512),
            subtitle: String(repeating: "\u{1}", count: 1024),
            message: String(repeating: "\u{1}", count: 8192),
            group: String(repeating: "\u{1}", count: 1024), push: true,
            pushOverrides: NtfyOverrides(token: String(repeating: "x", count: 200_000)))
        let (prepared, failure) = try NotificationClient.prepare(.post(requested))
        guard case .post(let local) = prepared else { return XCTFail("lost Mac request") }
        XCTAssertEqual(local.message, requested.message)
        XCTAssertEqual(local.identifier, requested.identifier)
        XCTAssertFalse(local.push)
        XCTAssertNil(local.pushOverrides)
        XCTAssertEqual(failure, "push: ntfy token is empty or invalid")
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(prepared).count, NotificationSocket.maximumFrame)

        requested.pushOverrides = NtfyOverrides(
            server: "https://example.test", topic: "private",
            token: String(repeating: "\"", count: 4096))
        let (valid, validFailure) = try NotificationClient.prepare(.post(requested))
        XCTAssertNil(validFailure)
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertGreaterThan(encoded.count, 65_536)
        XCTAssertLessThanOrEqual(encoded.count, NotificationSocket.maximumFrame)

        requested.push = false
        let (disabled, _) = try NotificationClient.prepare(.post(requested))
        guard case .post(let withoutPush) = disabled else { return XCTFail("lost Mac request") }
        XCTAssertNil(withoutPush.pushOverrides)
    }

    private func pair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw VoiceNotificationError("socketpair failed")
        }
        try NotificationSocket.prepare(descriptors[0])
        try NotificationSocket.prepare(descriptors[1])
        let pair = (descriptors[0], descriptors[1])
        addTeardownBlock {
            close(pair.0)
            close(pair.1)
        }
        return pair
    }

    func testRejectedPeerReceivesNoCredentialBytes() throws {
        let (client, server) = try pair()
        let request = NotificationRPCRequest.configurePush(
            NtfyConfiguration(server: "https://example.test", topic: "private", token: "secret"))
        XCTAssertThrowsError(
            try NotificationClient.exchange(
                request, descriptor: client,
                authenticate: {
                    throw VoiceNotificationError("bad signature")
                }))
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(server, &byte, 1), -1)
        XCTAssertEqual(errno, EAGAIN)
    }

    private func identity(for path: String? = nil) throws -> NotificationAppIdentity {
        var code: SecStaticCode?
        if let path {
            XCTAssertEqual(
                SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code),
                errSecSuccess)
        } else {
            var own: SecCode?
            XCTAssertEqual(SecCodeCopySelf([], &own), errSecSuccess)
            XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(own), [], &code), errSecSuccess)
        }
        var requirement: SecRequirement?
        XCTAssertEqual(
            SecCodeCopyDesignatedRequirement(try XCTUnwrap(code), [], &requirement), errSecSuccess)
        return try NotificationAppIdentity(requirement: XCTUnwrap(requirement))
    }

    private func socketPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("rpc.sock").path
    }

    func testKernelAuditTokenMatchesActualServerCodeAndRejectsDifferentCode() throws {
        let expected = try identity()
        let rejected = try identity(for: "/usr/bin/true")
        let path = try socketPath()
        let server = try NotificationServer(path: path, clientIdentity: expected) { _ in
            NotificationRPCResponse()
        }
        defer { withExtendedLifetime(server) {} }
        let descriptor = try XCTUnwrap(NotificationSocket.connect(path))
        defer { close(descriptor) }
        XCTAssertNoThrow(try expected.verify(descriptor))
        XCTAssertThrowsError(try rejected.verify(descriptor))
        let result = try NotificationClient.exchange(
            .post(message), descriptor: descriptor,
            authenticate: {
                try expected.verify(descriptor)
            })
        XCTAssertTrue(result.accepted)
    }

    func testServerRejectsUntrustedClientBeforeDispatch() throws {
        let path = try socketPath()
        let server = try NotificationServer(
            path: path, clientIdentity: identity(for: "/usr/bin/true")
        ) { _ in
            XCTFail("an untrusted client reached the handler")
            return NotificationRPCResponse()
        }
        defer { withExtendedLifetime(server) {} }
        let descriptor = try XCTUnwrap(NotificationSocket.connect(path))
        defer { close(descriptor) }
        let request = NotificationRPCRequest.configurePush(
            NtfyConfiguration(server: "https://example.test", topic: "private", token: "secret"))
        XCTAssertThrowsError(
            try NotificationClient.exchange(request, descriptor: descriptor, authenticate: {}))
    }

    func testFramingRoundTripAndOversizeAndEarlyClose() throws {
        let (writer, reader) = try pair()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        try NotificationSocket.send(
            NotificationRPCResponse(failures: ["push rejected"]), to: writer, until: deadline)
        XCTAssertEqual(
            try NotificationSocket.receive(
                NotificationRPCResponse.self, from: reader, until: deadline
            ).failures, ["push rejected"])
        var oversized = UInt32(NotificationSocket.maximumFrame + 1).bigEndian
        XCTAssertEqual(
            withUnsafeBytes(of: &oversized) { Darwin.write(writer, $0.baseAddress, $0.count) }, 4)
        XCTAssertThrowsError(
            try NotificationSocket.receive(
                NotificationRPCResponse.self, from: reader, until: deadline))
        XCTAssertEqual(shutdown(writer, SHUT_WR), 0)
        XCTAssertThrowsError(
            try NotificationSocket.receive(
                NotificationRPCResponse.self, from: reader, until: deadline))
    }

    func testReadHasAnAbsoluteDeadline() throws {
        let (_, reader) = try pair()
        XCTAssertThrowsError(
            try NotificationSocket.read(
                reader, count: 1, until: .now.advanced(by: .milliseconds(20))))
    }
}
