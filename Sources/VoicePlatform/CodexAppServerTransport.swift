import Darwin
import Foundation
import VoiceCore

/// Errors produced while driving a local Codex app-server process.
public enum CodexAppServerTransportError: LocalizedError, Sendable {
    case connectionClosed
    case invalidConfiguration(String)
    case invalidResponse(String)
    case notConnected
    case processLaunch(String)
    case serverError(code: Int?, message: String)
    case sessionNotStarted
    case turnFailed(String)
    case turnInProgress

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "The Codex app-server connection closed unexpectedly."
        case .invalidConfiguration(let reason):
            "The Codex app-server configuration is invalid: \(reason)"
        case .invalidResponse(let reason):
            "Codex app-server returned an invalid response: \(reason)"
        case .notConnected:
            "Codex app-server is not connected."
        case .processLaunch(let reason):
            "Codex app-server could not be launched: \(reason)"
        case .serverError(let code, let message):
            if let code {
                "Codex app-server error \(code): \(message)"
            } else {
                "Codex app-server error: \(message)"
            }
        case .sessionNotStarted:
            "Start or resume a Codex thread before sending a prompt."
        case .turnFailed(let message):
            "The Codex turn failed: \(message)"
        case .turnInProgress:
            "A Codex turn is already in progress."
        }
    }
}

/// A stable, read-only Codex app-server client over stdio JSONL.
///
/// The configured executable is launched directly. No shell is involved and
/// the transport neither reads nor supplies credentials; Codex owns its normal
/// authentication lifecycle.
public actor CodexAppServerTransport: AgentTransport {
    private struct ActiveTurn {
        let token: UUID
        let threadID: String
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        var turnID: String?
        var accumulatedText = ""
        var emittedCompletedMessage = false
        var cancellationRequested = false
        var localStreamFinished = false
    }

    typealias ConnectionFactory = @Sendable () -> any CodexAppServerConnection

    private let connectionFactory: ConnectionFactory
    private var activeTurn: ActiveTurn?
    private var configuration: AgentConfiguration?
    private var connection: (any CodexAppServerConnection)?
    private var disconnectHandler: (@Sendable (String) -> Void)?
    private var disconnecting = false
    /// Interrupted turns whose slot was released before the server confirmed;
    /// their late notifications are ignored until turn/completed drains them.
    private var drainingTurnIDs: Set<String> = []
    /// A fast turn can complete before send() resumes from the turn/start
    /// response; the finished token lets send() still hand back the (buffered)
    /// event stream instead of reporting a spurious cancellation.
    private var earlyFinishedTurnToken: UUID?
    private var nextRequestID = 0
    private var pendingResponses:
        [CodexAppServerRequestID: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var readerTask: Task<Void, Never>?
    private var session: AgentSession?

    public init() {
        connectionFactory = { CodexAppServerProcessConnection() }
    }

    init(connectionFactory: @escaping ConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public func connect(_ configuration: AgentConfiguration) async throws {
        await disconnect()
        try Self.validate(configuration)

        let newConnection = connectionFactory()
        let messages: AsyncThrowingStream<CodexAppServerEnvelope, Error>
        do {
            messages = try await newConnection.start(
                executableURL: configuration.executableURL.standardizedFileURL,
                currentDirectoryURL: configuration.projectURL.standardizedFileURL
            )
        } catch {
            throw CodexAppServerTransportError.processLaunch(error.localizedDescription)
        }

        self.configuration = configuration
        connection = newConnection
        nextRequestID = 0
        disconnecting = false
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(messages)
        }

        do {
            _ = try await request(
                method: "initialize",
                params: CodexAppServerWire.initializeParams
            )
            try await newConnection.send(CodexAppServerWire.initializedNotification)
        } catch {
            await tearDownConnection(with: error)
            throw error
        }
    }

    public func startOrResume(sessionID: String?) async throws -> AgentSession {
        guard connection != nil else {
            throw CodexAppServerTransportError.notConnected
        }
        guard let configuration else {
            throw CodexAppServerTransportError.invalidConfiguration(
                "The project directory is unavailable."
            )
        }
        guard activeTurn == nil else {
            throw CodexAppServerTransportError.turnInProgress
        }

        let method: String
        let params: JSONValue
        if let sessionID, !sessionID.isEmpty {
            method = "thread/resume"
            params = CodexAppServerWire.threadResumeParams(
                threadID: sessionID,
                projectPath: configuration.projectURL.standardizedFileURL.path
            )
        } else {
            method = "thread/start"
            params = CodexAppServerWire.threadStartParams(
                projectPath: configuration.projectURL.standardizedFileURL.path
            )
        }

        let result = try await request(method: method, params: params)
        guard let threadID = result["thread"]?["id"]?.stringValue,
            !threadID.isEmpty
        else {
            throw CodexAppServerTransportError.invalidResponse(
                "\(method) did not contain result.thread.id."
            )
        }

        let session = AgentSession(id: threadID)
        self.session = session
        return session
    }

    public func send(_ prompt: String) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard connection != nil else {
            throw CodexAppServerTransportError.notConnected
        }
        guard let session else {
            throw CodexAppServerTransportError.sessionNotStarted
        }
        guard let configuration else {
            throw CodexAppServerTransportError.invalidConfiguration(
                "The project directory is unavailable."
            )
        }
        guard activeTurn == nil else {
            throw CodexAppServerTransportError.turnInProgress
        }

        let token = UUID()
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.consumerTerminated(token: token)
            }
        }
        activeTurn = ActiveTurn(
            token: token,
            threadID: session.id,
            continuation: pair.continuation
        )
        earlyFinishedTurnToken = nil
        pair.continuation.yield(.connected)

        do {
            let result = try await request(
                method: "turn/start",
                params: CodexAppServerWire.turnStartParams(
                    threadID: session.id,
                    prompt: prompt,
                    projectPath: configuration.projectURL.standardizedFileURL.path
                )
            )
            guard let turnID = result["turn"]?["id"]?.stringValue,
                !turnID.isEmpty
            else {
                throw CodexAppServerTransportError.invalidResponse(
                    "turn/start did not contain result.turn.id."
                )
            }

            guard var current = activeTurn, current.token == token else {
                if earlyFinishedTurnToken == token {
                    // The reader drained the whole turn before this response
                    // resumed; the stream buffered every event and terminal
                    // state, so hand it to the caller as usual.
                    earlyFinishedTurnToken = nil
                    return pair.stream
                }
                throw CancellationError()
            }
            current.turnID = turnID
            let shouldInterrupt = current.cancellationRequested
            activeTurn = current
            if shouldInterrupt {
                do {
                    try await requestTurnInterrupt(current)
                } catch {
                    await tearDownConnection(with: error)
                    throw error
                }
                releaseTurnSlot(token: token)
            }
            return pair.stream
        } catch {
            if activeTurn?.token == token {
                activeTurn = nil
            }
            if earlyFinishedTurnToken == token {
                earlyFinishedTurnToken = nil
            }
            pair.continuation.finish(throwing: error)
            throw error
        }
    }

    public func interrupt() async {
        guard let current = markActiveTurnCancelling(token: nil) else { return }
        guard current.turnID != nil else { return }
        do {
            try await requestTurnInterrupt(current)
        } catch {
            await tearDownConnection(with: error)
            return
        }
        // Release the turn slot now instead of holding it until the server's
        // turn/completed — otherwise the next prompt fails with turnInProgress
        // (or wedges the transport if confirmation never comes).
        releaseTurnSlot(token: current.token)
    }

    public func setDisconnectHandler(_ handler: (@Sendable (String) -> Void)?) async {
        disconnectHandler = handler
    }

    public func disconnect() async {
        disconnecting = true
        readerTask?.cancel()
        readerTask = nil

        let cancellation = CancellationError()
        finishPendingResponses(throwing: cancellation)
        finishActiveTurn(throwing: cancellation)
        drainingTurnIDs.removeAll()
        earlyFinishedTurnToken = nil

        let oldConnection = connection
        connection = nil
        configuration = nil
        session = nil
        if let oldConnection {
            await oldConnection.stop()
        }
        disconnecting = false
    }

    private static func validate(_ configuration: AgentConfiguration) throws {
        let executablePath = configuration.executableURL.standardizedFileURL.path
        guard configuration.executableURL.isFileURL,
            configuration.executableURL.standardizedFileURL.path.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw CodexAppServerTransportError.invalidConfiguration(
                "Choose an absolute, executable Codex CLI path."
            )
        }

        var isDirectory: ObjCBool = false
        let projectPath = configuration.projectURL.standardizedFileURL.path
        guard configuration.projectURL.isFileURL,
            FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CodexAppServerTransportError.invalidConfiguration(
                "Choose an existing project directory."
            )
        }
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard let connection else {
            throw CodexAppServerTransportError.notConnected
        }

        let id = CodexAppServerRequestID.number(nextRequestID)
        nextRequestID += 1
        let pair = AsyncThrowingStream<JSONValue, Error>.makeStream()
        pendingResponses[id] = pair.continuation

        do {
            try await connection.send(
                CodexAppServerWire.request(id: id, method: method, params: params)
            )
        } catch {
            pendingResponses.removeValue(forKey: id)
            pair.continuation.finish(throwing: error)
            throw error
        }

        var iterator = pair.stream.makeAsyncIterator()
        guard let result = try await iterator.next() else {
            throw CodexAppServerTransportError.connectionClosed
        }
        return result
    }

    private func consume(
        _ messages: AsyncThrowingStream<CodexAppServerEnvelope, Error>
    ) async {
        do {
            for try await message in messages {
                if Task.isCancelled { return }
                await receive(message)
            }
            if !Task.isCancelled {
                await connectionEnded(with: CodexAppServerTransportError.connectionClosed)
            }
        } catch is CancellationError {
            // An intentional disconnect owns cleanup.
        } catch {
            if !Task.isCancelled {
                await connectionEnded(with: error)
            }
        }
    }

    private func receive(_ envelope: CodexAppServerEnvelope) async {
        if let id = envelope.id, envelope.isResponse {
            resolveResponse(id: id, envelope: envelope)
            return
        }

        if let id = envelope.id, envelope.method != nil, let connection {
            // Voice does not opt into server-initiated capabilities. Respond so
            // Codex never waits indefinitely on an unsupported request.
            try? await connection.send(
                CodexAppServerWire.errorResponse(
                    id: id,
                    code: -32601,
                    message: "Unsupported server request"
                )
            )
            return
        }

        guard let notification = CodexAppServerNotificationExtractor.extract(from: envelope) else {
            return
        }
        handle(notification)
    }

    private func resolveResponse(
        id: CodexAppServerRequestID,
        envelope: CodexAppServerEnvelope
    ) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }

        if let error = envelope.error {
            continuation.finish(
                throwing: CodexAppServerTransportError.serverError(
                    code: error.code,
                    message: error.message
                )
            )
        } else if let result = envelope.result {
            continuation.yield(result)
            continuation.finish()
        } else {
            continuation.finish(
                throwing: CodexAppServerTransportError.invalidResponse(
                    "Response \(id.description) contained neither result nor error."
                )
            )
        }
    }

    private func handle(_ notification: CodexAppServerNotification) {
        if drainingTurnIDs.contains(notification.turnID) {
            if case .turnCompleted = notification {
                drainingTurnIDs.remove(notification.turnID)
            }
            return
        }

        guard var current = activeTurn,
            current.threadID == notification.threadID
        else {
            return
        }

        if let currentTurnID = current.turnID,
            currentTurnID != notification.turnID
        {
            return
        }
        if current.turnID == nil {
            current.turnID = notification.turnID
        }

        switch notification {
        case .turnStarted:
            if !current.localStreamFinished {
                current.continuation.yield(.status("Codex is planning."))
            }
            activeTurn = current

        case .agentMessageDelta(_, _, let delta):
            if !current.localStreamFinished {
                current.accumulatedText += delta
                current.continuation.yield(.messageDelta(delta))
            }
            activeTurn = current

        case .agentMessageCompleted(_, _, let text):
            if !current.localStreamFinished {
                current.emittedCompletedMessage = true
                current.continuation.yield(.messageCompleted(text))
            }
            activeTurn = current

        case .turnCompleted(_, _, let status, let errorMessage):
            if current.localStreamFinished {
                // Cancellation already terminated the local consumer. The
                // completion only releases the occupied server turn slot.
            } else if status == "failed" {
                current.continuation.finish(
                    throwing: CodexAppServerTransportError.turnFailed(
                        errorMessage ?? "Codex did not provide an error message."
                    )
                )
            } else {
                if !current.emittedCompletedMessage, !current.accumulatedText.isEmpty {
                    current.continuation.yield(.messageCompleted(current.accumulatedText))
                }
                if status == "interrupted" {
                    current.continuation.yield(.status("Codex turn interrupted."))
                }
                current.continuation.yield(.turnCompleted)
                current.continuation.finish()
            }
            earlyFinishedTurnToken = current.token
            activeTurn = nil
        }
    }

    private func releaseTurnSlot(token: UUID) {
        guard let current = activeTurn, current.token == token else { return }
        if let turnID = current.turnID {
            drainingTurnIDs.insert(turnID)
        }
        activeTurn = nil
    }

    private func consumerTerminated(token: UUID) async {
        guard let current = markActiveTurnCancelling(token: token) else { return }
        guard current.turnID != nil else { return }
        do {
            try await requestTurnInterrupt(current)
        } catch {
            await tearDownConnection(with: error)
            return
        }
        // Same reasoning as interrupt(): holding the slot until the server's
        // turn/completed would fail every later send() with turnInProgress if
        // confirmation never comes.
        releaseTurnSlot(token: current.token)
    }

    private func markActiveTurnCancelling(token: UUID?) -> ActiveTurn? {
        guard var current = activeTurn else { return nil }
        if let token, current.token != token { return nil }
        guard !current.cancellationRequested else { return nil }
        current.cancellationRequested = true
        if !current.localStreamFinished {
            current.localStreamFinished = true
            current.continuation.finish(throwing: CancellationError())
        }
        activeTurn = current
        return current
    }

    private func requestTurnInterrupt(_ turn: ActiveTurn) async throws {
        guard let turnID = turn.turnID else { return }
        _ = try await request(
            method: "turn/interrupt",
            params: CodexAppServerWire.turnInterruptParams(
                threadID: turn.threadID,
                turnID: turnID
            )
        )
    }

    private func connectionEnded(with error: Error) async {
        guard !disconnecting else { return }
        let oldConnection = connection
        connection = nil
        configuration = nil
        session = nil
        readerTask = nil
        finishPendingResponses(throwing: error)
        finishActiveTurn(throwing: error)
        drainingTurnIDs.removeAll()
        earlyFinishedTurnToken = nil
        if let oldConnection {
            await oldConnection.stop()
        }
        disconnectHandler?(error.localizedDescription)
    }

    private func finishPendingResponses(throwing error: Error) {
        let responses = pendingResponses.values
        pendingResponses.removeAll()
        for response in responses {
            response.finish(throwing: error)
        }
    }

    private func finishActiveTurn(throwing error: Error) {
        let continuation = activeTurn?.continuation
        activeTurn = nil
        continuation?.finish(throwing: error)
    }

    private func tearDownConnection(with error: Error) async {
        disconnecting = true
        readerTask?.cancel()
        readerTask = nil
        finishPendingResponses(throwing: error)
        finishActiveTurn(throwing: error)
        drainingTurnIDs.removeAll()
        earlyFinishedTurnToken = nil
        let oldConnection = connection
        connection = nil
        configuration = nil
        session = nil
        if let oldConnection {
            await oldConnection.stop()
        }
        disconnecting = false
        disconnectHandler?(error.localizedDescription)
    }
}

// MARK: - Testable wire protocol

enum CodexAppServerRequestID: Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    var description: String {
        switch self {
        case .number(let value): String(value)
        case .string(let value): value
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .number(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }
}

struct CodexAppServerRPCError: Equatable, Sendable {
    let code: Int?
    let message: String
}

struct CodexAppServerEnvelope: Equatable, Sendable {
    let id: CodexAppServerRequestID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: CodexAppServerRPCError?

    var isResponse: Bool {
        id != nil && (result != nil || error != nil)
    }

    init(json: JSONValue) throws {
        guard case .object(let object) = json else {
            throw CodexAppServerTransportError.invalidResponse(
                "A JSONL record was not an object."
            )
        }

        if let rawID = object["id"] {
            switch rawID {
            case .number(let value):
                guard let integer = Int(exactly: value) else {
                    throw CodexAppServerTransportError.invalidResponse(
                        "The JSON-RPC numeric id was outside the supported integer range."
                    )
                }
                id = .number(integer)
            case .string(let value):
                id = .string(value)
            default:
                throw CodexAppServerTransportError.invalidResponse(
                    "The JSON-RPC id was neither an integer nor a string."
                )
            }
        } else {
            id = nil
        }

        method = object["method"]?.stringValue
        params = object["params"]
        result = object["result"]

        if let rawError = object["error"] {
            guard case .object(let errorObject) = rawError,
                let message = errorObject["message"]?.stringValue
            else {
                throw CodexAppServerTransportError.invalidResponse(
                    "The JSON-RPC error object did not contain a message."
                )
            }
            error = CodexAppServerRPCError(
                code: errorObject["code"]?.integerValue,
                message: message
            )
        } else {
            error = nil
        }
    }
}

struct CodexAppServerJSONLCodec: Sendable {
    func encode(_ message: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    func decode(line: String) throws -> CodexAppServerEnvelope {
        let record = line.trimmingCharacters(in: .newlines)
        guard !record.isEmpty else {
            throw CodexAppServerTransportError.invalidResponse(
                "The JSONL record was empty."
            )
        }
        guard let data = record.data(using: .utf8) else {
            throw CodexAppServerTransportError.invalidResponse(
                "The JSONL record was not valid UTF-8."
            )
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return try CodexAppServerEnvelope(json: json)
    }
}

enum CodexAppServerWire {
    static let initializeParams: JSONValue = .object([
        "clientInfo": .object([
            "name": .string("io.blacktop.Voice"),
            "title": .string("Voice"),
            "version": .string("0.1.0"),
        ])
    ])

    static let initializedNotification: JSONValue = notification(
        method: "initialized",
        params: .object([:])
    )

    static func request(
        id: CodexAppServerRequestID,
        method: String,
        params: JSONValue
    ) -> JSONValue {
        .object([
            "id": id.jsonValue,
            "method": .string(method),
            "params": params,
        ])
    }

    static func notification(method: String, params: JSONValue) -> JSONValue {
        .object([
            "method": .string(method),
            "params": params,
        ])
    }

    static func errorResponse(
        id: CodexAppServerRequestID,
        code: Int,
        message: String
    ) -> JSONValue {
        .object([
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
            "id": id.jsonValue,
        ])
    }

    static func threadStartParams(projectPath: String) -> JSONValue {
        .object([
            "approvalPolicy": .string("never"),
            "cwd": .string(projectPath),
            "sandbox": .string("read-only"),
        ])
    }

    static func threadResumeParams(threadID: String, projectPath: String) -> JSONValue {
        .object([
            "approvalPolicy": .string("never"),
            "cwd": .string(projectPath),
            "sandbox": .string("read-only"),
            "threadId": .string(threadID),
        ])
    }

    static func turnStartParams(
        threadID: String,
        prompt: String,
        projectPath: String
    ) -> JSONValue {
        .object([
            "approvalPolicy": .string("never"),
            "cwd": .string(projectPath),
            "input": .array([
                .object([
                    "text": .string(prompt),
                    "type": .string("text"),
                ])
            ]),
            "sandboxPolicy": .object([
                "networkAccess": .bool(false),
                "type": .string("readOnly"),
            ]),
            "threadId": .string(threadID),
        ])
    }

    static func turnInterruptParams(threadID: String, turnID: String) -> JSONValue {
        .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
        ])
    }
}

enum CodexAppServerNotification: Equatable, Sendable {
    case turnStarted(threadID: String, turnID: String)
    case agentMessageDelta(threadID: String, turnID: String, delta: String)
    case agentMessageCompleted(threadID: String, turnID: String, text: String)
    case turnCompleted(
        threadID: String,
        turnID: String,
        status: String,
        errorMessage: String?
    )

    var threadID: String {
        switch self {
        case .turnStarted(let threadID, _),
            .agentMessageDelta(let threadID, _, _),
            .agentMessageCompleted(let threadID, _, _),
            .turnCompleted(let threadID, _, _, _):
            threadID
        }
    }

    var turnID: String {
        switch self {
        case .turnStarted(_, let turnID),
            .agentMessageDelta(_, let turnID, _),
            .agentMessageCompleted(_, let turnID, _),
            .turnCompleted(_, let turnID, _, _):
            turnID
        }
    }
}

enum CodexAppServerNotificationExtractor {
    static func extract(from envelope: CodexAppServerEnvelope) -> CodexAppServerNotification? {
        guard envelope.id == nil,
            let method = envelope.method,
            let params = envelope.params
        else {
            return nil
        }

        switch method {
        case "turn/started":
            guard let threadID = params["threadId"]?.stringValue,
                let turnID = params["turn"]?["id"]?.stringValue
            else {
                return nil
            }
            return .turnStarted(threadID: threadID, turnID: turnID)

        case "item/agentMessage/delta":
            guard let threadID = params["threadId"]?.stringValue,
                let turnID = params["turnId"]?.stringValue,
                let delta = params["delta"]?.stringValue
            else {
                return nil
            }
            return .agentMessageDelta(
                threadID: threadID,
                turnID: turnID,
                delta: delta
            )

        case "item/completed":
            guard let threadID = params["threadId"]?.stringValue,
                let turnID = params["turnId"]?.stringValue,
                params["item"]?["type"]?.stringValue == "agentMessage",
                let text = params["item"]?["text"]?.stringValue
            else {
                return nil
            }
            return .agentMessageCompleted(
                threadID: threadID,
                turnID: turnID,
                text: text
            )

        case "turn/completed":
            guard let threadID = params["threadId"]?.stringValue,
                let turnID = params["turn"]?["id"]?.stringValue,
                let status = params["turn"]?["status"]?.stringValue
            else {
                return nil
            }
            return .turnCompleted(
                threadID: threadID,
                turnID: turnID,
                status: status,
                errorMessage: params["turn"]?["error"]?["message"]?.stringValue
            )

        default:
            return nil
        }
    }
}

// MARK: - Process connection

protocol CodexAppServerConnection: Sendable {
    func start(
        executableURL: URL,
        currentDirectoryURL: URL
    ) async throws -> AsyncThrowingStream<CodexAppServerEnvelope, Error>

    func send(_ message: JSONValue) async throws
    func stop() async
}

actor CodexAppServerProcessConnection: CodexAppServerConnection {
    private let codec = CodexAppServerJSONLCodec()
    private let writeQueue = DispatchQueue(label: "io.blacktop.Voice.codex-stdin")
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputContinuation:
        AsyncThrowingStream<
            CodexAppServerEnvelope,
            Error
        >.Continuation?
    private var process: Process?
    private var readerTask: Task<Void, Never>?

    func start(
        executableURL: URL,
        currentDirectoryURL: URL
    ) throws -> AsyncThrowingStream<CodexAppServerEnvelope, Error> {
        guard process == nil else {
            throw CodexAppServerTransportError.invalidConfiguration(
                "This app-server connection has already been started."
            )
        }

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ChildProcessEnvironment.privacyPreserving
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let pair = AsyncThrowingStream<CodexAppServerEnvelope, Error>.makeStream()
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        outputContinuation = pair.continuation
        self.process = process
        // A write after the child dies must fail with EPIPE instead of raising
        // SIGPIPE, whose default action kills the entire app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
        } catch {
            inputHandle = nil
            outputHandle = nil
            outputContinuation = nil
            self.process = nil
            pair.continuation.finish(throwing: error)
            throw error
        }

        readerTask = Task { [weak self] in
            await self?.readOutput()
        }
        return pair.stream
    }

    func send(_ message: JSONValue) async throws {
        guard let inputHandle,
            let process,
            process.isRunning
        else {
            throw CodexAppServerTransportError.connectionClosed
        }
        let data = try codec.encode(message)
        // A blocking write(2) on this actor would starve readOutput() (the
        // two-pipe deadlock with a wedged child) and make stop() unreachable.
        // Writing on a plain queue keeps the actor responsive; stop() can then
        // kill the child, which unblocks the write with EPIPE.
        let descriptor = inputHandle.fileDescriptor
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try Self.writeFully(data, to: descriptor)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func writeFully(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw CodexAppServerTransportError.connectionClosed
                }
                base += written
                remaining -= written
            }
        }
    }

    func stop() async {
        readerTask?.cancel()
        readerTask = nil
        try? inputHandle?.close()
        inputHandle = nil

        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<10 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process = nil

        try? outputHandle?.close()
        outputHandle = nil
        outputContinuation?.finish()
        outputContinuation = nil
    }

    private func readOutput() async {
        guard let outputHandle, let outputContinuation else { return }

        do {
            for try await line in outputHandle.bytes.lines {
                try Task.checkCancellation()
                // A stray non-JSON-RPC stdout line (banner, runtime warning)
                // must not tear down the connection and every pending request.
                guard let envelope = try? codec.decode(line: line) else { continue }
                outputContinuation.yield(envelope)
            }
            outputContinuation.finish()
        } catch is CancellationError {
            outputContinuation.finish()
        } catch {
            outputContinuation.finish(throwing: error)
        }
    }
}

extension JSONValue {
    fileprivate var integerValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }
}
