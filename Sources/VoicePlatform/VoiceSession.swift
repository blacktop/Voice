import Foundation
import VoiceCore
import os

public enum VoiceSessionRecognizerError: LocalizedError, Sendable {
    case busy

    public var errorDescription: String? {
        "Finish the current voice turn before changing speech models."
    }
}

public actor VoiceSession {
    private static let logger = Logger(subsystem: "io.blacktop.Voice", category: "session")
    public typealias PresentationHandler = @Sendable (VoicePresentation) -> Void
    public typealias PlanningConfigurationHandler =
        @Sendable ([AgentSessionConfigurationOption]) -> Void

    private enum Destination {
        case focusedTarget(InputTarget)
        case planning
    }

    private var recognizer: any SpeechRecognizing
    private let cleaner: any PromptCleaning
    private let injector: any TargetInjecting
    private let speechOutput: any SpeechOutputting
    private let historyStore: EncryptedHistoryStore?
    private let detector = ProtectedSpanDetector()
    private let onPresentation: PresentationHandler

    private var assembler = TranscriptAssembler()
    private var recognitionTask: Task<Void, Never>?
    private var recognitionError: Error?
    private var destination: Destination?
    private var mode: CleanupMode = .conservative
    private var phase: VoiceSessionPhase = .idle
    private var contextualStrings: [String] = []
    private var transport: (any AgentTransport)?
    private var connectingTransport: (any AgentTransport)?
    private var planningConnectionID: UUID?
    private var agentSession: AgentSession?
    private var selectedVoiceIdentifier: String?
    private var activeCaptureID: UUID?
    private var releaseRequested = false
    private var lastHotkeyEventID: UInt64 = 0
    private var lastHistoryEventID: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var transportGeneration: UUID?
    private var planningTeardownGeneration: UUID?
    private var onPlanningDisconnect: (@Sendable (String) -> Void)?
    private var onPlanningConfiguration: PlanningConfigurationHandler?
    private var planningConfigurationOptions: [AgentSessionConfigurationOption] = []
    private var recognizerReplacementID: UUID?
    private var recognizerReplacementCommitted = false
    private var hotkeyHeld = false
    private var externalCaptureReservationID: UUID?
    private var recognizerUnload: (id: UUID, task: Task<Void, Never>)?

    public init(
        recognizer: any SpeechRecognizing,
        cleaner: any PromptCleaning,
        injector: any TargetInjecting,
        speechOutput: any SpeechOutputting,
        historyStore: EncryptedHistoryStore? = nil,
        onPresentation: @escaping PresentationHandler
    ) {
        self.recognizer = recognizer
        self.cleaner = cleaner
        self.injector = injector
        self.speechOutput = speechOutput
        self.historyStore = historyStore
        self.onPresentation = onPresentation
    }

    public func setContextualStrings(_ strings: [String]) {
        contextualStrings = Array(strings.prefix(100))
    }

    public func setVoiceIdentifier(_ identifier: String?) {
        selectedVoiceIdentifier = identifier
    }

    public func setHistoryEnabled(_ enabled: Bool, eventID: UInt64) async {
        guard eventID > lastHistoryEventID else { return }
        lastHistoryEventID = eventID
        await historyStore?.setEnabled(enabled)
    }

    /// Called when a connected planning transport drops unexpectedly, so the
    /// owner can update connection state it tracks (e.g. menu labels).
    public func setPlanningDisconnectHandler(_ handler: (@Sendable (String) -> Void)?) {
        onPlanningDisconnect = handler
    }

    public func setPlanningConfigurationHandler(
        _ handler: PlanningConfigurationHandler?
    ) {
        onPlanningConfiguration = handler
    }

    public func currentPlanningConfigurationOptions() -> [AgentSessionConfigurationOption] {
        planningConfigurationOptions
    }

    public func setPlanningConfiguration(
        id: String,
        value: AgentSessionConfigurationValue
    ) async throws -> [AgentSessionConfigurationOption] {
        guard let transport, agentSession != nil,
            let generation = transportGeneration
        else {
            throw VoiceCoreError.unavailable("Connect a planning agent first.")
        }
        let options = try await transport.setSessionConfiguration(id: id, value: value)
        guard generation == transportGeneration, self.transport != nil else {
            throw CancellationError()
        }
        updatePlanningConfiguration(options)
        return options
    }

    public func handleHotkeyPress(
        eventID: UInt64,
        mode: CleanupMode,
        planning: Bool
    ) async {
        guard eventID > lastHotkeyEventID else { return }
        lastHotkeyEventID = eventID
        guard externalCaptureReservationID == nil else { return }
        hotkeyHeld = true
        releaseRequested = false
        // Run the turn work unawaited: the caller's ordered delivery must not
        // wait for preparation (a queued release would keep the mic running),
        // and release-during-preparing relies on interleaving at suspension
        // points.
        Task { await self.processHotkeyPress(mode: mode, planning: planning) }
    }

    public func handleHotkeyRelease(eventID: UInt64) async {
        guard eventID > lastHotkeyEventID else { return }
        lastHotkeyEventID = eventID
        guard externalCaptureReservationID == nil else { return }
        hotkeyHeld = false
        // Recorded synchronously so a press whose begin-work has not started
        // yet still observes the release and aborts instead of capturing with
        // no key held.
        releaseRequested = true
        Task { await self.endCapture() }
    }

    private func processHotkeyPress(mode: CleanupMode, planning: Bool) async {
        if phase == .speaking {
            activeCaptureID = nil
            await speechOutput.stopImmediately()
            if phase == .speaking {
                reset(message: "Speech interrupted", connected: transport != nil)
            }
        }
        if planning {
            await beginPlanningTurn(mode: mode)
        } else {
            await beginDictation(mode: mode)
        }
    }

    /// Builds the recognition session ahead of first use so the first hotkey
    /// press does not pay multi-second model setup. Failures are retried and
    /// surfaced by the next capture's prepare.
    public func prewarm() async {
        await waitForRecognizerUnload()
        try? await recognizer.prepare(contextualStrings: contextualStrings)
    }

    /// Releases the active recognizer only when no turn or replacement can be
    /// using it. The next hotkey press prepares it again before capture.
    public func unloadRecognizerIfIdle() async -> Bool {
        guard phase == .idle, activeCaptureID == nil, !hotkeyHeld,
            recognitionTask == nil, recognizerReplacementID == nil,
            externalCaptureReservationID == nil, recognizerUnload == nil
        else {
            return false
        }
        let unloadID = UUID()
        let recognizer = recognizer
        let task = Task {
            await recognizer.shutdown()
        }
        recognizerUnload = (unloadID, task)
        await task.value
        if recognizerUnload?.id == unloadID {
            recognizerUnload = nil
        }
        return true
    }

    private func waitForRecognizerUnload() async {
        guard let unload = recognizerUnload else { return }
        await unload.task.value
        if recognizerUnload?.id == unload.id {
            recognizerUnload = nil
        }
    }

    /// Atomically reserves the microphone for an owner outside the normal
    /// hotkey pipeline. The caller must release the returned token on every
    /// completion, failure, and cancellation path.
    public func reserveExternalCapture() throws -> UUID {
        guard phase == .idle, activeCaptureID == nil, !hotkeyHeld,
            !releaseRequested, recognitionTask == nil, destination == nil,
            recognizerReplacementID == nil, externalCaptureReservationID == nil
        else {
            throw VoiceCoreError.unavailable(
                "Finish or cancel the current voice turn before recording a comparison."
            )
        }
        let reservationID = UUID()
        externalCaptureReservationID = reservationID
        return reservationID
    }

    public func releaseExternalCapture(reservationID: UUID) {
        guard externalCaptureReservationID == reservationID else { return }
        externalCaptureReservationID = nil
    }

    /// Installs a recognizer that may already have completed an expensive model
    /// download. The second prepare applies the latest project vocabulary and
    /// keeps the swap transactional: the previous backend remains selected if
    /// preparation fails.
    public func replaceRecognizer(
        with candidate: any SpeechRecognizing,
        name: String
    ) async throws {
        await waitForRecognizerUnload()
        guard phase == .idle, activeCaptureID == nil, !hotkeyHeld,
            externalCaptureReservationID == nil
        else {
            throw VoiceSessionRecognizerError.busy
        }

        let replacementID = UUID()
        recognizerReplacementID = replacementID
        recognizerReplacementCommitted = false
        phase = .preparing
        publish(
            .init(
                phase: .preparing,
                message: "Activating \(name)…",
                isConnectedPlanning: transport != nil
            )
        )
        do {
            try await candidate.prepare(contextualStrings: contextualStrings)
            try Task.checkCancellation()
        } catch {
            await candidate.shutdown()
            if recognizerReplacementID == replacementID {
                recognizerReplacementID = nil
                recognizerReplacementCommitted = false
                phase = .idle
                publish(
                    .init(
                        phase: .idle,
                        message: "Previous speech model remains active",
                        isConnectedPlanning: transport != nil
                    )
                )
            }
            throw error
        }
        guard recognizerReplacementID == replacementID,
            phase == .preparing,
            activeCaptureID == nil,
            !hotkeyHeld
        else {
            await candidate.shutdown()
            throw CancellationError()
        }

        let previous = recognizer
        recognizerReplacementCommitted = true
        recognizer = candidate
        publish(
            .init(
                phase: .preparing,
                message: "Finishing \(name) activation…",
                isConnectedPlanning: transport != nil
            )
        )
        // Keep the session unavailable until the old backend has released its
        // model. MLX cache teardown is process-wide and must not overlap a turn
        // on the newly selected backend.
        await previous.shutdown()
        recognizerReplacementID = nil
        recognizerReplacementCommitted = false
        phase = .idle
        publish(
            .init(
                phase: .idle,
                message: "\(name) ready",
                isConnectedPlanning: transport != nil
            )
        )
    }

    public func connectPlanning(
        transport: any AgentTransport,
        configuration: AgentConfiguration,
        resumeSessionID: String? = nil
    ) async throws {
        guard phase == .idle, activeCaptureID == nil,
            externalCaptureReservationID == nil
        else {
            throw VoiceCoreError.unavailable(
                "Finish or cancel the current voice turn before connecting an agent."
            )
        }
        await disconnectPlanning()
        let connectionID = UUID()
        planningConnectionID = connectionID
        connectingTransport = transport
        phase = .preparing
        publish(
            .init(
                phase: .preparing, message: "Connecting to planning agent…",
                isConnectedPlanning: true))
        await transport.setDisconnectHandler { [weak self] reason in
            Task { [weak self] in
                await self?.handlePlanningTransportDisconnect(
                    generation: connectionID,
                    reason: reason
                )
            }
        }
        await transport.setSessionConfigurationHandler { [weak self] options in
            Task { [weak self] in
                await self?.handlePlanningConfigurationUpdate(
                    generation: connectionID,
                    options: options
                )
            }
        }
        do {
            try await transport.connect(configuration)
            try ensureConnectionActive(connectionID)
            let session = try await transport.startOrResume(sessionID: resumeSessionID)
            try ensureConnectionActive(connectionID)
            self.transport = transport
            transportGeneration = connectionID
            connectingTransport = nil
            planningConnectionID = nil
            agentSession = session
            updatePlanningConfiguration(session.configurationOptions)
            phase = .idle
            publish(
                .init(phase: .idle, message: "Connected planning ready", isConnectedPlanning: true))
        } catch {
            await transport.disconnect()
            if planningConnectionID == connectionID {
                connectingTransport = nil
                planningConnectionID = nil
                updatePlanningConfiguration([])
                phase = .idle
            }
            throw error
        }
    }

    /// The planning agent process died or its protocol failed while we were
    /// treating it as connected. Clear the transport so the UI stops showing
    /// "Connected" and every turn stops failing at send time.
    private func handlePlanningTransportDisconnect(generation: UUID, reason: String) async {
        guard generation == transportGeneration, transport != nil else { return }
        transport = nil
        transportGeneration = nil
        agentSession = nil
        updatePlanningConfiguration([])
        let message = "Planning agent disconnected: \(reason)"
        if isPlanningDestination {
            planningTeardownGeneration = generation
            guard await tearDownPlanningTurn(guarding: generation) else { return }
            guard planningTeardownGeneration == generation else { return }
            planningTeardownGeneration = nil
            phase = .failed
            publish(.init(phase: .failed, message: message, isConnectedPlanning: false))
            phase = .idle
        } else {
            publish(.init(phase: phase, message: message, isConnectedPlanning: false))
        }
        onPlanningDisconnect?(reason)
    }

    public func disconnectPlanning() async {
        let activeTransport = transport
        let pendingTransport = connectingTransport
        let wasTearingDownPlanning = planningTeardownGeneration != nil
        transport = nil
        transportGeneration = nil
        connectingTransport = nil
        planningConnectionID = nil
        planningTeardownGeneration = nil
        agentSession = nil
        updatePlanningConfiguration([])

        if isPlanningDestination {
            await tearDownPlanningTurn()
            phase = .idle
            publish(.idle)
        } else if wasTearingDownPlanning {
            phase = .idle
            publish(.idle)
        } else if pendingTransport != nil || (activeCaptureID == nil && phase == .idle) {
            phase = .idle
            publish(.idle)
        }
        if let activeTransport {
            await activeTransport.disconnect()
        }
        if let pendingTransport {
            await pendingTransport.disconnect()
        }
    }

    @discardableResult
    private func tearDownPlanningTurn(guarding generation: UUID? = nil) async -> Bool {
        activeCaptureID = nil
        releaseRequested = false
        recognitionTask?.cancel()
        recognitionTask = nil
        assembler.reset()
        destination = nil
        await recognizer.cancel()
        if let generation, planningTeardownGeneration != generation {
            return false
        }
        await speechOutput.stopImmediately()
        return true
    }

    private func handlePlanningConfigurationUpdate(
        generation: UUID,
        options: [AgentSessionConfigurationOption]
    ) {
        guard generation == transportGeneration || generation == planningConnectionID else {
            return
        }
        updatePlanningConfiguration(options)
    }

    private func updatePlanningConfiguration(
        _ options: [AgentSessionConfigurationOption]
    ) {
        guard planningConfigurationOptions != options else { return }
        planningConfigurationOptions = options
        onPlanningConfiguration?(options)
    }

    public func beginDictation(mode: CleanupMode) async {
        guard phase == .idle, externalCaptureReservationID == nil else { return }
        let captureID = UUID()
        activeCaptureID = captureID
        phase = .preparing
        publish(.init(phase: .preparing, message: "Capturing the focused text target…"))
        do {
            let target = try await injector.captureTarget()
            try ensureActive(captureID)
            destination = .focusedTarget(target)
            try await beginCapture(
                mode: mode,
                connected: false,
                reservedCaptureID: captureID
            )
        } catch is CancellationError {
            resetIfStillActive(captureID)
        } catch {
            fail(error)
        }
    }

    public func beginPlanningTurn(mode: CleanupMode = .conservative) async {
        guard phase == .idle, transport != nil, agentSession != nil,
            externalCaptureReservationID == nil
        else { return }
        destination = .planning
        let captureID = UUID()
        activeCaptureID = captureID
        do {
            try await beginCapture(
                mode: mode,
                connected: true,
                reservedCaptureID: captureID
            )
        } catch is CancellationError {
            resetIfStillActive(captureID)
        } catch {
            fail(error, connected: true)
        }
    }

    /// A recognizer can report cancellation while this capture is still the
    /// active one — a device change during microphone startup, for instance.
    /// Returning without resetting would strand the session in `.preparing`,
    /// where no later hotkey press can start a turn.
    private func resetIfStillActive(_ captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        reset(message: "Cancelled")
    }

    public func endCapture() async {
        // connectPlanning also uses .preparing, with no capture active; a
        // hotkey release then must not announce "finishing model preparation".
        if phase == .preparing, activeCaptureID != nil {
            releaseRequested = true
            publish(
                .init(
                    phase: .finalizing,
                    transcript: assembler.transcript.text,
                    message: "Finishing model preparation…",
                    isConnectedPlanning: isPlanningDestination
                )
            )
            return
        }
        guard phase == .listening, destination != nil else { return }
        guard let captureID = activeCaptureID else { return }
        phase = .finalizing
        publish(
            .init(
                phase: .finalizing,
                transcript: assembler.transcript.text,
                message: "Finalizing…",
                isConnectedPlanning: isPlanningDestination
            )
        )

        do {
            try await recognizer.stop()
            try ensureActive(captureID)
            await recognitionTask?.value
            try ensureActive(captureID)
            recognitionTask = nil
            if let recognitionError {
                self.recognitionError = nil
                throw recognitionError
            }
            let transcript = assembler.transcript
            guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceCoreError.emptyTranscript
            }

            phase = .cleaning
            publish(
                .init(
                    phase: .cleaning,
                    transcript: transcript.text,
                    message: "Cleaning on-device…",
                    isConnectedPlanning: isPlanningDestination
                )
            )
            let spans = detector.detect(in: transcript.text)
            let cleaned = await cleaner.clean(transcript, mode: mode, protectedSpans: spans)
            try ensureActive(captureID)

            guard let destination else {
                throw VoiceCoreError.unavailable("The dictation destination was lost.")
            }
            switch destination {
            case .focusedTarget(let target):
                phase = .inserting
                publish(
                    .init(
                        phase: .inserting,
                        transcript: cleaned.text,
                        message: "Inserting…",
                        cleanupSource: cleaned.source
                    )
                )
                try await injector.insert(cleaned.text, into: target)
                try ensureActive(captureID)
                let historyError = await persist(kind: .insertedPrompt, text: cleaned.text)
                try ensureActive(captureID)
                reset(
                    message: historyError.map { "Inserted; history was not saved: \($0)" }
                        ?? "Inserted locally"
                )
            case .planning:
                try await sendPlanningPrompt(cleaned, captureID: captureID)
            }
        } catch is CancellationError {
            if activeCaptureID == captureID {
                reset(message: "Cancelled")
            }
        } catch VoiceCoreError.emptyTranscript {
            if activeCaptureID == captureID {
                reset(message: "No speech recognized")
            }
        } catch {
            guard activeCaptureID == captureID else { return }
            fail(error, connected: isPlanningDestination)
        }
    }

    public func cancel() async {
        let committedReplacement =
            recognizerReplacementID != nil
            && recognizerReplacementCommitted
        if recognizerReplacementID != nil, !recognizerReplacementCommitted {
            recognizerReplacementID = nil
        }
        hotkeyHeld = false
        activeCaptureID = nil
        planningConnectionID = nil
        let pendingTransport = connectingTransport
        connectingTransport = nil
        releaseRequested = false
        recognitionTask?.cancel()
        recognitionTask = nil
        await recognizer.cancel()
        await pendingTransport?.disconnect()
        await transport?.interrupt()
        await speechOutput.stopImmediately()
        if committedReplacement {
            assembler.reset()
            destination = nil
            recognitionError = nil
            releaseRequested = false
            phase = .preparing
            publish(
                .init(
                    phase: .preparing,
                    message: "Finishing speech model activation…",
                    isConnectedPlanning: transport != nil
                )
            )
        } else {
            reset(message: "Cancelled")
        }
    }

    /// Stops only spoken planning playback. The planning transport and session
    /// remain connected, and no interrupt is sent to the agent because its turn
    /// has already completed by the time Voice enters `.speaking`.
    @discardableResult
    public func stopSpeaking() async -> Bool {
        guard phase == .speaking else { return false }
        activeCaptureID = nil
        await speechOutput.stopImmediately()
        guard phase == .speaking else { return true }
        reset(message: "Speech stopped", connected: transport != nil)
        return true
    }

    private func beginCapture(
        mode: CleanupMode,
        connected: Bool,
        reservedCaptureID: UUID? = nil
    ) async throws {
        let captureID: UUID
        if let reservedCaptureID {
            try ensureActive(reservedCaptureID)
            captureID = reservedCaptureID
        } else {
            captureID = UUID()
            activeCaptureID = captureID
        }
        self.mode = mode
        assembler.reset()
        recognitionError = nil
        phase = .preparing
        publish(
            .init(
                phase: .preparing,
                message: "Preparing on-device speech…",
                isConnectedPlanning: connected
            )
        )
        await speechOutput.stopImmediately()
        try ensureActive(captureID)
        await waitForRecognizerUnload()
        try ensureActive(captureID)
        try await recognizer.prepare(contextualStrings: contextualStrings)
        try ensureActive(captureID)
        if releaseRequested {
            reset(message: "Speech model ready · hold the hotkey again", connected: connected)
            return
        }
        let stream = try await recognizer.start()
        try ensureActive(captureID)
        phase = .listening
        publish(
            .init(
                phase: .listening,
                message: mode == .polish ? "Listening · Polish" : "Listening · Conservative",
                isConnectedPlanning: connected
            )
        )
        recognitionTask = Task { [weak self] in
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    await self?.receive(event, captureID: captureID)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.recordRecognitionError(error, captureID: captureID)
            }
        }
        if releaseRequested {
            await endCapture()
        }
    }

    private func receive(_ event: TranscriptEvent, captureID: UUID) {
        guard activeCaptureID == captureID,
            phase == .listening || phase == .finalizing
        else {
            return
        }
        assembler.apply(event)
        let visiblePhase = phase
        publish(
            .init(
                phase: visiblePhase,
                transcript: assembler.transcript.text,
                message: visiblePhase == .finalizing
                    ? "Finalizing…"
                    : (mode == .polish ? "Listening · Polish" : "Listening · Conservative"),
                isConnectedPlanning: isPlanningDestination
            )
        )
    }

    private func recordRecognitionError(_ error: Error, captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        recognitionError = error
    }

    private func sendPlanningPrompt(
        _ cleaned: CleanedPrompt,
        captureID: UUID
    ) async throws {
        guard let transport else {
            throw VoiceCoreError.unavailable("No planning agent is connected.")
        }
        let text = cleaned.text
        phase = .planning
        publish(
            .init(
                phase: .planning,
                transcript: text,
                message: "Agent is planning…",
                isConnectedPlanning: true,
                cleanupSource: cleaned.source
            )
        )
        let events = try await transport.send(text)
        try ensureActive(captureID)
        var historyError = await persist(kind: .planningPrompt, text: text)
        try ensureActive(captureID)
        var response = ""
        for try await event in events {
            try Task.checkCancellation()
            try ensureActive(captureID)
            switch event {
            case .messageDelta(let delta):
                response += delta
                publish(
                    .init(
                        phase: .planning,
                        transcript: text,
                        message: response,
                        isConnectedPlanning: true,
                        cleanupSource: cleaned.source
                    )
                )
            case .messageCompleted(let message):
                if !message.isEmpty {
                    response = message
                    publish(
                        .init(
                            phase: .planning,
                            transcript: text,
                            message: response,
                            isConnectedPlanning: true,
                            cleanupSource: cleaned.source
                        )
                    )
                }
            case .status(let status):
                if response.isEmpty {
                    publish(
                        .init(
                            phase: .planning,
                            transcript: text,
                            message: status,
                            isConnectedPlanning: true,
                            cleanupSource: cleaned.source
                        )
                    )
                }
            case .connected, .turnCompleted:
                break
            }
        }
        if !response.isEmpty {
            historyError = await persist(kind: .planningResponse, text: response) ?? historyError
            try ensureActive(captureID)
            phase = .speaking
            publish(
                .init(
                    phase: .speaking,
                    transcript: text,
                    message: response,
                    isConnectedPlanning: true,
                    cleanupSource: cleaned.source
                )
            )
            try await speechOutput.speak(response, voiceIdentifier: selectedVoiceIdentifier)
            try ensureActive(captureID)
        }
        reset(
            message: historyError.map { "Planning ready; history was not saved: \($0)" }
                ?? "Connected planning ready",
            connected: true
        )
    }

    private var isPlanningDestination: Bool {
        guard case .planning = destination else { return false }
        return true
    }

    private func reset(message: String, connected: Bool? = nil) {
        assembler.reset()
        destination = nil
        recognitionError = nil
        activeCaptureID = nil
        releaseRequested = false
        phase = .idle
        publish(
            .init(
                phase: .idle,
                message: message,
                isConnectedPlanning: connected ?? (transport != nil)
            )
        )
    }

    private func fail(_ error: Error, connected: Bool = false) {
        Self.logger.error("turn failed: \(error.localizedDescription, privacy: .public)")
        phase = .failed
        publish(
            .init(
                phase: .failed,
                transcript: assembler.transcript.text,
                message: error.localizedDescription,
                isConnectedPlanning: connected
            )
        )
        assembler.reset()
        destination = nil
        recognitionTask = nil
        activeCaptureID = nil
        releaseRequested = false
        phase = .idle
    }

    private func publish(_ presentation: VoicePresentation) {
        presentationRevision &+= 1
        onPresentation(
            .init(
                phase: presentation.phase,
                transcript: presentation.transcript,
                message: presentation.message,
                isConnectedPlanning: presentation.isConnectedPlanning,
                cleanupSource: presentation.cleanupSource,
                revision: presentationRevision
            )
        )
    }

    private func ensureActive(_ captureID: UUID) throws {
        guard activeCaptureID == captureID else {
            throw CancellationError()
        }
    }

    private func ensureConnectionActive(_ connectionID: UUID) throws {
        guard planningConnectionID == connectionID else {
            throw CancellationError()
        }
    }

    private func persist(kind: LocalHistoryEntry.Kind, text: String) async -> String? {
        guard let historyStore, await historyStore.isEnabled else { return nil }
        do {
            try await historyStore.append(.init(kind: kind, text: text))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
