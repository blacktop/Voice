import Foundation
import VoiceCore
import XCTest

@testable import VoicePlatform

final class ACPAgentTransportTests: XCTestCase {
    func testCodecFramesAJSONRPC2RequestAsOneLine() throws {
        let codec = ACPJSONLCodec()
        let request = ACPWire.request(
            id: .string("request-7"),
            method: "session/prompt",
            params: .object(["sessionId": .string("session-1")])
        )

        let data = try codec.encode(request)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)

        let envelope = try codec.decode(line: text)
        XCTAssertEqual(envelope.id, .string("request-7"))
        XCTAssertEqual(envelope.method, "session/prompt")
        XCTAssertEqual(envelope.params?["sessionId"]?.stringValue, "session-1")
        XCTAssertNil(envelope.result)
        XCTAssertNil(envelope.error)
    }

    func testCodecRejectsWrongVersionAndUnsafeNumericIDs() {
        XCTAssertThrowsError(
            try ACPJSONLCodec().decode(
                line: #"{"jsonrpc":"1.0","id":1,"result":{}}"#
            )
        )
        XCTAssertThrowsError(
            try ACPJSONLCodec().decode(
                line: #"{"jsonrpc":"2.0","id":9007199254740992,"result":{}}"#
            )
        )
        XCTAssertThrowsError(
            try ACPJSONLCodec().decode(
                line: #"{"jsonrpc":"2.0","id":1.5,"result":{}}"#
            )
        )
    }

    func testInitializeNegotiatesACPVersionOneWithTerminalAuthentication() throws {
        XCTAssertEqual(ACPWire.initializeParams["protocolVersion"], .number(1))
        XCTAssertEqual(
            ACPWire.initializeParams["clientCapabilities"]?["auth"]?["terminal"],
            .bool(true)
        )
        let sessionCapabilities = ACPWire.initializeParams["clientCapabilities"]?["session"]
        XCTAssertEqual(sessionCapabilities?["configOptions"]?["boolean"], .object([:]))
        XCTAssertEqual(
            ACPWire.initializeParams["clientInfo"]?["name"],
            .string("io.blacktop.Voice")
        )

        let supported = try ACPInitializeResult(
            result: .object([
                "agentCapabilities": .object(["loadSession": .bool(true)]),
                "authMethods": .array([
                    .object([
                        "args": .array([
                            .string("--cli"),
                            .string("auth"),
                            .string("login"),
                            .string("--claudeai"),
                        ]),
                        "env": .object(["AUTH_SOURCE": .string("voice")]),
                        "id": .string("claude-ai-login"),
                        "name": .string("Log in with Claude.ai"),
                        "type": .string("terminal"),
                    ])
                ]),
                "protocolVersion": .number(1),
            ])
        )
        XCTAssertTrue(supported.loadSessionSupported)
        let authenticationMethod = try XCTUnwrap(supported.authenticationMethods.first)
        XCTAssertEqual(
            authenticationMethod.arguments,
            ["--cli", "auth", "login", "--claudeai"]
        )
        XCTAssertEqual(authenticationMethod.environment, ["AUTH_SOURCE": "voice"])
        XCTAssertEqual(authenticationMethod.id, "claude-ai-login")
        XCTAssertEqual(authenticationMethod.name, "Log in with Claude.ai")
        XCTAssertEqual(authenticationMethod.type, "terminal")

        let defaulted = try ACPInitializeResult(
            result: .object([
                "agentCapabilities": .object([:]),
                "protocolVersion": .number(1),
            ])
        )
        XCTAssertFalse(defaulted.loadSessionSupported)
        XCTAssertTrue(defaulted.authenticationMethods.isEmpty)

        XCTAssertThrowsError(
            try ACPInitializeResult(
                result: .object([
                    "agentCapabilities": .object([:]),
                    "protocolVersion": .number(2),
                ])
            )
        )
    }

    func testSessionAndPromptParametersMatchACPV1() {
        let newSession = ACPWire.sessionNewParams(projectPath: "/tmp/project")
        XCTAssertEqual(newSession["cwd"], .string("/tmp/project"))
        XCTAssertEqual(newSession["mcpServers"], .array([]))

        let loadedSession = ACPWire.sessionLoadParams(
            sessionID: "session-old",
            projectPath: "/tmp/project"
        )
        XCTAssertEqual(loadedSession["sessionId"], .string("session-old"))
        XCTAssertEqual(loadedSession["cwd"], .string("/tmp/project"))
        XCTAssertEqual(loadedSession["mcpServers"], .array([]))

        let prompt = ACPWire.sessionPromptParams(
            sessionID: "session-1",
            prompt: "Plan this feature."
        )
        XCTAssertEqual(prompt["sessionId"], .string("session-1"))
        XCTAssertEqual(
            prompt["prompt"],
            .array([
                .object([
                    "text": .string("Plan this feature."),
                    "type": .string("text"),
                ])
            ])
        )

        let cancellation = ACPWire.sessionCancelNotification(sessionID: "session-1")
        XCTAssertEqual(cancellation["jsonrpc"], .string("2.0"))
        XCTAssertEqual(cancellation["method"], .string("session/cancel"))
        XCTAssertEqual(cancellation["params"]?["sessionId"], .string("session-1"))
        XCTAssertNil(cancellation["id"])

        let selectConfiguration = ACPWire.sessionConfigurationParams(
            sessionID: "session-1",
            configID: "model",
            value: .string("opus")
        )
        XCTAssertEqual(selectConfiguration["sessionId"], .string("session-1"))
        XCTAssertEqual(selectConfiguration["configId"], .string("model"))
        XCTAssertEqual(selectConfiguration["value"], .string("opus"))
        XCTAssertEqual(selectConfiguration["type"], .string("id"))

        let booleanConfiguration = ACPWire.sessionConfigurationParams(
            sessionID: "session-1",
            configID: "fast",
            value: .boolean(true)
        )
        XCTAssertEqual(booleanConfiguration["value"], .bool(true))
        XCTAssertEqual(booleanConfiguration["type"], .string("boolean"))

        let authentication = ACPWire.authenticationParams(methodID: "claude-ai-login")
        XCTAssertEqual(authentication["methodId"], .string("claude-ai-login"))
    }

    func testParsesSelectAndBooleanConfigurationWhileIgnoringUnknownTypes() throws {
        let options = try ACPSessionConfigurationParser.options(
            from: .object([
                "configOptions": .array([
                    .object([
                        "category": .string("model"),
                        "currentValue": .string("custom-model"),
                        "description": .string("Model used by the agent"),
                        "id": .string("model"),
                        "name": .string("Model"),
                        "options": .array([
                            .object([
                                "description": .null,
                                "name": .string("Sonnet"),
                                "value": .string("sonnet"),
                            ])
                        ]),
                        "type": .string("select"),
                    ]),
                    .object([
                        "currentValue": .bool(true),
                        "id": .string("fast"),
                        "name": .string("Fast mode"),
                        "type": .string("boolean"),
                    ]),
                    .object([
                        "currentValue": .number(4),
                        "id": .string("future"),
                        "name": .string("Future control"),
                        "type": .string("slider"),
                    ]),
                ])
            ])
        )

        XCTAssertEqual(options.map(\.id), ["model", "fast"])
        XCTAssertEqual(options[0].category, "model")
        XCTAssertEqual(options[0].currentValue, .string("custom-model"))
        XCTAssertEqual(
            options[0].displayChoices.map(\.value),
            ["custom-model", "sonnet"]
        )
        XCTAssertEqual(options[1].currentValue, .boolean(true))

        let notification = try ACPEnvelope(
            json: ACPWire.notification(
                method: "session/update",
                params: .object([
                    "sessionId": .string("session-1"),
                    "update": .object([
                        "configOptions": .array([
                            .object([
                                "currentValue": .bool(false),
                                "id": .string("fast"),
                                "name": .string("Fast mode"),
                                "type": .string("boolean"),
                            ])
                        ]),
                        "sessionUpdate": .string("config_option_update"),
                    ]),
                ])
            )
        )
        let update = try XCTUnwrap(
            ACPSessionConfigurationParser.update(from: notification)
        )
        XCTAssertEqual(update.sessionID, "session-1")
        XCTAssertEqual(update.options.first?.currentValue, .boolean(false))
    }

    func testExtractsOnlyTextAgentMessageChunks() throws {
        let agentChunk = try ACPJSONLCodec().decode(
            line:
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","messageId":"message-1","content":{"type":"text","text":"Hello "}}}}"#
        )
        XCTAssertEqual(
            ACPSessionUpdateExtractor.extract(from: agentChunk),
            ACPSessionTextUpdate(sessionID: "session-1", text: "Hello ")
        )

        let userChunk = try ACPJSONLCodec().decode(
            line:
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Ignored"}}}}"#
        )
        XCTAssertNil(ACPSessionUpdateExtractor.extract(from: userChunk))

        let imageChunk = try ACPJSONLCodec().decode(
            line:
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","data":"ignored"}}}}"#
        )
        XCTAssertNil(ACPSessionUpdateExtractor.extract(from: imageChunk))
    }

    func testPermissionRequestsAreCancelledAndUnsupportedMethodsAreRejected() throws {
        let permission = ACPWire.cancelledPermissionResponse(id: .string("permission-1"))
        let permissionEnvelope = try ACPEnvelope(json: permission)
        XCTAssertEqual(permissionEnvelope.id, .string("permission-1"))
        XCTAssertEqual(
            permissionEnvelope.result?["outcome"]?["outcome"],
            .string("cancelled")
        )

        let unsupported = ACPWire.errorResponse(
            id: .number(9),
            code: -32601,
            message: "Method not found"
        )
        let unsupportedEnvelope = try ACPEnvelope(json: unsupported)
        XCTAssertEqual(unsupportedEnvelope.id, .number(9))
        XCTAssertEqual(unsupportedEnvelope.error?.code, -32601)
        XCTAssertEqual(unsupportedEnvelope.error?.message, "Method not found")
    }

    func testParsesEveryACPV1StopReasonAndRejectsUnknownValues() throws {
        let values: [(String, ACPStopReason)] = [
            ("end_turn", .endTurn),
            ("max_tokens", .maxTokens),
            ("max_turn_requests", .maxTurnRequests),
            ("refusal", .refusal),
            ("cancelled", .cancelled),
        ]
        for (value, expected) in values {
            XCTAssertEqual(
                try ACPStopReason(result: .object(["stopReason": .string(value)])),
                expected
            )
        }

        XCTAssertThrowsError(
            try ACPStopReason(result: .object(["stopReason": .string("future_reason")]))
        )
        XCTAssertThrowsError(try ACPStopReason(result: .object([:])))
    }

    func testTransportPassesArgumentsAndGatesSessionLoadByCapability() async throws {
        let connection = ACPTestConnection(behavior: .loadUnsupported)
        let transport = ACPAgentTransport(connectionFactory: { connection })
        let configuration = AgentConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            projectURL: FileManager.default.temporaryDirectory,
            arguments: ["--acp", "stdio"]
        )

        try await transport.connect(configuration)

        let launch = await connection.launch
        XCTAssertEqual(launch?.arguments, ["--acp", "stdio"])
        XCTAssertEqual(
            launch?.currentDirectoryURL.standardizedFileURL,
            FileManager.default.temporaryDirectory.standardizedFileURL
        )

        do {
            _ = try await transport.startOrResume(sessionID: "session-existing")
            XCTFail("Expected unsupported load to fail")
        } catch ACPAgentTransportError.sessionLoadingUnsupported {
            // Expected.
        }

        let didAttemptLoad = await connection.didSend(method: "session/load")
        XCTAssertFalse(didAttemptLoad)
        await transport.disconnect()
    }

    func testTransportRestoresAdvertisedConfigurationAndSetsBooleanOption() async throws {
        let connection = ACPTestConnection(behavior: .sessionConfiguration)
        let transport = ACPAgentTransport(connectionFactory: { connection })
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory,
                sessionConfigurationValues: [
                    "effort": .string("high"),
                    "model": .string("opus"),
                ]
            )
        )

        let session = try await transport.startOrResume(sessionID: nil)

        XCTAssertEqual(
            session.configurationOptions.first(where: { $0.id == "model" })?.currentValue,
            .string("opus")
        )
        XCTAssertEqual(
            session.configurationOptions.first(where: { $0.id == "effort" })?.currentValue,
            .string("high")
        )
        let configurationMessages = await connection.sentMessages(
            method: "session/set_config_option"
        )
        XCTAssertEqual(configurationMessages.count, 2)
        XCTAssertEqual(configurationMessages[0]["params"]?["configId"], .string("model"))
        XCTAssertEqual(configurationMessages[0]["params"]?["value"], .string("opus"))
        XCTAssertEqual(configurationMessages[1]["params"]?["configId"], .string("effort"))
        XCTAssertEqual(configurationMessages[1]["params"]?["value"], .string("high"))

        let updateReceived = expectation(description: "configuration update")
        await transport.setSessionConfigurationHandler { _ in
            updateReceived.fulfill()
        }
        let notificationEnqueued = try await connection.publishConfigurationUpdate(
            model: "sonnet",
            effort: "default",
            fastModeEnabled: false
        )
        XCTAssertTrue(notificationEnqueued)
        await fulfillment(of: [updateReceived], timeout: 1)

        let updated = try await transport.setSessionConfiguration(
            id: "fast",
            value: .boolean(true)
        )
        XCTAssertEqual(
            updated.first(where: { $0.id == "fast" })?.currentValue,
            .boolean(true)
        )
        let allConfigurationMessages = await connection.sentMessages(
            method: "session/set_config_option"
        )
        let latestMessage = allConfigurationMessages.last
        XCTAssertEqual(latestMessage?["params"]?["type"], .string("boolean"))
        XCTAssertEqual(latestMessage?["params"]?["value"], .bool(true))
        await transport.disconnect()
    }

    func testAuthenticationRequiredAtSessionStartRunsAdvertisedLoginAndRetries() async throws {
        let connection = ACPTestConnection(behavior: .authenticationRequiredAtSessionStart)
        let authentication = ACPTestAuthenticationRunner()
        let transport = ACPAgentTransport(
            connectionFactory: { connection },
            authenticationRunner: { configuration, method in
                try await authentication.run(configuration: configuration, method: method)
            }
        )
        let configuration = AgentConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            projectURL: FileManager.default.temporaryDirectory,
            arguments: ["adapter.js"]
        )

        try await transport.connect(configuration)
        let session = try await transport.startOrResume(sessionID: nil)

        XCTAssertEqual(session.id, "session-new")
        let sessionRequestCount = await connection.sendCount(method: "session/new")
        XCTAssertEqual(sessionRequestCount, 2)
        let authenticationRequest = await connection.firstSentMessage(method: "authenticate")
        XCTAssertEqual(
            authenticationRequest?["params"]?["methodId"],
            .string("claude-ai-login")
        )
        let runs = await authentication.runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.baseArguments, ["adapter.js"])
        XCTAssertEqual(runs.first?.method.id, "claude-ai-login")
        XCTAssertEqual(
            runs.first?.method.arguments,
            ["--cli", "auth", "login", "--claudeai"]
        )
        await transport.disconnect()
    }

    func testAuthenticationRequiredAtFirstPromptRunsLoginAndRetries() async throws {
        let connection = ACPTestConnection(behavior: .authenticationRequiredAtPrompt)
        let authentication = ACPTestAuthenticationRunner()
        let transport = ACPAgentTransport(
            connectionFactory: { connection },
            authenticationRunner: { configuration, method in
                try await authentication.run(configuration: configuration, method: method)
            }
        )
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory
            )
        )
        _ = try await transport.startOrResume(sessionID: nil)

        let stream = try await transport.send("Plan this feature.")
        for try await _ in stream {}

        let promptRequestCount = await connection.sendCount(method: "session/prompt")
        let authenticationRunCount = await authentication.runs.count
        let authenticationRequestCount = await connection.sendCount(method: "authenticate")
        XCTAssertEqual(promptRequestCount, 2)
        XCTAssertEqual(authenticationRunCount, 1)
        XCTAssertEqual(authenticationRequestCount, 1)
        await transport.disconnect()
    }

    func testAuthenticationRequiredWithoutAdvertisedLoginFailsClearly() async throws {
        let connection = ACPTestConnection(
            behavior: .authenticationRequiredWithoutAdvertisedMethod
        )
        let authentication = ACPTestAuthenticationRunner()
        let transport = ACPAgentTransport(
            connectionFactory: { connection },
            authenticationRunner: { configuration, method in
                try await authentication.run(configuration: configuration, method: method)
            }
        )
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory
            )
        )

        do {
            _ = try await transport.startOrResume(sessionID: nil)
            XCTFail("Expected authentication to be unavailable")
        } catch ACPAgentTransportError.authenticationUnavailable {
            // Expected.
        }
        let authenticationRuns = await authentication.runs
        XCTAssertTrue(authenticationRuns.isEmpty)
        await transport.disconnect()
    }

    func testAuthenticationRunnerFailureIsReportedWithoutASecondRequest() async throws {
        let connection = ACPTestConnection(behavior: .authenticationRequiredAtSessionStart)
        let authentication = ACPTestAuthenticationRunner(shouldFail: true)
        let transport = ACPAgentTransport(
            connectionFactory: { connection },
            authenticationRunner: { configuration, method in
                try await authentication.run(configuration: configuration, method: method)
            }
        )
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory
            )
        )

        do {
            _ = try await transport.startOrResume(sessionID: nil)
            XCTFail("Expected authentication to fail")
        } catch ACPAgentTransportError.authenticationFailed(let reason) {
            XCTAssertTrue(reason.contains("test login failure"))
        }
        let sessionRequestCount = await connection.sendCount(method: "session/new")
        XCTAssertEqual(sessionRequestCount, 1)
        await transport.disconnect()
    }

    func testDisconnectCancelsRunningAuthentication() async throws {
        let connection = ACPTestConnection(behavior: .authenticationRequiredAtSessionStart)
        let authentication = ACPTestAuthenticationRunner(shouldSuspend: true)
        let transport = ACPAgentTransport(
            connectionFactory: { connection },
            authenticationRunner: { configuration, method in
                try await authentication.run(configuration: configuration, method: method)
            }
        )
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory
            )
        )

        let sessionTask = Task {
            try await transport.startOrResume(sessionID: nil)
        }
        let authenticationStarted = await waitUntil {
            await !authentication.runs.isEmpty
        }
        XCTAssertTrue(authenticationStarted)

        await transport.disconnect()
        do {
            _ = try await sessionTask.value
            XCTFail("Expected disconnect to cancel authentication")
        } catch is CancellationError {
            // Expected.
        }
        let cancellationObserved = await authentication.cancellationObserved
        XCTAssertTrue(cancellationObserved)
    }

    func testInitializeSendFailureNotifiesDisconnectHandlerOnce() async throws {
        let connection = ACPTestConnection(behavior: .initializeWriteFailure)
        let transport = ACPAgentTransport(connectionFactory: { connection })
        let disconnected = expectation(description: "disconnect handler")
        disconnected.assertForOverFulfill = true
        let agentTransport: any AgentTransport = transport
        await agentTransport.setDisconnectHandler { _ in
            disconnected.fulfill()
        }

        do {
            try await transport.connect(
                AgentConfiguration(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    projectURL: FileManager.default.temporaryDirectory
                )
            )
            XCTFail("Expected initialize write to fail")
        } catch ACPTestConnection.Failure.initializeWrite {
            // Expected.
        }

        await fulfillment(of: [disconnected], timeout: 1)
    }

    func testTransportStreamsAgentTextDeniesPermissionAndCompletesTurn() async throws {
        let connection = ACPTestConnection(behavior: .completingPromptWithPermissionRequest)
        let transport = ACPAgentTransport(connectionFactory: { connection })
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory
            )
        )
        let session = try await transport.startOrResume(sessionID: nil)
        XCTAssertEqual(session.id, "session-new")

        let stream = try await transport.send("Plan this feature.")
        var deltas: [String] = []
        var completedMessage: String?
        var turnCompleted = false
        for try await event in stream {
            switch event {
            case .messageDelta(let delta):
                deltas.append(delta)
            case .messageCompleted(let message):
                completedMessage = message
            case .turnCompleted:
                turnCompleted = true
            case .connected, .status:
                break
            }
        }

        XCTAssertEqual(deltas, ["Hello ", "world."])
        XCTAssertEqual(completedMessage, "Hello world.")
        XCTAssertTrue(turnCompleted)

        let permissionResponse = await connection.sentMessage(
            matchingID: .string("permission-1")
        )
        XCTAssertEqual(
            permissionResponse?["result"]?["outcome"]?["outcome"],
            .string("cancelled")
        )
        await transport.disconnect()
    }

    func testCancellingStreamConsumerSendsSessionCancelNotification() async throws {
        let connection = ACPTestConnection(behavior: .pendingPrompt)
        let transport = ACPAgentTransport(connectionFactory: { connection })
        try await transport.connect(
            AgentConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                projectURL: FileManager.default.temporaryDirectory
            )
        )
        _ = try await transport.startOrResume(sessionID: nil)

        let stream = try await transport.send("Keep planning.")
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the behavior under test.
            }
        }
        let sentPrompt = await waitUntil {
            await connection.didSend(method: "session/prompt")
        }
        XCTAssertTrue(sentPrompt, "The prompt request was never sent")

        consumer.cancel()

        let sentCancellation = await waitUntil {
            await connection.didSend(method: "session/cancel")
        }
        XCTAssertTrue(sentCancellation, "Cancelling the stream did not notify the ACP agent")
        let cancellation = await connection.firstSentMessage(method: "session/cancel")
        XCTAssertEqual(cancellation?["params"]?["sessionId"], .string("session-new"))

        do {
            _ = try await transport.send("Do not overlap the cancelling turn.")
            XCTFail("Expected the cancelling turn to remain active until the agent acknowledges it")
        } catch ACPAgentTransportError.turnInProgress {
            // Expected.
        }
        await transport.disconnect()
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

private actor ACPTestConnection: ACPAgentConnection {
    enum Behavior: Sendable {
        case authenticationRequiredAtPrompt
        case authenticationRequiredAtSessionStart
        case authenticationRequiredWithoutAdvertisedMethod
        case completingPromptWithPermissionRequest
        case initializeWriteFailure
        case loadUnsupported
        case pendingPrompt
        case sessionConfiguration
    }

    enum Failure: Error {
        case initializeWrite
    }

    struct Launch: Sendable {
        let executableURL: URL
        let arguments: [String]
        let currentDirectoryURL: URL
    }

    let behavior: Behavior
    private(set) var launch: Launch?
    private var continuation: AsyncThrowingStream<ACPEnvelope, Error>.Continuation?
    private var authenticated = false
    private var sentMessages: [JSONValue] = []
    private var selectedEffort = "default"
    private var selectedModel = "sonnet"
    private var fastModeEnabled = false

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> AsyncThrowingStream<ACPEnvelope, Error> {
        launch = Launch(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
        let pair = AsyncThrowingStream<ACPEnvelope, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func send(_ message: JSONValue) throws {
        sentMessages.append(message)
        guard let method = message["method"]?.stringValue,
            let rawID = message["id"]
        else {
            return
        }
        let id = try Self.requestID(from: rawID)

        switch method {
        case "initialize":
            if behavior == .initializeWriteFailure {
                throw Failure.initializeWrite
            }
            let loadSupported = behavior != .loadUnsupported
            let authenticationMethods: JSONValue
            if behavior == .authenticationRequiredWithoutAdvertisedMethod {
                authenticationMethods = .array([])
            } else if behavior == .authenticationRequiredAtSessionStart
                || behavior == .authenticationRequiredAtPrompt
            {
                authenticationMethods = .array([Self.claudeAuthenticationMethod])
            } else {
                authenticationMethods = .array([])
            }
            try yield(
                ACPWire.resultResponse(
                    id: id,
                    result: .object([
                        "agentCapabilities": .object([
                            "loadSession": .bool(loadSupported)
                        ]),
                        "authMethods": authenticationMethods,
                        "protocolVersion": .number(1),
                    ])
                )
            )

        case "session/new":
            if behavior == .authenticationRequiredAtSessionStart
                || behavior == .authenticationRequiredWithoutAdvertisedMethod,
                !authenticated
            {
                try yield(Self.authenticationRequiredResponse(id: id))
                return
            }
            var result: [String: JSONValue] = ["sessionId": .string("session-new")]
            if behavior == .sessionConfiguration {
                result["configOptions"] = Self.configurationOptions(
                    model: selectedModel,
                    effort: selectedEffort,
                    fastModeEnabled: fastModeEnabled
                )
            }
            try yield(ACPWire.resultResponse(id: id, result: .object(result)))

        case "session/load":
            try yield(ACPWire.resultResponse(id: id, result: .null))

        case "session/prompt":
            guard behavior != .pendingPrompt else { return }
            if behavior == .authenticationRequiredAtPrompt,
                !authenticated
            {
                try yield(Self.authenticationRequiredResponse(id: id))
                return
            }
            if behavior == .completingPromptWithPermissionRequest {
                try yield(
                    ACPWire.request(
                        id: .string("permission-1"),
                        method: "session/request_permission",
                        params: .object(["sessionId": .string("session-new")])
                    )
                )
            }
            try yield(Self.agentMessageChunk(text: "Hello "))
            try yield(Self.agentMessageChunk(text: "world."))
            try yield(
                ACPWire.resultResponse(
                    id: id,
                    result: .object(["stopReason": .string("end_turn")])
                )
            )

        case "authenticate":
            guard
                message["params"]?["methodId"]?.stringValue
                    == "claude-ai-login"
            else {
                try yield(
                    ACPWire.errorResponse(
                        id: id,
                        code: -32_602,
                        message: "Invalid authentication method"
                    )
                )
                return
            }
            authenticated = true
            try yield(ACPWire.resultResponse(id: id, result: .object([:])))

        case "session/set_config_option":
            guard behavior == .sessionConfiguration,
                let configID = message["params"]?["configId"]?.stringValue,
                let value = message["params"]?["value"]
            else {
                return
            }
            switch (configID, value) {
            case ("model", .string(let model)):
                selectedModel = model
            case ("effort", .string(let effort)):
                selectedEffort = effort
            case ("fast", .bool(let enabled)):
                fastModeEnabled = enabled
            default:
                return
            }
            try yield(
                ACPWire.resultResponse(
                    id: id,
                    result: .object([
                        "configOptions": Self.configurationOptions(
                            model: selectedModel,
                            effort: selectedEffort,
                            fastModeEnabled: fastModeEnabled
                        )
                    ])
                )
            )

        default:
            break
        }
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func didSend(method: String) -> Bool {
        sentMessages.contains { $0["method"]?.stringValue == method }
    }

    func sendCount(method: String) -> Int {
        sentMessages.count { $0["method"]?.stringValue == method }
    }

    func firstSentMessage(method: String) -> JSONValue? {
        sentMessages.first { $0["method"]?.stringValue == method }
    }

    func sentMessages(method: String) -> [JSONValue] {
        sentMessages.filter { $0["method"]?.stringValue == method }
    }

    func sentMessage(matchingID id: ACPRequestID) -> JSONValue? {
        sentMessages.first { message in
            guard let rawID = message["id"],
                let requestID = try? Self.requestID(from: rawID)
            else {
                return false
            }
            return requestID == id && message["method"] == nil
        }
    }

    func publishConfigurationUpdate(
        model: String,
        effort: String,
        fastModeEnabled: Bool
    ) throws -> Bool {
        guard let continuation else { return false }
        let envelope = try ACPEnvelope(
            json: ACPWire.notification(
                method: "session/update",
                params: .object([
                    "sessionId": .string("session-new"),
                    "update": .object([
                        "configOptions": Self.configurationOptions(
                            model: model,
                            effort: effort,
                            fastModeEnabled: fastModeEnabled
                        ),
                        "sessionUpdate": .string("config_option_update"),
                    ]),
                ])
            )
        )
        switch continuation.yield(envelope) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private func yield(_ message: JSONValue) throws {
        continuation?.yield(try ACPEnvelope(json: message))
    }

    private static func requestID(from value: JSONValue) throws -> ACPRequestID {
        switch value {
        case .number(let number):
            guard let integer = Int(exactly: number) else {
                throw ACPAgentTransportError.invalidResponse("Invalid test request id.")
            }
            return .number(integer)
        case .string(let string):
            return .string(string)
        default:
            throw ACPAgentTransportError.invalidResponse("Invalid test request id.")
        }
    }

    private static func agentMessageChunk(text: String) -> JSONValue {
        ACPWire.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-new"),
                "update": .object([
                    "content": .object([
                        "text": .string(text),
                        "type": .string("text"),
                    ]),
                    "sessionUpdate": .string("agent_message_chunk"),
                ]),
            ])
        )
    }

    private static let claudeAuthenticationMethod: JSONValue = .object([
        "args": .array([
            .string("--cli"),
            .string("auth"),
            .string("login"),
            .string("--claudeai"),
        ]),
        "id": .string("claude-ai-login"),
        "name": .string("Log in with Claude.ai"),
        "type": .string("terminal"),
    ])

    private static func authenticationRequiredResponse(id: ACPRequestID) -> JSONValue {
        ACPWire.errorResponse(
            id: id,
            code: -32_000,
            message: "Authentication required"
        )
    }

    private static func configurationOptions(
        model: String,
        effort: String,
        fastModeEnabled: Bool
    ) -> JSONValue {
        .array([
            .object([
                "category": .string("model"),
                "currentValue": .string(model),
                "id": .string("model"),
                "name": .string("Model"),
                "options": .array([
                    .object(["name": .string("Sonnet"), "value": .string("sonnet")]),
                    .object(["name": .string("Opus"), "value": .string("opus")]),
                ]),
                "type": .string("select"),
            ]),
            .object([
                "category": .string("thought_level"),
                "currentValue": .string(effort),
                "id": .string("effort"),
                "name": .string("Effort"),
                "options": .array([
                    .object(["name": .string("Default"), "value": .string("default")]),
                    .object(["name": .string("High"), "value": .string("high")]),
                ]),
                "type": .string("select"),
            ]),
            .object([
                "category": .string("model_config"),
                "currentValue": .bool(fastModeEnabled),
                "id": .string("fast"),
                "name": .string("Fast mode"),
                "type": .string("boolean"),
            ]),
        ])
    }
}

final class ACPTerminalAuthenticationScriptTests: XCTestCase {
    func testScriptUsesTheExactExecutableArgumentsEnvironmentAndProject() throws {
        let configuration = AgentConfiguration(
            executableURL: URL(fileURLWithPath: "/tmp/agent's binary"),
            projectURL: URL(fileURLWithPath: "/tmp/project with spaces"),
            arguments: ["adapter.js", "--name=O'Brien"]
        )
        let method = try ACPAuthenticationMethod(
            json: .object([
                "args": .array([.string("auth"), .string("login")]),
                "env": .object(["AUTH_SOURCE": .string("Voice's terminal")]),
                "id": .string("login"),
                "name": .string("Login"),
                "type": .string("terminal"),
            ])
        )
        let statusURL = URL(fileURLWithPath: "/tmp/status file")

        let script = ACPTerminalAuthenticationScript.contents(
            configuration: configuration,
            method: method,
            statusURL: statusURL
        )

        XCTAssertTrue(script.contains("cd -- '/tmp/project with spaces'"))
        XCTAssertTrue(script.contains("/usr/bin/env -i"))
        XCTAssertTrue(script.contains("'/tmp/agent'\\''s binary'"))
        XCTAssertTrue(script.contains("'--name=O'\\''Brien'"))
        XCTAssertTrue(script.contains("'AUTH_SOURCE=Voice'\\''s terminal'"))
        XCTAssertTrue(script.contains("'/tmp/status file.tmp'"))
        XCTAssertTrue(script.contains("'/tmp/status file'"))
        XCTAssertTrue(script.contains("else\n  status=1"))
    }
}

private actor ACPTestAuthenticationRunner {
    struct Run: Sendable {
        let baseArguments: [String]
        let method: ACPAuthenticationMethod
    }

    enum Failure: LocalizedError {
        case login

        var errorDescription: String? {
            "test login failure"
        }
    }

    private(set) var runs: [Run] = []
    private(set) var cancellationObserved = false
    private let shouldFail: Bool
    private let shouldSuspend: Bool

    init(shouldFail: Bool = false, shouldSuspend: Bool = false) {
        self.shouldFail = shouldFail
        self.shouldSuspend = shouldSuspend
    }

    func run(
        configuration: AgentConfiguration,
        method: ACPAuthenticationMethod
    ) async throws {
        runs.append(Run(baseArguments: configuration.arguments, method: method))
        if shouldFail {
            throw Failure.login
        }
        if shouldSuspend {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                cancellationObserved = true
                throw CancellationError()
            }
        }
    }
}
