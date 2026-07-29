import Darwin
import Foundation
import VoiceCore

/// Errors produced while driving an Agent Client Protocol v1 process.
public enum ACPAgentTransportError: LocalizedError, Sendable {
    case authenticationFailed(String)
    case authenticationUnavailable
    case connectionClosed
    case invalidConfiguration(String)
    case invalidResponse(String)
    case notConnected
    case processLaunch(String)
    case serverError(code: Int?, message: String)
    case sessionLoadingUnsupported
    case sessionNotStarted
    case turnInProgress

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            "ACP agent authentication failed: \(reason)"
        case .authenticationUnavailable:
            "The ACP agent requires authentication but did not advertise a supported login method."
        case .connectionClosed:
            "The ACP connection closed unexpectedly."
        case .invalidConfiguration(let reason):
            "The ACP configuration is invalid: \(reason)"
        case .invalidResponse(let reason):
            "The ACP agent returned an invalid response: \(reason)"
        case .notConnected:
            "The ACP agent is not connected."
        case .processLaunch(let reason):
            "The ACP agent could not be launched: \(reason)"
        case .serverError(let code, let message):
            if let code {
                "ACP agent error \(code): \(message)"
            } else {
                "ACP agent error: \(message)"
            }
        case .sessionLoadingUnsupported:
            "The ACP agent does not support loading an existing session."
        case .sessionNotStarted:
            "Start or load an ACP session before sending a prompt."
        case .turnInProgress:
            "An ACP prompt turn is already in progress."
        }
    }
}

/// A local ACP v1 client over newline-delimited JSON-RPC 2.0 on stdio.
///
/// The executable is launched directly with `Process`; no shell is involved.
/// Voice advertises terminal-style authentication, but no filesystem, terminal
/// tool, or MCP capabilities, and never authorizes a permission request. An ACP
/// agent remains responsible for enforcing its own sandbox for operations it
/// performs without asking.
public actor ACPAgentTransport: AgentTransport {
    private struct ActivePrompt {
        let token: UUID
        let sessionID: String
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        var accumulatedText = ""
        var cancellationRequested = false
    }

    typealias ConnectionFactory = @Sendable () -> any ACPAgentConnection
    typealias AuthenticationRunner =
        @Sendable (AgentConfiguration, ACPAuthenticationMethod) async throws -> Void

    private let authenticationRunner: AuthenticationRunner
    private let connectionFactory: ConnectionFactory
    private var activePrompt: ActivePrompt?
    private var authenticationAttempted = false
    private var authenticationMethods: [ACPAuthenticationMethod] = []
    private var authenticationTask: Task<Void, Error>?
    private var authenticationTaskToken: UUID?
    private var configuration: AgentConfiguration?
    private var connection: (any ACPAgentConnection)?
    private var connectionGeneration: UUID?
    private var disconnectHandler: (@Sendable (String) -> Void)?
    private var disconnecting = false
    private var loadSessionSupported = false
    private var nextRequestID = 0
    private var pendingResponses:
        [ACPRequestID: AsyncThrowingStream<JSONValue, Error>.Continuation] =
            [:]
    private var promptTask: Task<Void, Never>?
    private var cancellationTimeoutTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var session: AgentSession?
    private var sessionConfigurationHandler:
        (@Sendable ([AgentSessionConfigurationOption]) -> Void)?

    public init() {
        authenticationRunner = Self.runAuthentication
        connectionFactory = { ACPProcessConnection() }
    }

    init(connectionFactory: @escaping ConnectionFactory) {
        authenticationRunner = Self.runAuthentication
        self.connectionFactory = connectionFactory
    }

    init(
        connectionFactory: @escaping ConnectionFactory,
        authenticationRunner: @escaping AuthenticationRunner
    ) {
        self.authenticationRunner = authenticationRunner
        self.connectionFactory = connectionFactory
    }

    public func connect(_ configuration: AgentConfiguration) async throws {
        await disconnect()
        try Self.validate(configuration)

        let newConnection = connectionFactory()
        let messages: AsyncThrowingStream<ACPEnvelope, Error>
        do {
            messages = try await newConnection.start(
                executableURL: configuration.executableURL.standardizedFileURL,
                arguments: configuration.arguments,
                currentDirectoryURL: configuration.projectURL.standardizedFileURL
            )
        } catch {
            throw ACPAgentTransportError.processLaunch(error.localizedDescription)
        }

        self.configuration = configuration
        connection = newConnection
        connectionGeneration = UUID()
        disconnecting = false
        authenticationAttempted = false
        authenticationMethods = []
        loadSessionSupported = false
        nextRequestID = 0
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(messages)
        }

        do {
            let result = try await request(
                method: "initialize",
                params: ACPWire.initializeParams
            )
            let capabilities = try ACPInitializeResult(result: result)
            authenticationMethods = capabilities.authenticationMethods
            loadSessionSupported = capabilities.loadSessionSupported
        } catch {
            // A send failure inside request() already ran connectionEnded
            // (handler fired, connection cleared); tearing down again would
            // report the same disconnect twice.
            if connection != nil {
                await tearDownConnection(with: error)
            }
            throw error
        }
    }

    public func startOrResume(sessionID: String?) async throws -> AgentSession {
        guard connection != nil, let generation = connectionGeneration else {
            throw ACPAgentTransportError.notConnected
        }
        guard let configuration else {
            throw ACPAgentTransportError.invalidConfiguration(
                "The project directory is unavailable."
            )
        }
        guard activePrompt == nil else {
            throw ACPAgentTransportError.turnInProgress
        }

        let projectPath = configuration.projectURL.standardizedFileURL.path
        if let sessionID, !sessionID.isEmpty {
            guard loadSessionSupported else {
                throw ACPAgentTransportError.sessionLoadingUnsupported
            }
            let result = try await requestWithAuthenticationRetry(
                method: "session/load",
                params: ACPWire.sessionLoadParams(
                    sessionID: sessionID,
                    projectPath: projectPath
                )
            )
            try ensureConnectionGeneration(generation)
            let initialOptions = try ACPSessionConfigurationParser.options(from: result)
            let options = try await applyPreferredSessionConfiguration(
                to: initialOptions,
                sessionID: sessionID,
                generation: generation
            )
            try ensureConnectionGeneration(generation)
            let session = AgentSession(
                id: sessionID,
                configurationOptions: options
            )
            self.session = session
            return session
        }

        let result = try await requestWithAuthenticationRetry(
            method: "session/new",
            params: ACPWire.sessionNewParams(projectPath: projectPath)
        )
        try ensureConnectionGeneration(generation)
        guard let sessionID = result["sessionId"]?.stringValue,
            !sessionID.isEmpty
        else {
            throw ACPAgentTransportError.invalidResponse(
                "session/new did not contain result.sessionId."
            )
        }

        let initialOptions = try ACPSessionConfigurationParser.options(from: result)
        let options = try await applyPreferredSessionConfiguration(
            to: initialOptions,
            sessionID: sessionID,
            generation: generation
        )
        try ensureConnectionGeneration(generation)
        let session = AgentSession(
            id: sessionID,
            configurationOptions: options
        )
        self.session = session
        return session
    }

    public func send(_ prompt: String) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard connection != nil else {
            throw ACPAgentTransportError.notConnected
        }
        guard let session else {
            throw ACPAgentTransportError.sessionNotStarted
        }
        guard activePrompt == nil else {
            throw ACPAgentTransportError.turnInProgress
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ACPAgentTransportError.invalidConfiguration("The prompt is empty.")
        }

        let token = UUID()
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.consumerCancelled(token: token)
            }
        }
        activePrompt = ActivePrompt(
            token: token,
            sessionID: session.id,
            continuation: pair.continuation
        )
        pair.continuation.yield(.connected)
        pair.continuation.yield(.status("ACP agent is planning."))

        promptTask = Task { [weak self] in
            guard let self else { return }
            await self.performPrompt(prompt, sessionID: session.id, token: token)
        }
        return pair.stream
    }

    public func interrupt() async {
        await cancelActivePrompt()
    }

    public func setDisconnectHandler(_ handler: (@Sendable (String) -> Void)?) async {
        disconnectHandler = handler
    }

    public func setSessionConfigurationHandler(
        _ handler: (@Sendable ([AgentSessionConfigurationOption]) -> Void)?
    ) async {
        sessionConfigurationHandler = handler
    }

    public func setSessionConfiguration(
        id: String,
        value: AgentSessionConfigurationValue
    ) async throws -> [AgentSessionConfigurationOption] {
        guard let session else {
            throw ACPAgentTransportError.sessionNotStarted
        }
        guard let option = session.configurationOptions.first(where: { $0.id == id }),
            option.accepts(value)
        else {
            throw ACPAgentTransportError.invalidConfiguration(
                "The selected session configuration value is unavailable."
            )
        }
        let generation = connectionGeneration
        let options = try await requestSessionConfigurationChange(
            sessionID: session.id,
            configID: id,
            value: value
        )
        guard generation == connectionGeneration,
            self.session?.id == session.id
        else {
            throw CancellationError()
        }
        self.session = AgentSession(
            id: session.id,
            configurationOptions: options
        )
        return options
    }

    public func disconnect() async {
        disconnecting = true
        readerTask?.cancel()
        readerTask = nil
        promptTask?.cancel()
        promptTask = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationTaskToken = nil
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil

        let cancellation = CancellationError()
        finishPendingResponses(throwing: cancellation)
        finishActivePrompt(throwing: cancellation)

        let oldConnection = connection
        connection = nil
        connectionGeneration = nil
        configuration = nil
        authenticationAttempted = false
        authenticationMethods = []
        loadSessionSupported = false
        session = nil
        if let oldConnection {
            await oldConnection.stop()
        }
        disconnecting = false
    }

    private static func validate(_ configuration: AgentConfiguration) throws {
        let executablePath = configuration.executableURL.standardizedFileURL.path
        guard configuration.executableURL.isFileURL,
            executablePath.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw ACPAgentTransportError.invalidConfiguration(
                "Choose an absolute, executable ACP agent path."
            )
        }

        var isDirectory: ObjCBool = false
        let projectPath = configuration.projectURL.standardizedFileURL.path
        guard configuration.projectURL.isFileURL,
            FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ACPAgentTransportError.invalidConfiguration(
                "Choose an existing project directory."
            )
        }
    }

    private static func runAuthentication(
        configuration: AgentConfiguration,
        method: ACPAuthenticationMethod
    ) async throws {
        let runner = ACPProcessAuthenticationRunner()
        try await runner.run(configuration: configuration, method: method)
    }

    private func applyPreferredSessionConfiguration(
        to initialOptions: [AgentSessionConfigurationOption],
        sessionID: String,
        generation: UUID
    ) async throws -> [AgentSessionConfigurationOption] {
        guard let configuration,
            !configuration.sessionConfigurationValues.isEmpty
        else {
            return initialOptions
        }

        var options = initialOptions
        var processedIDs: Set<String> = []
        while let option = options.first(where: {
            !processedIDs.contains($0.id)
                && configuration.sessionConfigurationValues[$0.id] != nil
        }) {
            processedIDs.insert(option.id)
            guard let preferredValue = configuration.sessionConfigurationValues[option.id],
                preferredValue != option.currentValue,
                option.accepts(preferredValue)
            else {
                continue
            }
            try ensureConnectionGeneration(generation)
            options = try await requestSessionConfigurationChange(
                sessionID: sessionID,
                configID: option.id,
                value: preferredValue
            )
            try ensureConnectionGeneration(generation)
        }
        return options
    }

    private func ensureConnectionGeneration(_ generation: UUID) throws {
        guard generation == connectionGeneration, connection != nil else {
            throw CancellationError()
        }
    }

    private func requestSessionConfigurationChange(
        sessionID: String,
        configID: String,
        value: AgentSessionConfigurationValue
    ) async throws -> [AgentSessionConfigurationOption] {
        let result = try await requestWithAuthenticationRetry(
            method: "session/set_config_option",
            params: ACPWire.sessionConfigurationParams(
                sessionID: sessionID,
                configID: configID,
                value: value
            )
        )
        return try ACPSessionConfigurationParser.options(
            from: result,
            required: true
        )
    }

    private func requestWithAuthenticationRetry(
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        do {
            return try await request(method: method, params: params)
        } catch {
            guard Self.isAuthenticationRequired(error) else { throw error }
            try await authenticateCurrentConnection()
            return try await request(method: method, params: params)
        }
    }

    private static func isAuthenticationRequired(_ error: Error) -> Bool {
        guard let transportError = error as? ACPAgentTransportError,
            case .serverError(let code, let message) = transportError
        else {
            return false
        }
        return code == -32_000
            && message.localizedCaseInsensitiveContains("authentication required")
    }

    private func authenticateCurrentConnection() async throws {
        guard !authenticationAttempted else {
            throw ACPAgentTransportError.authenticationFailed(
                "The agent still rejected the request after its login flow completed."
            )
        }
        guard let method = authenticationMethods.first(where: { $0.type == "terminal" }) else {
            throw ACPAgentTransportError.authenticationUnavailable
        }
        guard let configuration,
            let generation = connectionGeneration,
            connection != nil
        else {
            throw ACPAgentTransportError.notConnected
        }

        authenticationAttempted = true
        let authenticationToken = UUID()
        let authenticationRunner = self.authenticationRunner
        let task = Task {
            try await authenticationRunner(configuration, method)
        }
        authenticationTask = task
        authenticationTaskToken = authenticationToken
        defer {
            if authenticationTaskToken == authenticationToken {
                authenticationTask = nil
                authenticationTaskToken = nil
            }
        }
        do {
            try await task.value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ACPAgentTransportError {
            throw error
        } catch {
            throw ACPAgentTransportError.authenticationFailed(error.localizedDescription)
        }

        try ensureConnectionGeneration(generation)
        _ = try await request(
            method: "authenticate",
            params: ACPWire.authenticationParams(methodID: method.id)
        )
        try ensureConnectionGeneration(generation)
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard let connection else {
            throw ACPAgentTransportError.notConnected
        }

        let maximumSafeInteger = 9_007_199_254_740_991
        guard nextRequestID <= maximumSafeInteger else {
            throw ACPAgentTransportError.invalidResponse(
                "The JSON-RPC request id space was exhausted."
            )
        }
        let id = ACPRequestID.number(nextRequestID)
        nextRequestID += 1
        let pair = AsyncThrowingStream<JSONValue, Error>.makeStream()
        pendingResponses[id] = pair.continuation

        do {
            try await connection.send(
                ACPWire.request(id: id, method: method, params: params)
            )
        } catch {
            pendingResponses.removeValue(forKey: id)
            pair.continuation.finish(throwing: error)
            // This path owns the reader task as well as the process. Cancelling
            // it before stop() closes the output stream prevents consume() from
            // reporting the same launch failure a second time.
            await tearDownConnection(with: error)
            throw error
        }

        var iterator = pair.stream.makeAsyncIterator()
        guard let result = try await iterator.next() else {
            throw ACPAgentTransportError.connectionClosed
        }
        return result
    }

    private func performPrompt(_ prompt: String, sessionID: String, token: UUID) async {
        do {
            let result = try await requestWithAuthenticationRetry(
                method: "session/prompt",
                params: ACPWire.sessionPromptParams(sessionID: sessionID, prompt: prompt)
            )
            let stopReason = try ACPStopReason(result: result)
            completePrompt(token: token, stopReason: stopReason)
        } catch {
            guard activePrompt?.token == token else { return }
            finishActivePrompt(throwing: error)
        }
    }

    private func consume(_ messages: AsyncThrowingStream<ACPEnvelope, Error>) async {
        do {
            for try await message in messages {
                if Task.isCancelled { return }
                await receive(message)
            }
            if !Task.isCancelled {
                await connectionEnded(with: ACPAgentTransportError.connectionClosed)
            }
        } catch is CancellationError {
            // An intentional disconnect owns cleanup.
        } catch {
            if !Task.isCancelled {
                await connectionEnded(with: error)
            }
        }
    }

    private func receive(_ envelope: ACPEnvelope) async {
        if let id = envelope.id, envelope.isResponse {
            resolveResponse(id: id, envelope: envelope)
            return
        }

        if let id = envelope.id, let method = envelope.method, let connection {
            let response: JSONValue
            if method == "session/request_permission" {
                response = ACPWire.cancelledPermissionResponse(id: id)
            } else {
                response = ACPWire.errorResponse(
                    id: id,
                    code: -32601,
                    message: "Method not found"
                )
            }
            do {
                try await connection.send(response)
            } catch {
                await connectionEnded(with: error)
            }
            return
        }

        do {
            if let update = try ACPSessionConfigurationParser.update(from: envelope) {
                guard let session, session.id == update.sessionID else { return }
                self.session = AgentSession(
                    id: session.id,
                    configurationOptions: update.options
                )
                sessionConfigurationHandler?(update.options)
                return
            }
        } catch {
            await connectionEnded(with: error)
            return
        }

        guard let update = ACPSessionUpdateExtractor.extract(from: envelope),
            var current = activePrompt,
            current.sessionID == update.sessionID
        else {
            return
        }
        current.accumulatedText += update.text
        current.continuation.yield(.messageDelta(update.text))
        activePrompt = current
    }

    private func resolveResponse(id: ACPRequestID, envelope: ACPEnvelope) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }

        if let error = envelope.error {
            continuation.finish(
                throwing: ACPAgentTransportError.serverError(
                    code: error.code,
                    message: error.message
                )
            )
        } else if let result = envelope.result {
            continuation.yield(result)
            continuation.finish()
        } else {
            continuation.finish(
                throwing: ACPAgentTransportError.invalidResponse(
                    "Response \(id.description) contained neither result nor error."
                )
            )
        }
    }

    private func completePrompt(token: UUID, stopReason: ACPStopReason) {
        guard let current = activePrompt, current.token == token else { return }

        if !current.accumulatedText.isEmpty {
            current.continuation.yield(.messageCompleted(current.accumulatedText))
        }
        if let status = stopReason.statusMessage {
            current.continuation.yield(.status(status))
        }
        current.continuation.yield(.turnCompleted)
        current.continuation.finish()
        activePrompt = nil
        promptTask = nil
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
    }

    private func consumerCancelled(token: UUID) async {
        guard let current = activePrompt, current.token == token else { return }
        await cancelActivePrompt()
    }

    private func cancelActivePrompt() async {
        guard var current = activePrompt, !current.cancellationRequested else { return }
        current.cancellationRequested = true
        current.continuation.yield(.status("Cancelling ACP agent turn."))
        current.continuation.finish(throwing: CancellationError())
        // ACP session/update notifications carry no turn discriminator, so a
        // new prompt must not overlap the cancelled one: the slot stays held
        // until the agent answers the outstanding session/prompt. The timeout
        // below bounds how long a hung agent can wedge the transport.
        activePrompt = current

        do {
            try await sendCancellation(sessionID: current.sessionID)
        } catch {
            await connectionEnded(with: error)
            return
        }
        let token = current.token
        cancellationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.abandonUnacknowledgedCancellation(token: token)
        }
    }

    private func abandonUnacknowledgedCancellation(token: UUID) async {
        guard let current = activePrompt,
            current.token == token,
            current.cancellationRequested
        else {
            return
        }
        await tearDownConnection(
            with: ACPAgentTransportError.invalidResponse(
                "The agent did not answer the cancelled session/prompt request."
            )
        )
    }

    private func sendCancellation(sessionID: String) async throws {
        guard let connection else {
            throw ACPAgentTransportError.notConnected
        }
        try await connection.send(ACPWire.sessionCancelNotification(sessionID: sessionID))
    }

    private func connectionEnded(with error: Error) async {
        await tearDownConnection(with: error)
    }

    private func finishPendingResponses(throwing error: Error) {
        let responses = pendingResponses.values
        pendingResponses.removeAll()
        for response in responses {
            response.finish(throwing: error)
        }
    }

    private func finishActivePrompt(throwing error: Error) {
        let continuation = activePrompt?.continuation
        activePrompt = nil
        promptTask?.cancel()
        promptTask = nil
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        continuation?.finish(throwing: error)
    }

    private func tearDownConnection(with error: Error) async {
        guard !disconnecting, connection != nil else { return }
        disconnecting = true
        readerTask?.cancel()
        readerTask = nil
        promptTask?.cancel()
        promptTask = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationTaskToken = nil
        finishPendingResponses(throwing: error)
        finishActivePrompt(throwing: error)
        let oldConnection = connection
        connection = nil
        connectionGeneration = nil
        configuration = nil
        authenticationAttempted = false
        authenticationMethods = []
        loadSessionSupported = false
        session = nil
        if let oldConnection {
            await oldConnection.stop()
        }
        disconnecting = false
        disconnectHandler?(error.localizedDescription)
    }
}

// MARK: - Testable ACP v1 wire protocol

enum ACPRequestID: Hashable, Sendable, CustomStringConvertible {
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

struct ACPRPCError: Equatable, Sendable {
    let code: Int?
    let message: String
}

struct ACPEnvelope: Equatable, Sendable {
    let id: ACPRequestID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: ACPRPCError?

    var isResponse: Bool {
        id != nil && (result != nil || error != nil)
    }

    init(json: JSONValue) throws {
        guard case .object(let object) = json else {
            throw ACPAgentTransportError.invalidResponse(
                "A JSONL record was not an object."
            )
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            throw ACPAgentTransportError.invalidResponse(
                "A JSONL record did not declare JSON-RPC 2.0."
            )
        }

        if let rawID = object["id"] {
            switch rawID {
            case .number(let value):
                let maximumSafeInteger = 9_007_199_254_740_991.0
                guard value >= -maximumSafeInteger,
                    value <= maximumSafeInteger,
                    let integer = Int(exactly: value)
                else {
                    throw ACPAgentTransportError.invalidResponse(
                        "The JSON-RPC numeric id was outside the safe integer range."
                    )
                }
                id = .number(integer)
            case .string(let value):
                id = .string(value)
            default:
                throw ACPAgentTransportError.invalidResponse(
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
                throw ACPAgentTransportError.invalidResponse(
                    "The JSON-RPC error object did not contain a message."
                )
            }
            error = ACPRPCError(
                code: Self.integer(from: errorObject["code"]),
                message: message
            )
        } else {
            error = nil
        }
    }

    private static func integer(from value: JSONValue?) -> Int? {
        guard case .number(let number) = value else { return nil }
        return Int(exactly: number)
    }
}

struct ACPJSONLCodec: Sendable {
    func encode(_ message: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    func decode(line: String) throws -> ACPEnvelope {
        let record = line.trimmingCharacters(in: .newlines)
        guard !record.isEmpty else {
            throw ACPAgentTransportError.invalidResponse("The JSONL record was empty.")
        }
        guard let data = record.data(using: .utf8) else {
            throw ACPAgentTransportError.invalidResponse(
                "The JSONL record was not valid UTF-8."
            )
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return try ACPEnvelope(json: json)
    }
}

enum ACPWire {
    static let initializeParams: JSONValue = .object([
        "clientCapabilities": .object([
            "auth": .object([
                "terminal": .bool(true)
            ]),
            "session": .object([
                "configOptions": .object([
                    "boolean": .object([:])
                ])
            ]),
        ]),
        "clientInfo": .object([
            "name": .string("io.blacktop.Voice"),
            "title": .string("Voice"),
            "version": .string("0.1.0"),
        ]),
        "protocolVersion": .number(1),
    ])

    static func request(id: ACPRequestID, method: String, params: JSONValue) -> JSONValue {
        .object([
            "id": id.jsonValue,
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
    }

    static func notification(method: String, params: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
    }

    static func resultResponse(id: ACPRequestID, result: JSONValue) -> JSONValue {
        .object([
            "id": id.jsonValue,
            "jsonrpc": .string("2.0"),
            "result": result,
        ])
    }

    static func errorResponse(
        id: ACPRequestID,
        code: Int,
        message: String
    ) -> JSONValue {
        .object([
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
            "id": id.jsonValue,
            "jsonrpc": .string("2.0"),
        ])
    }

    static func cancelledPermissionResponse(id: ACPRequestID) -> JSONValue {
        resultResponse(
            id: id,
            result: .object([
                "outcome": .object([
                    "outcome": .string("cancelled")
                ])
            ])
        )
    }

    static func sessionNewParams(projectPath: String) -> JSONValue {
        .object([
            "cwd": .string(projectPath),
            "mcpServers": .array([]),
        ])
    }

    static func sessionLoadParams(sessionID: String, projectPath: String) -> JSONValue {
        .object([
            "cwd": .string(projectPath),
            "mcpServers": .array([]),
            "sessionId": .string(sessionID),
        ])
    }

    static func sessionPromptParams(sessionID: String, prompt: String) -> JSONValue {
        .object([
            "prompt": .array([
                .object([
                    "text": .string(prompt),
                    "type": .string("text"),
                ])
            ]),
            "sessionId": .string(sessionID),
        ])
    }

    static func sessionConfigurationParams(
        sessionID: String,
        configID: String,
        value: AgentSessionConfigurationValue
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "configId": .string(configID),
            "sessionId": .string(sessionID),
        ]
        switch value {
        case .boolean(let enabled):
            params["type"] = .string("boolean")
            params["value"] = .bool(enabled)
        case .string(let identifier):
            params["type"] = .string("id")
            params["value"] = .string(identifier)
        }
        return .object(params)
    }

    static func authenticationParams(methodID: String) -> JSONValue {
        .object(["methodId": .string(methodID)])
    }

    static func sessionCancelNotification(sessionID: String) -> JSONValue {
        notification(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        )
    }
}

struct ACPAuthenticationMethod: Equatable, Sendable {
    let arguments: [String]
    let environment: [String: String]
    let id: String
    let name: String
    let type: String

    init(json: JSONValue) throws {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
            let name = json["name"]?.stringValue, !name.isEmpty
        else {
            throw ACPAgentTransportError.invalidResponse(
                "An advertised authentication method did not contain an id and name."
            )
        }

        let type = json["type"]?.stringValue ?? "agent"
        let arguments: [String]
        if let rawArguments = json["args"] {
            guard case .array(let values) = rawArguments else {
                throw ACPAgentTransportError.invalidResponse(
                    "Authentication method \(id) contained invalid arguments."
                )
            }
            arguments = try values.map { value in
                guard let argument = value.stringValue else {
                    throw ACPAgentTransportError.invalidResponse(
                        "Authentication method \(id) contained a non-string argument."
                    )
                }
                return argument
            }
        } else {
            arguments = []
        }

        let environment: [String: String]
        if let rawEnvironment = json["env"] {
            guard case .object(let values) = rawEnvironment else {
                throw ACPAgentTransportError.invalidResponse(
                    "Authentication method \(id) contained an invalid environment."
                )
            }
            environment = try values.reduce(into: [:]) { result, entry in
                guard let value = entry.value.stringValue else {
                    throw ACPAgentTransportError.invalidResponse(
                        "Authentication method \(id) contained a non-string environment value."
                    )
                }
                result[entry.key] = value
            }
        } else {
            environment = [:]
        }

        self.arguments = arguments
        self.environment = environment
        self.id = id
        self.name = name
        self.type = type
    }
}

struct ACPInitializeResult: Equatable, Sendable {
    let authenticationMethods: [ACPAuthenticationMethod]
    let loadSessionSupported: Bool

    init(result: JSONValue) throws {
        guard case .number(let version) = result["protocolVersion"], version == 1 else {
            throw ACPAgentTransportError.invalidResponse(
                "The agent did not negotiate ACP protocol version 1."
            )
        }
        if case .bool(let supported) = result["agentCapabilities"]?["loadSession"] {
            loadSessionSupported = supported
        } else {
            loadSessionSupported = false
        }

        if let rawMethods = result["authMethods"] {
            guard case .array(let methods) = rawMethods else {
                throw ACPAgentTransportError.invalidResponse(
                    "The agent returned invalid authentication methods."
                )
            }
            authenticationMethods = try methods.map(ACPAuthenticationMethod.init(json:))
        } else {
            authenticationMethods = []
        }
    }
}

struct ACPSessionConfigurationUpdate: Equatable, Sendable {
    let sessionID: String
    let options: [AgentSessionConfigurationOption]
}

enum ACPSessionConfigurationParser {
    static func options(
        from result: JSONValue,
        required: Bool = false
    ) throws -> [AgentSessionConfigurationOption] {
        guard let rawOptions = result["configOptions"] else {
            if required {
                throw ACPAgentTransportError.invalidResponse(
                    "session/set_config_option did not return configOptions."
                )
            }
            return []
        }
        return try options(from: rawOptions)
    }

    static func update(from envelope: ACPEnvelope) throws -> ACPSessionConfigurationUpdate? {
        guard envelope.id == nil,
            envelope.method == "session/update",
            envelope.params?["update"]?["sessionUpdate"]?.stringValue
                == "config_option_update"
        else {
            return nil
        }
        guard let sessionID = envelope.params?["sessionId"]?.stringValue,
            !sessionID.isEmpty,
            let rawOptions = envelope.params?["update"]?["configOptions"]
        else {
            throw ACPAgentTransportError.invalidResponse(
                "A config_option_update did not contain a session and configOptions."
            )
        }
        return ACPSessionConfigurationUpdate(
            sessionID: sessionID,
            options: try options(from: rawOptions)
        )
    }

    private static func options(
        from rawOptions: JSONValue
    ) throws -> [AgentSessionConfigurationOption] {
        guard case .array(let values) = rawOptions else {
            throw ACPAgentTransportError.invalidResponse(
                "Session configOptions was not an array."
            )
        }
        var parsed: [AgentSessionConfigurationOption] = []
        var optionIDs: Set<String> = []
        for value in values {
            guard let option = try option(from: value) else { continue }
            guard optionIDs.insert(option.id).inserted else {
                throw ACPAgentTransportError.invalidResponse(
                    "Session configOptions contained duplicate id \(option.id)."
                )
            }
            parsed.append(option)
        }
        return parsed
    }

    private static func option(
        from value: JSONValue
    ) throws -> AgentSessionConfigurationOption? {
        guard let rawType = value["type"]?.stringValue else {
            throw ACPAgentTransportError.invalidResponse(
                "A session configuration option did not contain a type."
            )
        }
        guard let kind = AgentSessionConfigurationOption.Kind(rawValue: rawType) else {
            return nil
        }
        guard let id = value["id"]?.stringValue, !id.isEmpty,
            let name = value["name"]?.stringValue, !name.isEmpty
        else {
            throw ACPAgentTransportError.invalidResponse(
                "A session configuration option did not contain an id and name."
            )
        }
        let description = try optionalString("description", from: value)
        let category = try optionalString("category", from: value)

        switch kind {
        case .boolean:
            guard case .bool(let currentValue) = value["currentValue"] else {
                throw ACPAgentTransportError.invalidResponse(
                    "Boolean session configuration \(id) did not contain a boolean value."
                )
            }
            return AgentSessionConfigurationOption(
                id: id,
                name: name,
                description: description,
                category: category,
                kind: .boolean,
                currentValue: .boolean(currentValue)
            )
        case .select:
            guard let currentValue = value["currentValue"]?.stringValue,
                let rawChoices = value["options"],
                case .array(let choiceValues) = rawChoices
            else {
                throw ACPAgentTransportError.invalidResponse(
                    "Select session configuration \(id) did not contain a value and options."
                )
            }
            var choiceIDs: Set<String> = []
            let choices = try choiceValues.map { choiceValue in
                guard let choiceID = choiceValue["value"]?.stringValue,
                    !choiceID.isEmpty,
                    let choiceName = choiceValue["name"]?.stringValue,
                    !choiceName.isEmpty
                else {
                    throw ACPAgentTransportError.invalidResponse(
                        "Select session configuration \(id) contained an invalid choice."
                    )
                }
                guard choiceIDs.insert(choiceID).inserted else {
                    throw ACPAgentTransportError.invalidResponse(
                        "Select session configuration \(id) contained duplicate choice \(choiceID)."
                    )
                }
                return AgentSessionConfigurationChoice(
                    value: choiceID,
                    name: choiceName,
                    description: try optionalString("description", from: choiceValue)
                )
            }
            return AgentSessionConfigurationOption(
                id: id,
                name: name,
                description: description,
                category: category,
                kind: .select,
                currentValue: .string(currentValue),
                choices: choices
            )
        }
    }

    private static func optionalString(
        _ key: String,
        from value: JSONValue
    ) throws -> String? {
        guard let rawValue = value[key] else { return nil }
        if case .null = rawValue { return nil }
        guard let string = rawValue.stringValue else {
            throw ACPAgentTransportError.invalidResponse(
                "Session configuration field \(key) was not a string."
            )
        }
        return string
    }
}

enum ACPStopReason: String, Equatable, Sendable {
    case cancelled
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal

    init(result: JSONValue) throws {
        guard let value = result["stopReason"]?.stringValue,
            let reason = Self(rawValue: value)
        else {
            throw ACPAgentTransportError.invalidResponse(
                "session/prompt did not contain a recognized result.stopReason."
            )
        }
        self = reason
    }

    var statusMessage: String? {
        switch self {
        case .endTurn:
            nil
        case .cancelled:
            "ACP agent turn cancelled."
        case .maxTokens:
            "ACP agent stopped at its token limit."
        case .maxTurnRequests:
            "ACP agent stopped at its turn-request limit."
        case .refusal:
            "ACP agent declined the request."
        }
    }
}

struct ACPSessionTextUpdate: Equatable, Sendable {
    let sessionID: String
    let text: String
}

enum ACPSessionUpdateExtractor {
    static func extract(from envelope: ACPEnvelope) -> ACPSessionTextUpdate? {
        guard envelope.id == nil,
            envelope.method == "session/update",
            let params = envelope.params,
            let sessionID = params["sessionId"]?.stringValue,
            params["update"]?["sessionUpdate"]?.stringValue == "agent_message_chunk",
            params["update"]?["content"]?["type"]?.stringValue == "text",
            let text = params["update"]?["content"]?["text"]?.stringValue
        else {
            return nil
        }
        return ACPSessionTextUpdate(sessionID: sessionID, text: text)
    }
}

enum ACPTerminalAuthenticationScript {
    static func contents(
        configuration: AgentConfiguration,
        method: ACPAuthenticationMethod,
        statusURL: URL
    ) -> String {
        let environment = ChildProcessEnvironment.privacyPreserving.merging(
            method.environment,
            uniquingKeysWith: { _, advertisedValue in advertisedValue }
        )
        let environmentArguments =
            environment
            .sorted { $0.key < $1.key }
            .map { shellQuote("\($0.key)=\($0.value)") }
        let commandArguments =
            [configuration.executableURL.standardizedFileURL.path]
            + configuration.arguments + method.arguments
        let command =
            (["/usr/bin/env", "-i"] + environmentArguments
            + commandArguments.map(shellQuote))
            .joined(separator: " ")
        let temporaryStatusURL = statusURL.appendingPathExtension("tmp")

        return """
            #!/bin/zsh
            if cd -- \(shellQuote(configuration.projectURL.standardizedFileURL.path)); then
              \(command)
              status=$?
            else
              status=1
            fi
            /usr/bin/printf '%d\\n' "$status" > \(shellQuote(temporaryStatusURL.path))
            /bin/mv -f \(shellQuote(temporaryStatusURL.path)) \(shellQuote(statusURL.path))
            exit "$status"
            """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private actor ACPProcessAuthenticationRunner {
    private var process: Process?

    func run(
        configuration: AgentConfiguration,
        method: ACPAuthenticationMethod
    ) async throws {
        guard process == nil else {
            throw ACPAgentTransportError.authenticationFailed(
                "Another login process is already running."
            )
        }

        let fileManager = FileManager.default
        let workingDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "VoiceACPAuthentication-\(UUID().uuidString)",
            isDirectory: true
        )
        let scriptURL = workingDirectoryURL.appendingPathComponent("Authenticate.command")
        let statusURL = workingDirectoryURL.appendingPathComponent("exit-status")
        try fileManager.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workingDirectoryURL) }

        let script = ACPTerminalAuthenticationScript.contents(
            configuration: configuration,
            method: method,
            statusURL: statusURL
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-b",
            "com.apple.Terminal",
            scriptURL.path,
        ]
        process.currentDirectoryURL = configuration.projectURL.standardizedFileURL
        process.environment = ChildProcessEnvironment.privacyPreserving
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        let launchStatus: Int32
        do {
            launchStatus = try await run(process)
        } catch {
            self.process = nil
            throw error
        }
        self.process = nil

        try Task.checkCancellation()
        guard launchStatus == 0 else {
            throw ACPAgentTransportError.authenticationFailed(
                "Terminal could not open \(method.name) (status \(launchStatus))."
            )
        }

        let terminationStatus = try await waitForStatus(
            at: statusURL,
            fileManager: fileManager
        )
        guard terminationStatus == 0 else {
            throw ACPAgentTransportError.authenticationFailed(
                "\(method.name) exited with status \(terminationStatus)."
            )
        }
    }

    private func run(_ process: Process) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finishedProcess in
                    continuation.resume(returning: finishedProcess.terminationStatus)
                }
                do {
                    try process.run()
                    if Task.isCancelled, process.isRunning {
                        process.terminate()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func waitForStatus(
        at statusURL: URL,
        fileManager: FileManager
    ) async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: statusURL.path) {
                let contents = try String(contentsOf: statusURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let status = Int32(contents) else {
                    throw ACPAgentTransportError.authenticationFailed(
                        "The terminal login returned an invalid exit status."
                    )
                }
                return status
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func cancel() async {
        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - Process connection

protocol ACPAgentConnection: Sendable {
    func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) async throws -> AsyncThrowingStream<ACPEnvelope, Error>

    func send(_ message: JSONValue) async throws
    func stop() async
}

actor ACPProcessConnection: ACPAgentConnection {
    private let codec = ACPJSONLCodec()
    private let writeQueue = DispatchQueue(label: "io.blacktop.Voice.acp-stdin")
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputContinuation: AsyncThrowingStream<ACPEnvelope, Error>.Continuation?
    private var process: Process?
    private var readerTask: Task<Void, Never>?

    func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> AsyncThrowingStream<ACPEnvelope, Error> {
        guard process == nil else {
            throw ACPAgentTransportError.invalidConfiguration(
                "This ACP connection has already been started."
            )
        }

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ChildProcessEnvironment.privacyPreserving
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let pair = AsyncThrowingStream<ACPEnvelope, Error>.makeStream()
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
            throw ACPAgentTransportError.connectionClosed
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
                    throw ACPAgentTransportError.connectionClosed
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
