import Darwin
import UserNotifications
import XCTest

@testable import VoiceNotifications

final class RexNotificationTests: XCTestCase {
    func testContextRequiresFullIDsAndLocalSocket() throws {
        let fixture = try RexFixture()
        let normalized = try RexNotificationContext(
            session: fixture.session.uppercased().replacingOccurrences(
                of: "SESSION:", with: "session:"),
            block: fixture.block, server: "unix:///tmp/rex%20server.sock")
        XCTAssertEqual(normalized.session, fixture.session)
        XCTAssertEqual(normalized.server, "/tmp/rex server.sock")
        for server in [
            "remote", "https://example.test", "unix://host/tmp/rex.sock", "/tmp/a\0b",
            "/" + String(repeating: "x", count: 104),
        ] {
            XCTAssertThrowsError(
                try RexNotificationContext(
                    session: fixture.session, block: fixture.block, server: server))
        }
        for invalid in ["work", "session:1234", "block:" + String(fixture.session.dropFirst(8))] {
            XCTAssertThrowsError(try RexNotificationContext(session: invalid, block: fixture.block))
        }
    }

    func testEnvironmentDefaultsPreserveExistingDestinations() throws {
        let fixture = try RexFixture()
        let environment = fixture.environment
        let automatic = try NotificationContext(
            pane: nil, noPane: false, tmuxSocket: nil, push: false, environment: environment)
        XCTAssertEqual(automatic.rex, fixture.context)
        XCTAssertNil(automatic.pane)
        let nested = environment.merging(["TMUX_PANE": "%8", "TMUX": "/tmp/tmux,42,0"]) { _, new in
            new
        }
        let tmux = try NotificationContext(
            pane: nil, noPane: false, tmuxSocket: nil, push: false, environment: nested)
        XCTAssertEqual(tmux.pane, "%8")
        XCTAssertNil(tmux.rex)
        let socketOnly = try NotificationContext(
            pane: nil, noPane: true, tmuxSocket: "/tmp/explicit-tmux", push: false,
            environment: environment)
        XCTAssertNil(socketOnly.rex)
        let explicit = try NotificationContext(
            pane: nil, noPane: false, tmuxSocket: nil, rexSession: fixture.session,
            rexBlock: fixture.block, rexServer: fixture.context.server, push: false,
            environment: nested)
        XCTAssertEqual(explicit.rex, fixture.context)
        XCTAssertNil(explicit.pane)
        let disabled = try NotificationContext(
            pane: nil, noPane: true, tmuxSocket: nil, noRex: true, push: false,
            environment: environment)
        XCTAssertNil(disabled.rex)
        let project = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let zed = try NotificationContext(
            pane: nil, noPane: true, tmuxSocket: nil, zedProject: project, push: false,
            environment: environment)
        XCTAssertNil(zed.rex)
        XCTAssertThrowsError(
            try NotificationContext(
                pane: "%3", noPane: false, tmuxSocket: nil, rexSession: fixture.session,
                rexBlock: fixture.block, push: false, environment: [:]))
        XCTAssertThrowsError(
            try NotificationContext(
                pane: nil, noPane: true, tmuxSocket: nil, rexSession: fixture.session,
                rexBlock: fixture.block, noRex: true, push: false, environment: [:]))
        XCTAssertThrowsError(
            try NotificationContext(
                pane: nil, noPane: true, tmuxSocket: nil, push: false,
                environment: ["REX_SESSION": fixture.session]))
    }

    @MainActor
    func testRexRPCAndDetailsKeepTheTargetLocal() throws {
        let fixture = try RexFixture()
        let message = NotificationMessage(
            title: "Build", message: "Preview", group: "build", rex: fixture.context,
            push: true, details: Data("Full text".utf8))
        let (request, failure) = try NotificationClient.prepare(.post(message))
        XCTAssertNil(failure)
        guard case .postWithRex = request else {
            return XCTFail("Rex target could silently downgrade")
        }
        let decoded = try JSONDecoder().decode(
            NotificationRPCRequest.self, from: NotificationSocket.encoded(request))
        guard case .postWithRex(let restored) = decoded else {
            return XCTFail("lost Rex discriminator")
        }
        XCTAssertEqual(restored.rex, fixture.context)
        let click = NotificationClickTarget(rex: fixture.target)
        let content = try VoiceNotificationAppDelegate.content(for: message, target: click)
        XCTAssertEqual(NotificationClickTarget.decode(content.userInfo), click)
        XCTAssertEqual(try VoiceNotificationAppDelegate.details(for: content).destination, .rex)
        let push = try NtfyPush.request(
            for: message,
            configuration: NtfyConfiguration(
                server: "https://example.test", topic: "private", token: "test-token"))
        let body = try XCTUnwrap(push.httpBody)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: body) as? [String: String],
            ["topic": "private", "title": "Build", "message": "Preview"])
        XCTAssertThrowsError(
            try NotificationMessage(
                title: "Build", message: "Preview", group: "build", pane: "%3", rex: fixture.context
            ).validate())
    }

    func testCaptureRejectsDetachedBlocks() async throws {
        let fixture = try RexFixture()
        let server = try RexTestServer(fixture: fixture, detached: true)
        do {
            _ = try await RexNotification.capture(
                fixture.context, control: server.control, process: fixture.process)
            XCTFail("detached block was captured")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing or detached"))
        }
    }

    func testClientSelectionRequiresOneLocalApp() throws {
        let fixture = try RexFixture()
        let first = fixture.client(fixture.clientID, pid: 50, sessions: [fixture.session])
        let otherID = "client:00000000-0000-0000-0000-000000000051"
        let other = fixture.client(otherID, pid: 51, sessions: [])
        XCTAssertEqual(
            try RexNotification.selectClient(
                [first, other], context: fixture.context, localPIDs: [50, 51], uid: getuid()), first
        )
        let attached = fixture.client(otherID, pid: 51, sessions: [fixture.session])
        XCTAssertThrowsError(
            try RexNotification.selectClient(
                [first, attached], context: fixture.context, localPIDs: [50, 51], uid: getuid()))
        let explicit = try RexNotificationContext(
            session: fixture.session, block: fixture.block, server: fixture.context.server,
            client: otherID)
        XCTAssertEqual(
            try RexNotification.selectClient(
                [first, attached], context: explicit, localPIDs: [50, 51], uid: getuid()), attached)
        let remote = fixture.client(otherID, pid: 51, sessions: [fixture.session], transport: "tcp")
        XCTAssertThrowsError(
            try RexNotification.selectClient(
                [remote], context: fixture.context, localPIDs: [51], uid: getuid()))
    }

    @MainActor
    func testClickUsesTheBlocksCurrentWindowAndConfirmsClient() async throws {
        let fixture = try RexFixture()
        let server = try RexTestServer(fixture: fixture, selectedWindow: fixture.movedWindow)
        var raised: [TmuxProcessIdentity] = []
        try await RexNotification.activate(
            fixture.target, control: server.control, localApplicationPIDs: [50],
            process: fixture.process, raiseApplication: { raised.append($0) })
        XCTAssertEqual(raised, [fixture.appProcess])
        let calls = await server.calls
        XCTAssertEqual(
            calls.map(\.method),
            [.status, .resolve, .clients, .focusBlock, .view, .clients, .showSession, .view])
        let focus = try jsonObject(XCTUnwrap(calls.first { $0.method == .focusBlock }).arguments)
        XCTAssertEqual(focus["session_id"] as? String, fixture.session)
        XCTAssertEqual(focus["block_id"] as? String, fixture.block)
        let show = try jsonObject(XCTUnwrap(calls.first { $0.method == .showSession }).arguments)
        XCTAssertEqual(show["client_id"] as? String, fixture.clientID)
        XCTAssertEqual(show["action"] as? String, "session.select")
        XCTAssertEqual((show["args"] as? [String: String])?["window_id"], fixture.movedWindow)
    }

    @MainActor
    func testServerRestartFailsBeforeAnyFocusMutation() async throws {
        let fixture = try RexFixture()
        let server = try RexTestServer(fixture: fixture, instanceID: UUID())
        do {
            try await RexNotification.activate(
                fixture.target, control: server.control, localApplicationPIDs: [50],
                process: fixture.process,
                raiseApplication: { _ in XCTFail("raised a stale target") })
            XCTFail("restarted server was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("original Rex server"))
        }
        let calls = await server.calls
        XCTAssertEqual(calls.map(\.method), [.status])
    }

    @MainActor
    func testChangedClientProcessIsNotSentAnAction() async throws {
        let fixture = try RexFixture()
        let server = try RexTestServer(fixture: fixture, clientPIDAfterRefresh: 51)
        do {
            try await RexNotification.activate(
                fixture.target, control: server.control, localApplicationPIDs: [50, 51],
                process: fixture.process,
                raiseApplication: { _ in XCTFail("raised a changed client") })
            XCTFail("changed client was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("original Rex session"))
        }
        let calls = await server.calls
        XCTAssertFalse(calls.contains { $0.method == .showSession })
    }

    @MainActor
    func testRexClickCannotRunTmuxOrZedActions() async throws {
        let fixture = try RexFixture()
        var opened: [RexNotificationTarget] = []
        try await NotificationClickTarget(rex: fixture.target).activate(
            selectTmux: { _ in
                XCTFail("unexpected tmux selection")
                return nil
            },
            openZed: { _ in XCTFail("unexpected Zed activation") },
            raiseHost: { _ in XCTFail("unexpected terminal activation") },
            openRex: { opened.append($0) })
        XCTAssertEqual(opened, [fixture.target])
    }

    func testRexProcessBoundsAndCleanup() async throws {
        for (command, timeout, limit) in [
            (process("/bin/sleep", ["30"]), Duration.milliseconds(50), 128),
            (process("/usr/bin/yes", ["x"]), Duration.seconds(2), 128),
        ] {
            do {
                _ = try await BlockingCall.run {
                    try RexCommand.output(of: command, timeout: timeout, maximumOutput: limit)
                }
                XCTFail("unbounded Rex process was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("limit"))
            }
            XCTAssertFalse(command.isRunning)
        }
    }

    func testRemoteControlRejectionIsActionable() async throws {
        let command = process(
            "/bin/sh",
            [
                "-c", "printf '%s' 'Rex.app is not accepting actions' >&2; exit 1",
            ])
        do {
            _ = try await BlockingCall.run { try RexCommand.output(of: command) }
            XCTFail("rejected client action was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Remote Control"))
            XCTAssertTrue(error.localizedDescription.contains("Rex Server"))
        }
        XCTAssertFalse(command.isRunning)
    }

    func testSuccessfulRexJSONIsSeparateFromDiagnostics() async throws {
        let command = process(
            "/bin/sh",
            ["-c", "printf '%s' '{\"revision\":1}'; printf '%s' 'warning: test diagnostic' >&2"])
        let output = try await BlockingCall.run { try RexCommand.output(of: command) }
        XCTAssertEqual(try jsonObject(output)["revision"] as? Int, 1)
        XCTAssertFalse(command.isRunning)
    }

    private func process(_ path: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct RexFixture: Sendable {
    let session = "session:00000000-0000-0000-0000-000000000001"
    let block = "block:00000000-0000-0000-0000-000000000002"
    let window = "window:00000000-0000-0000-0000-000000000003"
    let movedWindow = "window:00000000-0000-0000-0000-000000000004"
    let clientID = "client:00000000-0000-0000-0000-000000000005"
    let hostID: UUID
    let instanceID: UUID
    let context: RexNotificationContext
    let serverProcess = TmuxProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1)
    let appProcess = TmuxProcessIdentity(pid: 50, startSeconds: 101, startMicroseconds: 2)

    init() throws {
        hostID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000006"))
        instanceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000007"))
        context = try RexNotificationContext(
            session: session, block: block, server: "/tmp/rex.sock")
    }

    var target: RexNotificationTarget {
        RexNotificationTarget(
            context: context, hostID: hostID, instanceID: instanceID, serverProcess: serverProcess)
    }
    var environment: [String: String] {
        ["REX_SESSION": session, "REX_BLOCK": block, "REX_SERVER": context.server]
    }
    var process: @Sendable (Int32) -> TmuxProcessIdentity? {
        { pid in
            pid == serverProcess.pid ? serverProcess : (pid == appProcess.pid ? appProcess : nil)
        }
    }

    func client(_ id: String, pid: Int32, sessions: [String], transport: String = "unix")
        -> RexClient
    {
        RexClient(
            clientID: id, info: .init(kind: "app", platform: "macos"),
            principal: .init(kind: "peer", transport: transport, uid: getuid(), pid: pid),
            connectionState: "connected", sessionIDs: sessions)
    }
}

private actor RexTestServer {
    struct Call: Sendable {
        let method: RexMethod
        let arguments: Data
    }
    private(set) var calls: [Call] = []
    private let responses: [RexMethod: Data]
    private let refreshedClients: Data?
    nonisolated var control: RexControl { RexControl { try await self.receive($0, $1) } }

    init(
        fixture: RexFixture, detached: Bool = false, selectedWindow: String? = nil,
        instanceID: UUID? = nil, clientPIDAfterRefresh: Int32? = nil
    )
        throws
    {
        let window = selectedWindow ?? fixture.window
        var target: [String: Any] = [
            "kind": "block", "session_id": fixture.session, "block_id": fixture.block,
        ]
        if !detached { target["window_id"] = fixture.window }
        func clientObject(pid: Int32) -> [String: Any] {
            [
                "client_id": fixture.clientID,
                "info": ["kind": "app", "platform": "macos"],
                "principal": ["kind": "peer", "transport": "unix", "uid": getuid(), "pid": pid],
                "connection_state": "connected", "session_ids": [fixture.session],
            ]
        }
        let objects: [RexMethod: Any] = [
            .status: [
                "host_id": fixture.hostID.uuidString,
                "instance_id": (instanceID ?? fixture.instanceID).uuidString, "pid": 42,
            ],
            .resolve: ["results": [["status": "resolved", "target": target]]],
            .clients: ["clients": [clientObject(pid: 50)]],
            .focusBlock: ["revision": 1],
            .view: [
                "session_id": fixture.session, "active_window_id": window,
                "windows": [["window_id": window, "focused_block_id": fixture.block]],
            ],
            .showSession: ["performed_by": fixture.clientID],
        ]
        responses = try objects.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        refreshedClients = try clientPIDAfterRefresh.map {
            try JSONSerialization.data(withJSONObject: ["clients": [clientObject(pid: $0)]])
        }
    }

    private func receive(_ method: RexMethod, _ arguments: Data) throws -> Data {
        let refresh = method == .clients && calls.contains { $0.method == .clients }
        calls.append(Call(method: method, arguments: arguments))
        if refresh, let refreshedClients { return refreshedClients }
        return try XCTUnwrap(responses[method])
    }
}
