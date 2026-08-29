import CryptoKit
import Foundation
import Security
import VoiceCore
import XCTest

@testable import VoicePlatform

final class VoiceSessionTests: XCTestCase {
    func testFailedAgentStartupDisconnectsTransport() async {
        let transport = TestAgentTransport(failSessionStart: true)
        let session = makeSession()

        do {
            try await session.connectPlanning(
                transport: transport,
                configuration: configuration
            )
            XCTFail("Expected session startup to fail")
        } catch {
            // Expected.
        }

        let disconnectCount = await transport.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testPlanningConfigurationIsExposedAppliedAndCleared() async throws {
        let initialOption = AgentSessionConfigurationOption(
            id: "model",
            name: "Model",
            category: "model",
            kind: .select,
            currentValue: .string("sonnet"),
            choices: [
                AgentSessionConfigurationChoice(value: "sonnet", name: "Sonnet"),
                AgentSessionConfigurationChoice(value: "opus", name: "Opus"),
            ]
        )
        let transport = TestAgentTransport(configurationOptions: [initialOption])
        let session = makeSession()

        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )

        let initialOptions = await session.currentPlanningConfigurationOptions()
        XCTAssertEqual(initialOptions.first?.currentValue, .string("sonnet"))

        let updatedOptions = try await session.setPlanningConfiguration(
            id: "model",
            value: .string("opus")
        )
        XCTAssertEqual(updatedOptions.first?.currentValue, .string("opus"))
        let transportOptions = await transport.configurationOptions
        XCTAssertEqual(transportOptions.first?.currentValue, .string("opus"))

        await session.disconnectPlanning()
        let disconnectedOptions = await session.currentPlanningConfigurationOptions()
        XCTAssertTrue(disconnectedOptions.isEmpty)
    }

    func testPlanningResponseIsSpokenWhenEncryptedHistoryFails() async throws {
        let recognizer = TestSpeechRecognizer(text: "plan the parser")
        let speechOutput = TestSpeechOutput()
        let transport = TestAgentTransport(response: "Start with a failing parser test.")
        let history = EncryptedHistoryStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("voicehistory"),
            keyProvider: FailingHistoryKeyProvider(),
            isEnabled: true
        )
        let session = makeSession(
            recognizer: recognizer,
            speechOutput: speechOutput,
            historyStore: history
        )

        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        await session.endCapture()

        let prompts = await transport.prompts
        let spoken = await speechOutput.spoken
        XCTAssertEqual(prompts, ["Plan the parser."])
        XCTAssertEqual(spoken, ["Start with a failing parser test."])
    }

    func testStopSpeakingKeepsPlanningAgentConnected() async throws {
        let recognizer = TestSpeechRecognizer(text: "plan the parser")
        let speechOutput = BlockingSpeechOutput()
        let transport = TestAgentTransport(response: "A deliberately long spoken response.")
        let session = makeSession(
            recognizer: recognizer,
            speechOutput: speechOutput
        )
        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        let finishingTurn = Task {
            await session.endCapture()
        }
        await speechOutput.waitUntilSpeaking()

        let stopped = await session.stopSpeaking()
        await finishingTurn.value
        let stoppedAgain = await session.stopSpeaking()
        let interruptionCount = await speechOutput.interruptionCount
        let agentInterruptionCount = await transport.interruptionCount
        let disconnectCount = await transport.disconnectCount

        XCTAssertTrue(stopped)
        XCTAssertFalse(stoppedAgain)
        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(agentInterruptionCount, 0)
        XCTAssertEqual(disconnectCount, 0)
    }

    func testDisconnectDuringPlanningCaptureCancelsSpeechAndAgent() async throws {
        let recognizer = TestSpeechRecognizer(text: "keep listening")
        let transport = TestAgentTransport(response: "Unused")
        let session = makeSession(recognizer: recognizer)

        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        await session.disconnectPlanning()

        let recognitionCancellations = await recognizer.cancelCount
        let agentDisconnects = await transport.disconnectCount
        XCTAssertEqual(recognitionCancellations, 1)
        XCTAssertEqual(agentDisconnects, 1)
    }

    func testUnexpectedPlanningDisconnectTearsDownCaptureAndSpeech() async throws {
        let recognizer = TestSpeechRecognizer(text: "keep listening")
        let speechOutput = TestSpeechOutput()
        let transport = TestAgentTransport(response: "Unused")
        let session = makeSession(
            recognizer: recognizer,
            speechOutput: speechOutput
        )
        let disconnects = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        await session.setPlanningDisconnectHandler { reason in
            disconnects.continuation.yield(reason)
        }

        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        let stopsBeforeDisconnect = await speechOutput.stopCount

        await transport.simulateUnexpectedDisconnect(reason: "agent exited")
        var observedReason: String?
        for await reason in disconnects.stream.prefix(1) {
            observedReason = reason
        }

        let recognitionCancellations = await recognizer.cancelCount
        let stopsAfterDisconnect = await speechOutput.stopCount
        XCTAssertEqual(observedReason, "agent exited")
        XCTAssertEqual(recognitionCancellations, 1)
        XCTAssertEqual(stopsAfterDisconnect, stopsBeforeDisconnect + 1)
    }

    func testUnexpectedPlanningDisconnectStopsActivePlayback() async throws {
        let recognizer = TestSpeechRecognizer(text: "plan the parser")
        let speechOutput = BlockingSpeechOutput()
        let transport = TestAgentTransport(response: "A deliberately long response.")
        let session = makeSession(
            recognizer: recognizer,
            speechOutput: speechOutput
        )
        let disconnects = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        await session.setPlanningDisconnectHandler { reason in
            disconnects.continuation.yield(reason)
        }
        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        let finishingTurn = Task {
            await session.endCapture()
        }
        await speechOutput.waitUntilSpeaking()

        await transport.simulateUnexpectedDisconnect(reason: "agent exited")
        for await _ in disconnects.stream.prefix(1) {}
        await finishingTurn.value

        let recognitionCancellations = await recognizer.cancelCount
        let playbackInterruptions = await speechOutput.interruptionCount
        XCTAssertEqual(recognitionCancellations, 1)
        XCTAssertEqual(playbackInterruptions, 1)
    }

    func testStaleUnexpectedDisconnectCannotInvalidateReconnection() async throws {
        let recognizer = BlockingFirstCancelRecognizer(text: "new connection turn")
        let speechOutput = BlockingSpeechOutput()
        let oldTransport = TestAgentTransport(response: "Old response")
        let newTransport = TestAgentTransport(response: "New response")
        let session = makeSession(
            recognizer: recognizer,
            speechOutput: speechOutput
        )
        let staleCallback = expectation(description: "stale disconnect callback")
        staleCallback.isInverted = true
        await session.setPlanningDisconnectHandler { _ in
            staleCallback.fulfill()
        }

        try await session.connectPlanning(
            transport: oldTransport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        await oldTransport.simulateUnexpectedDisconnect(reason: "old agent exited")
        await recognizer.waitUntilFirstCancellationStarts()

        await session.disconnectPlanning()
        try await session.connectPlanning(
            transport: newTransport,
            configuration: configuration
        )
        await session.beginPlanningTurn()
        let finishingTurn = Task {
            await session.endCapture()
        }
        await speechOutput.waitUntilSpeaking()

        await recognizer.finishFirstCancellation()
        for _ in 0..<100 {
            await Task.yield()
        }
        let stalePlaybackInterruptions = await speechOutput.interruptionCount
        let stoppedNewPlayback = await session.stopSpeaking()
        await finishingTurn.value

        let newPrompts = await newTransport.prompts
        XCTAssertEqual(newPrompts, ["New connection turn."])
        XCTAssertEqual(stalePlaybackInterruptions, 0)
        XCTAssertTrue(stoppedNewPlayback)
        await fulfillment(of: [staleCallback], timeout: 0.05)
    }

    func testStaleHotkeyPressCannotStartAfterNewerRelease() async throws {
        let recognizer = TestSpeechRecognizer(text: "must not start")
        let transport = TestAgentTransport(response: "Unused")
        let session = makeSession(recognizer: recognizer)
        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )

        await session.handleHotkeyRelease(eventID: 2)
        await session.handleHotkeyPress(
            eventID: 1,
            mode: .conservative,
            planning: true
        )

        let prepareCount = await recognizer.prepareCount
        XCTAssertEqual(prepareCount, 0)
    }

    func testStaleHistoryToggleCannotOverrideNewerChoice() async {
        let history = EncryptedHistoryStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let session = makeSession(historyStore: history)

        await session.setHistoryEnabled(false, eventID: 2)
        await session.setHistoryEnabled(true, eventID: 1)

        let enabled = await history.isEnabled
        XCTAssertFalse(enabled)
    }

    func testCancelledStartDoesNotStrandTheSessionInPreparing() async throws {
        let recognizer = CancellingStartRecognizer()
        let transport = TestAgentTransport(response: "Unused")
        let session = makeSession(recognizer: recognizer)
        try await session.connectPlanning(
            transport: transport,
            configuration: configuration
        )

        await session.beginPlanningTurn()
        await session.beginPlanningTurn()

        let prepareCount = await recognizer.prepareCount
        XCTAssertEqual(prepareCount, 2)
    }

    func testIdleRecognizerCanBeUnloadedAndPreparedAgain() async {
        let recognizer = TestSpeechRecognizer(text: "ready again")
        let session = makeSession(recognizer: recognizer)

        let unloaded = await session.unloadRecognizerIfIdle()
        await session.prewarm()

        let shutdownCount = await recognizer.shutdownCount
        let prepareCount = await recognizer.prepareCount
        XCTAssertTrue(unloaded)
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(prepareCount, 1)
    }

    func testPreparationWaitsForInFlightIdleUnload() async {
        let recognizer = BlockingShutdownRecognizer()
        let session = makeSession(recognizer: recognizer)

        let unload = Task { await session.unloadRecognizerIfIdle() }
        await recognizer.waitUntilShutdownStarts()
        let prewarm = Task { await session.prewarm() }
        await Task.yield()

        let prepareCountDuringUnload = await recognizer.prepareCount
        XCTAssertEqual(prepareCountDuringUnload, 0)

        await recognizer.finishShutdown()
        let didUnload = await unload.value
        XCTAssertTrue(didUnload)
        await prewarm.value
        let finalPrepareCount = await recognizer.prepareCount
        XCTAssertEqual(finalPrepareCount, 1)
    }

    func testRecognizerReplacementUsesPreparedCandidate() async throws {
        let original = TestSpeechRecognizer(text: "original")
        let candidate = TestSpeechRecognizer(text: "candidate")
        let session = makeSession(recognizer: original)

        try await session.replaceRecognizer(with: candidate, name: "Test MLX")
        await session.prewarm()

        let candidatePreparations = await candidate.prepareCount
        let originalPreparations = await original.prepareCount
        let originalShutdowns = await original.shutdownCount
        XCTAssertEqual(candidatePreparations, 2)
        XCTAssertEqual(originalPreparations, 0)
        XCTAssertEqual(originalShutdowns, 1)
    }

    func testFailedRecognizerReplacementKeepsPreviousBackend() async {
        let original = TestSpeechRecognizer(text: "original")
        let candidate = TestSpeechRecognizer(text: "candidate", failPreparation: true)
        let session = makeSession(recognizer: original)

        do {
            try await session.replaceRecognizer(with: candidate, name: "Broken MLX")
            XCTFail("Expected replacement preparation to fail")
        } catch {
            // Expected.
        }
        await session.prewarm()

        let originalPreparations = await original.prepareCount
        let candidateShutdowns = await candidate.shutdownCount
        XCTAssertEqual(originalPreparations, 1)
        XCTAssertEqual(candidateShutdowns, 1)
    }

    func testCancelDuringRecognizerPreparationPreservesPreviousBackend() async {
        let original = TestSpeechRecognizer(text: "original")
        let candidate = BlockingPreparationRecognizer()
        let session = makeSession(recognizer: original)

        let replacement = Task {
            try await session.replaceRecognizer(with: candidate, name: "Test MLX")
        }
        await candidate.waitUntilPreparationStarts()
        await session.cancel()
        await candidate.finishPreparation()

        do {
            try await replacement.value
            XCTFail("Expected the cancelled replacement to stop")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected replacement error: \(error)")
        }

        await session.prewarm()
        let originalPreparations = await original.prepareCount
        let candidateShutdowns = await candidate.shutdownCount
        XCTAssertEqual(originalPreparations, 1)
        XCTAssertEqual(candidateShutdowns, 1)
    }

    func testHeldHotkeyBlocksRecognizerReplacementBeforeTurnWorkStarts() async {
        let candidate = TestSpeechRecognizer(text: "candidate")
        let session = makeSession()

        await session.handleHotkeyPress(
            eventID: 1,
            mode: .conservative,
            planning: true
        )
        do {
            try await session.replaceRecognizer(with: candidate, name: "Test MLX")
            XCTFail("Expected a held hotkey to reserve the current recognizer")
        } catch VoiceSessionRecognizerError.busy {
            // Expected.
        } catch {
            XCTFail("Unexpected replacement error: \(error)")
        }
        await session.handleHotkeyRelease(eventID: 2)
    }

    func testExternalCaptureReservationBlocksSessionWorkUntilReleased() async throws {
        let candidate = TestSpeechRecognizer(text: "candidate")
        let session = makeSession()
        let reservationID = try await session.reserveExternalCapture()

        do {
            try await session.replaceRecognizer(with: candidate, name: "Test MLX")
            XCTFail("Expected the external capture to reserve the current recognizer")
        } catch VoiceSessionRecognizerError.busy {
            // Expected.
        } catch {
            XCTFail("Unexpected replacement error: \(error)")
        }

        await session.releaseExternalCapture(reservationID: reservationID)
        try await session.replaceRecognizer(with: candidate, name: "Test MLX")
    }

    func testExternalCaptureReservationRejectsQueuedHotkeyRelease() async {
        let session = makeSession()
        await session.handleHotkeyPress(
            eventID: 1,
            mode: .conservative,
            planning: true
        )
        await session.handleHotkeyRelease(eventID: 2)

        do {
            _ = try await session.reserveExternalCapture()
            XCTFail("Expected queued hotkey work to block an external capture")
        } catch {
            // Expected.
        }
    }

    private var configuration: AgentConfiguration {
        AgentConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            projectURL: FileManager.default.temporaryDirectory
        )
    }

    private func makeSession(
        recognizer: any SpeechRecognizing = TestSpeechRecognizer(text: "unused"),
        speechOutput: any SpeechOutputting = TestSpeechOutput(),
        historyStore: EncryptedHistoryStore? = nil
    ) -> VoiceSession {
        VoiceSession(
            recognizer: recognizer,
            cleaner: TestPromptCleaner(),
            injector: UnusedTargetInjector(),
            speechOutput: speechOutput,
            historyStore: historyStore,
            onPresentation: { _ in }
        )
    }
}

private struct TestPromptCleaner: PromptCleaning {
    func clean(
        _ transcript: VoiceCore.Transcript,
        mode _: CleanupMode,
        protectedSpans _: [ProtectedSpan]
    ) async -> CleanedPrompt {
        let source = transcript.text
        let cleaned = source.prefix(1).uppercased() + source.dropFirst()
        return CleanedPrompt(text: cleaned + ".", source: .deterministic)
    }
}

private struct UnusedTargetInjector: TargetInjecting {
    @MainActor
    func captureTarget() throws -> InputTarget {
        throw VoiceCoreError.unavailable("The test does not use a focused target.")
    }

    @MainActor
    func insert(_: String, into _: InputTarget) async throws {
        throw VoiceCoreError.unavailable("The test does not insert text.")
    }
}

private actor TestSpeechRecognizer: SpeechRecognizing {
    private let text: String
    private let failPreparation: Bool
    private(set) var cancelCount = 0
    private(set) var prepareCount = 0
    private(set) var shutdownCount = 0

    init(text: String, failPreparation: Bool = false) {
        self.text = text
        self.failPreparation = failPreparation
    }

    func prepare(contextualStrings _: [String]) async throws {
        prepareCount += 1
        if failPreparation {
            throw VoiceCoreError.unavailable("Test recognizer preparation failed.")
        }
    }

    func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let pair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        pair.continuation.yield(
            TranscriptEvent(
                text: text,
                startTime: 0,
                duration: 1,
                isFinal: true,
                confidence: 1
            )
        )
        pair.continuation.finish()
        return pair.stream
    }

    func stop() async throws {}

    func cancel() {
        cancelCount += 1
    }

    func shutdown() {
        shutdownCount += 1
    }
}

private actor BlockingPreparationRecognizer: SpeechRecognizing {
    private let preparationStarted = AsyncGate()
    private let preparationRelease = AsyncGate()
    private(set) var shutdownCount = 0

    func waitUntilPreparationStarts() async {
        await preparationStarted.wait()
    }

    func finishPreparation() async {
        await preparationRelease.open()
    }

    func prepare(contextualStrings _: [String]) async throws {
        await preparationStarted.open()
        await preparationRelease.wait()
    }

    func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stop() async throws {}

    func cancel() {}

    func shutdown() {
        shutdownCount += 1
    }
}

/// A recognizer that reports cancellation while the session still owns the
/// capture, which is what a microphone device change during startup produces.
private actor CancellingStartRecognizer: SpeechRecognizing {
    private(set) var prepareCount = 0

    func prepare(contextualStrings _: [String]) {
        prepareCount += 1
    }

    func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        throw CancellationError()
    }

    func stop() {}

    func cancel() {}

    func shutdown() {}
}

private actor BlockingShutdownRecognizer: SpeechRecognizing {
    private let shutdownStarted = AsyncGate()
    private let shutdownRelease = AsyncGate()
    private(set) var prepareCount = 0

    func waitUntilShutdownStarts() async {
        await shutdownStarted.wait()
    }

    func finishShutdown() async {
        await shutdownRelease.open()
    }

    func prepare(contextualStrings _: [String]) {
        prepareCount += 1
    }

    func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stop() {}

    func cancel() {}

    func shutdown() async {
        await shutdownStarted.open()
        await shutdownRelease.wait()
    }
}

private actor BlockingFirstCancelRecognizer: SpeechRecognizing {
    private let text: String
    private let firstCancellationStarted = AsyncGate()
    private let firstCancellationRelease = AsyncGate()
    private var shouldBlockCancellation = true

    init(text: String) {
        self.text = text
    }

    func waitUntilFirstCancellationStarts() async {
        await firstCancellationStarted.wait()
    }

    func finishFirstCancellation() async {
        await firstCancellationRelease.open()
    }

    func prepare(contextualStrings _: [String]) {}

    func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let pair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        pair.continuation.yield(
            TranscriptEvent(
                text: text,
                startTime: 0,
                duration: 1,
                isFinal: true,
                confidence: 1
            )
        )
        pair.continuation.finish()
        return pair.stream
    }

    func stop() {}

    func cancel() async {
        guard shouldBlockCancellation else { return }
        shouldBlockCancellation = false
        await firstCancellationStarted.open()
        await firstCancellationRelease.wait()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private actor TestSpeechOutput: SpeechOutputting {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    func speak(_ text: String, voiceIdentifier _: String?) {
        spoken.append(text)
    }

    func stopImmediately() {
        stopCount += 1
    }
}

private actor BlockingSpeechOutput: SpeechOutputting {
    private let starts: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private(set) var interruptionCount = 0

    init() {
        let pair = AsyncStream<Void>.makeStream()
        starts = pair.stream
        startContinuation = pair.continuation
    }

    func speak(_: String, voiceIdentifier _: String?) async throws {
        startContinuation.yield(())
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
        }
    }

    func stopImmediately() {
        guard let playbackContinuation else { return }
        self.playbackContinuation = nil
        interruptionCount += 1
        playbackContinuation.resume()
    }

    func waitUntilSpeaking() async {
        for await _ in starts.prefix(1) {}
    }
}

private enum TestAgentError: LocalizedError, Sendable {
    case failedSessionStart

    var errorDescription: String? {
        "The test agent refused to start a session."
    }
}

private actor TestAgentTransport: AgentTransport {
    private let failSessionStart: Bool
    private let response: String
    private(set) var configurationOptions: [AgentSessionConfigurationOption]
    private(set) var interruptionCount = 0
    private(set) var disconnectCount = 0
    private(set) var prompts: [String] = []
    private var disconnectHandler: (@Sendable (String) -> Void)?

    init(
        response: String = "Test response",
        failSessionStart: Bool = false,
        configurationOptions: [AgentSessionConfigurationOption] = []
    ) {
        self.response = response
        self.failSessionStart = failSessionStart
        self.configurationOptions = configurationOptions
    }

    func connect(_: AgentConfiguration) async throws {}

    func startOrResume(sessionID _: String?) async throws -> AgentSession {
        if failSessionStart {
            throw TestAgentError.failedSessionStart
        }
        return AgentSession(
            id: "test-session",
            configurationOptions: configurationOptions
        )
    }

    func send(_ prompt: String) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        prompts.append(prompt)
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        pair.continuation.yield(.connected)
        pair.continuation.yield(.messageDelta(response))
        pair.continuation.yield(.messageCompleted(response))
        pair.continuation.yield(.turnCompleted)
        pair.continuation.finish()
        return pair.stream
    }

    func interrupt() {
        interruptionCount += 1
    }

    func setDisconnectHandler(_ handler: (@Sendable (String) -> Void)?) {
        disconnectHandler = handler
    }

    func simulateUnexpectedDisconnect(reason: String) {
        disconnectHandler?(reason)
    }

    func setSessionConfiguration(
        id: String,
        value: AgentSessionConfigurationValue
    ) async throws -> [AgentSessionConfigurationOption] {
        guard let index = configurationOptions.firstIndex(where: { $0.id == id }),
            configurationOptions[index].accepts(value)
        else {
            throw VoiceCoreError.unavailable("Test configuration is unavailable.")
        }
        configurationOptions[index] = configurationOptions[index]
            .replacingCurrentValue(value)
        return configurationOptions
    }

    func disconnect() {
        disconnectCount += 1
    }
}

private struct FailingHistoryKeyProvider: HistoryKeyProviding {
    func loadOrCreateKey() throws -> SymmetricKey {
        throw HistoryKeyProviderError.keychain(errSecInteractionNotAllowed)
    }
}
