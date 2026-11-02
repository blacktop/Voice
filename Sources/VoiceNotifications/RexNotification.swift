import AppKit
import Darwin
import Foundation

/// Full Rex IDs and a local server socket. Labels and abbreviated IDs are not
/// stable enough to retain in Notification Center.
public struct RexNotificationContext: Codable, Sendable, Equatable {
    public let session: String
    public let block: String
    public let server: String
    public let client: String?

    public init(session: String, block: String, server: String? = nil, client: String? = nil)
        throws
    {
        self.session = try Self.identifier(session, kind: "session")
        self.block = try Self.identifier(block, kind: "block")
        self.server = try Self.socketPath(
            server ?? NSHomeDirectory() + "/Library/Application Support/rex/server.sock")
        self.client = try client.map { try Self.identifier($0, kind: "client") }
    }

    public func validate() throws {
        let normalized = try Self(session: session, block: block, server: server, client: client)
        guard normalized == self else {
            throw VoiceNotificationError("Rex target IDs and socket must use their canonical form")
        }
    }

    static func resolve(
        session: String?, block: String?, server: String?, client: String?,
        environment: [String: String]
    ) throws -> Self? {
        let session = session ?? environment["REX_SESSION"]
        let block = block ?? environment["REX_BLOCK"]
        guard session != nil || block != nil || server != nil || client != nil else { return nil }
        guard let session, let block else {
            throw VoiceNotificationError(
                "a Rex target requires both a full session ID and block ID")
        }
        return try Self(
            session: session, block: block, server: server ?? environment["REX_SERVER"],
            client: client ?? environment["REX_CLIENT"])
    }

    static func identifier(_ value: String, kind: String) throws -> String {
        let prefix = kind + ":"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 36,
            let uuid = UUID(uuidString: String(value.dropFirst(prefix.count)))
        else { throw VoiceNotificationError("Rex \(kind) must be a full \(kind):UUID identifier") }
        return prefix + uuid.uuidString.lowercased()
    }

    static func socketPath(_ value: String) throws -> String {
        let path: String
        if value.hasPrefix("/") {
            path = value
        } else if let url = URLComponents(string: value), url.scheme == "unix",
            url.host == nil || url.host == "", url.user == nil, url.password == nil,
            url.port == nil, url.query == nil, url.fragment == nil
        {
            path = url.path
        } else {
            throw VoiceNotificationError("Rex notifications require a local Unix socket path")
        }
        guard path.hasPrefix("/"), path.utf8.count <= 103,
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw VoiceNotificationError(
                "Rex socket must be an absolute local path of at most 103 bytes")
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct RexNotificationTarget: Codable, Sendable, Equatable {
    let context: RexNotificationContext
    let hostID: UUID
    let instanceID: UUID
    let serverProcess: TmuxProcessIdentity
}

struct RexServerStatus: Decodable, Sendable {
    let hostID: UUID
    let instanceID: UUID
    let pid: Int32

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case instanceID = "instance_id"
        case pid
    }
}

struct RexClient: Decodable, Sendable, Equatable {
    struct Info: Decodable, Sendable, Equatable {
        let kind: String?
        let platform: String?
    }
    struct Principal: Decodable, Sendable, Equatable {
        let kind: String
        let transport: String
        let uid: UInt32?
        let pid: Int32?
    }
    let clientID: String
    let info: Info?
    let principal: Principal
    let connectionState: String?
    let sessionIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case connectionState = "connection_state"
        case sessionIDs = "session_ids"
        case info, principal
    }
}

enum RexNotification {
    private static let bundleIdentifier = "com.superlogical.rex"

    static func capture(_ context: RexNotificationContext) async throws -> RexNotificationTarget {
        try await capture(
            context, control: RexControl(socket: context.server), process: TmuxProcessIdentity.read)
    }

    static func capture(
        _ context: RexNotificationContext, control: RexControl,
        process: @Sendable (Int32) -> TmuxProcessIdentity?
    ) async throws -> RexNotificationTarget {
        try context.validate()
        let status: RexServerStatus = try await control.call(.status, RexEmptyArguments())
        try await resolve(context, control: control)
        guard let identity = process(status.pid) else {
            throw VoiceNotificationError("the local Rex server process could not be identified")
        }
        return RexNotificationTarget(
            context: context, hostID: status.hostID, instanceID: status.instanceID,
            serverProcess: identity)
    }

    @MainActor
    static func activate(_ target: RexNotificationTarget) async throws {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { !$0.isTerminated }
        let applicationsByPID = Dictionary(
            applications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first }
        )
        try await activate(
            target, control: RexControl(socket: target.context.server),
            localApplicationPIDs: Set(applicationsByPID.keys), process: TmuxProcessIdentity.read,
            raiseApplication: { identity in
                guard TmuxProcessIdentity.read(identity.pid) == identity,
                    let application = applicationsByPID[identity.pid], !application.isTerminated
                else { throw VoiceNotificationError("the selected Rex app is no longer running") }
                NSApp.yieldActivation(to: application)
                guard application.activate(options: []) else {
                    throw VoiceNotificationError(
                        "Rex accepted the target but could not be activated")
                }
            })
    }

    @MainActor
    static func activate(
        _ target: RexNotificationTarget, control: RexControl, localApplicationPIDs: Set<Int32>,
        process: @Sendable (Int32) -> TmuxProcessIdentity?,
        raiseApplication: (TmuxProcessIdentity) throws -> Void
    ) async throws {
        try target.context.validate()
        try Task.checkCancellation()
        let status: RexServerStatus = try await control.call(.status, RexEmptyArguments())
        guard status.hostID == target.hostID, status.instanceID == target.instanceID,
            status.pid == target.serverProcess.pid, process(status.pid) == target.serverProcess
        else {
            throw VoiceNotificationError("the original Rex server is no longer running")
        }
        try await resolve(target.context, control: control)
        let clients: RexClientList = try await control.call(.clients, RexClientListArguments())
        let client = try selectClient(
            clients.clients, context: target.context, localPIDs: localApplicationPIDs, uid: getuid()
        )
        guard let pid = client.principal.pid, let application = process(pid) else {
            throw VoiceNotificationError("the selected Rex app is no longer running")
        }
        try verifyProcesses(target, application: application, process: process)
        let _: RexRevision = try await control.call(
            .focusBlock,
            RexFocusArguments(sessionID: target.context.session, blockID: target.context.block))
        let window = try await selectedWindow(target.context, control: control)
        let pinnedClient = try RexNotificationContext(
            session: target.context.session, block: target.context.block,
            server: target.context.server, client: client.clientID)
        let currentClients: RexClientList = try await control.call(
            .clients, RexClientListArguments())
        _ = try selectClient(
            currentClients.clients, context: pinnedClient, localPIDs: [application.pid],
            uid: getuid())
        try verifyProcesses(target, application: application, process: process)
        let performed: RexPerformed = try await control.call(
            .showSession,
            RexShowArguments(
                clientID: client.clientID, session: target.context.session, window: window))
        guard performed.performedBy == client.clientID else {
            throw VoiceNotificationError("Rex did not confirm the selected Mac client")
        }
        guard try await selectedWindow(target.context, control: control) == window else {
            throw VoiceNotificationError("the Rex block moved while its notification was opening")
        }
        try verifyProcesses(target, application: application, process: process)
        try raiseApplication(application)
    }

    static func selectClient(
        _ clients: [RexClient], context: RexNotificationContext, localPIDs: Set<Int32>, uid: UInt32
    ) throws -> RexClient {
        let eligible = clients.filter {
            $0.info?.kind == "app" && $0.info?.platform == "macos"
                && $0.principal.kind == "peer" && $0.principal.transport == "unix"
                && $0.principal.uid == uid && $0.principal.pid.map(localPIDs.contains) == true
                && ($0.connectionState == nil || $0.connectionState == "connected")
                && (try? RexNotificationContext.identifier($0.clientID, kind: "client"))
                    == $0.clientID
        }
        let candidates: [RexClient]
        if let requested = context.client {
            candidates = eligible.filter { $0.clientID == requested }
        } else {
            let attached = eligible.filter { $0.sessionIDs?.contains(context.session) == true }
            candidates = attached.isEmpty ? eligible : attached
        }
        guard candidates.count == 1, let client = candidates.first else {
            throw VoiceNotificationError(
                candidates.isEmpty
                    ? "open the original Rex session in the Rex app on this Mac"
                    : "multiple local Rex clients match; pass --rex-client with a full client ID")
        }
        return client
    }

    private static func verifyProcesses(
        _ target: RexNotificationTarget, application: TmuxProcessIdentity,
        process: @Sendable (Int32) -> TmuxProcessIdentity?
    ) throws {
        try Task.checkCancellation()
        guard process(target.serverProcess.pid) == target.serverProcess,
            process(application.pid) == application
        else { throw VoiceNotificationError("the original Rex server or app is no longer running") }
    }

    private static func resolve(_ context: RexNotificationContext, control: RexControl) async throws
    {
        let response: RexResolveResponse = try await control.call(
            .resolve, RexResolveArguments(session: context.session, block: context.block))
        guard response.results.count == 1, let result = response.results.first,
            result.status == "resolved", let target = result.target, target.kind == "block",
            target.sessionID == context.session, target.blockID == context.block,
            let window = target.windowID,
            (try? RexNotificationContext.identifier(window, kind: "window")) == window
        else { throw VoiceNotificationError("the original Rex block is missing or detached") }
    }

    private static func selectedWindow(_ context: RexNotificationContext, control: RexControl)
        async throws -> String
    {
        let view: RexSessionView = try await control.call(
            .view, RexSessionArguments(sessionID: context.session))
        guard view.sessionID == context.session, let active = view.activeWindowID,
            (try? RexNotificationContext.identifier(active, kind: "window")) == active,
            view.windows.contains(where: {
                $0.windowID == active && $0.focusedBlockID == context.block
            })
        else { throw VoiceNotificationError("Rex did not select the original block") }
        return active
    }
}

enum RexMethod: String, Sendable {
    case status = "server.status"
    case resolve = "target.resolve"
    case clients = "client.list"
    case focusBlock = "session.focus_block"
    case view = "session.view"
    case showSession = "client.perform"
}

struct RexControl: Sendable {
    let send: @Sendable (RexMethod, Data) async throws -> Data

    init(socket: String) throws {
        let command = try RexCommand(socket: socket)
        send = { method, arguments in try await command.run(method, arguments: arguments) }
    }

    init(send: @escaping @Sendable (RexMethod, Data) async throws -> Data) { self.send = send }

    func call<Arguments: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: RexMethod, _ arguments: Arguments
    ) async throws -> Response {
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(arguments)
        let response = try await send(method, body)
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(Response.self, from: response) } catch {
            throw VoiceNotificationError("Rex returned an invalid response to \(method.rawValue)")
        }
    }
}

private struct RexEmptyArguments: Encodable, Sendable {}
private struct RexClientListArguments: Encodable, Sendable { let kinds = ["app"] }
private struct RexClientList: Decodable, Sendable { let clients: [RexClient] }
private struct RexRevision: Decodable, Sendable { let revision: UInt64 }

private struct RexSessionArguments: Encodable, Sendable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

private struct RexFocusArguments: Encodable, Sendable {
    let sessionID: String
    let blockID: String
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case blockID = "block_id"
    }
}

private struct RexResolveArguments: Encodable, Sendable {
    struct Scope: Encodable, Sendable { let session: String }
    let kinds = ["block"]
    let queries: [String]
    let scope: Scope
    init(session: String, block: String) {
        queries = [block]
        scope = Scope(session: session)
    }
}

private struct RexResolveResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct Target: Decodable, Sendable {
            let kind: String
            let sessionID: String?
            let blockID: String?
            let windowID: String?
            enum CodingKeys: String, CodingKey {
                case kind
                case sessionID = "session_id"
                case blockID = "block_id"
                case windowID = "window_id"
            }
        }
        let status: String
        let target: Target?
    }
    let results: [Result]
}

private struct RexSessionView: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let windowID: String
        let focusedBlockID: String?
        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case focusedBlockID = "focused_block_id"
        }
    }
    let sessionID: String
    let activeWindowID: String?
    let windows: [Window]
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case activeWindowID = "active_window_id"
        case windows
    }
}

private struct RexShowArguments: Encodable, Sendable {
    struct Arguments: Encodable, Sendable {
        let sessionID: String
        let windowID: String
        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case windowID = "window_id"
        }
    }
    let clientID: String
    let action = "session.select"
    let args: Arguments
    let timeoutMilliseconds = 2000
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case action, args
        case timeoutMilliseconds = "timeout_ms"
    }
    init(clientID: String, session: String, window: String) {
        self.clientID = clientID
        args = Arguments(sessionID: session, windowID: window)
    }
}

private struct RexPerformed: Decodable, Sendable {
    let performedBy: String
    enum CodingKeys: String, CodingKey { case performedBy = "performed_by" }
}
