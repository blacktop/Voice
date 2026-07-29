import VoiceCore
import XCTest

@testable import VoicePlatform

final class CodexAppServerTransportTests: XCTestCase {
    func testCodecFramesAndParsesOneJSONLRequest() throws {
        let codec = CodexAppServerJSONLCodec()
        let request = CodexAppServerWire.request(
            id: .number(7),
            method: "turn/start",
            params: .object(["threadId": .string("thread-1")])
        )

        let data = try codec.encode(request)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)

        let envelope = try codec.decode(line: text)
        XCTAssertEqual(envelope.id, .number(7))
        XCTAssertEqual(envelope.method, "turn/start")
        XCTAssertEqual(envelope.params?["threadId"]?.stringValue, "thread-1")
        XCTAssertNil(envelope.result)
        XCTAssertNil(envelope.error)
    }

    func testCodecParsesServerErrorResponse() throws {
        let codec = CodexAppServerJSONLCodec()
        let envelope = try codec.decode(
            line: #"{"id":4,"error":{"code":-32001,"message":"Server overloaded"}}"#
        )

        XCTAssertEqual(envelope.id, .number(4))
        XCTAssertTrue(envelope.isResponse)
        XCTAssertEqual(
            envelope.error,
            CodexAppServerRPCError(code: -32001, message: "Server overloaded")
        )
    }

    func testCodecRejectsNumericRequestIDOutsideIntegerRange() {
        XCTAssertThrowsError(
            try CodexAppServerJSONLCodec().decode(
                line: #"{"id":1e100,"result":{}}"#
            )
        )
    }

    func testReadOnlyThreadAndTurnParametersUseStableWireShapes() {
        let thread = CodexAppServerWire.threadStartParams(projectPath: "/tmp/project")
        XCTAssertEqual(thread["cwd"], .string("/tmp/project"))
        XCTAssertEqual(thread["sandbox"], .string("read-only"))
        XCTAssertEqual(thread["approvalPolicy"], .string("never"))

        let turn = CodexAppServerWire.turnStartParams(
            threadID: "thread-1",
            prompt: "Plan this feature.",
            projectPath: "/tmp/project"
        )
        XCTAssertEqual(turn["threadId"], .string("thread-1"))
        XCTAssertEqual(turn["cwd"], .string("/tmp/project"))
        XCTAssertEqual(turn["sandboxPolicy"]?["type"], .string("readOnly"))
        XCTAssertEqual(turn["sandboxPolicy"]?["networkAccess"], .bool(false))
        XCTAssertEqual(
            turn["input"],
            .array([
                .object([
                    "text": .string("Plan this feature."),
                    "type": .string("text"),
                ])
            ])
        )
    }

    func testExtractsAgentMessageDeltaNotification() throws {
        let envelope = try CodexAppServerJSONLCodec().decode(
            line:
                #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"Hello "}}"#
        )

        XCTAssertEqual(
            CodexAppServerNotificationExtractor.extract(from: envelope),
            .agentMessageDelta(
                threadID: "thread-1",
                turnID: "turn-1",
                delta: "Hello "
            )
        )
    }

    func testExtractsCompletedAgentMessageNotification() throws {
        let envelope = try CodexAppServerJSONLCodec().decode(
            line:
                #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"id":"item-1","type":"agentMessage","text":"Complete response"}}}"#
        )

        XCTAssertEqual(
            CodexAppServerNotificationExtractor.extract(from: envelope),
            .agentMessageCompleted(
                threadID: "thread-1",
                turnID: "turn-1",
                text: "Complete response"
            )
        )
    }

    func testExtractsFailedTurnCompletionNotification() throws {
        let envelope = try CodexAppServerJSONLCodec().decode(
            line:
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"failed","items":[],"error":{"message":"Model unavailable"}}}}"#
        )

        XCTAssertEqual(
            CodexAppServerNotificationExtractor.extract(from: envelope),
            .turnCompleted(
                threadID: "thread-1",
                turnID: "turn-1",
                status: "failed",
                errorMessage: "Model unavailable"
            )
        )
    }

    func testIgnoresCompletedNonAgentItems() throws {
        let envelope = try CodexAppServerJSONLCodec().decode(
            line:
                #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"id":"item-1","type":"commandExecution","command":"pwd"}}}"#
        )

        XCTAssertNil(CodexAppServerNotificationExtractor.extract(from: envelope))
    }

    /// An abandoned event stream (consumer stopped reading mid-turn) must
    /// interrupt the turn AND release the turn slot; otherwise every later
    /// send() fails with turnInProgress when the server never confirms.
    func testAbandonedConsumerReleasesTurnSlotAfterInterrupt() async throws {
        let transport = CodexAppServerTransport(
            connectionFactory: { ScriptedCodexConnection() }
        )
        let configuration = AgentConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/ls"),
            projectURL: FileManager.default.temporaryDirectory,
            arguments: []
        )
        try await transport.connect(configuration)
        _ = try await transport.startOrResume(sessionID: nil)

        do {
            let events = try await transport.send("plan this")
            var iterator = events.makeAsyncIterator()
            _ = try? await iterator.next()
        }

        var lastError: Error?
        for _ in 0..<200 {
            do {
                _ = try await transport.send("plan this again")
                lastError = nil
                break
            } catch CodexAppServerTransportError.turnInProgress {
                lastError = CodexAppServerTransportError.turnInProgress
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertNil(
            lastError,
            "The abandoned turn's slot was never released; send() still reports turnInProgress."
        )
        await transport.disconnect()
    }
}

/// Answers every request in-process so transport state machines can be tested
/// without launching a child process. The interrupted turn is deliberately
/// never confirmed with turn/completed.
private actor ScriptedCodexConnection: CodexAppServerConnection {
    private var continuation: AsyncThrowingStream<CodexAppServerEnvelope, Error>.Continuation?

    func start(
        executableURL _: URL,
        currentDirectoryURL _: URL
    ) throws -> AsyncThrowingStream<CodexAppServerEnvelope, Error> {
        let pair = AsyncThrowingStream<CodexAppServerEnvelope, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func send(_ message: JSONValue) async throws {
        guard let id = message["id"] else { return }
        let result: JSONValue =
            switch message["method"]?.stringValue {
            case "thread/start":
                .object(["thread": .object(["id": .string("thread-1")])])
            case "turn/start":
                .object(["turn": .object(["id": .string(UUID().uuidString)])])
            default:
                .object([:])
            }
        let response = try CodexAppServerEnvelope(
            json: .object(["id": id, "result": result])
        )
        continuation?.yield(response)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}
