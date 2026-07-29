import Foundation
import FoundationModels
import VoiceCore

public enum LocalFoundationModelTransportError: LocalizedError, Sendable {
    case modelUnavailable(String)
    case notConnected
    case sessionNotStarted
    case sessionResumeUnsupported
    case turnInProgress

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            "Apple's on-device language model is unavailable: \(reason)"
        case .notConnected:
            "The on-device planning model is not connected."
        case .sessionNotStarted:
            "Start an on-device planning session before sending a prompt."
        case .sessionResumeUnsupported:
            "On-device planning sessions are intentionally memory-only and cannot be resumed after disconnecting."
        case .turnInProgress:
            "An on-device planning turn is already in progress."
        }
    }
}

/// A tool-free planning conversation backed only by Apple's system model.
///
/// This transport never launches a process, opens a socket, or reads project
/// files.
public actor LocalFoundationModelTransport: AgentTransport {
    private let model: SystemLanguageModel
    private var activeContinuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    private var activeGeneration: Task<Void, Never>?
    private var activeToken: UUID?
    private var session: LanguageModelSession?
    private var transportSession: AgentSession?

    public init() {
        model = SystemLanguageModel(useCase: .general)
    }

    public func connect(_: AgentConfiguration) async throws {
        await disconnect()
        guard case .available = model.availability else {
            throw LocalFoundationModelTransportError.modelUnavailable(
                Self.unavailableReason(model.availability)
            )
        }

        let session = makeSession()
        session.prewarm()
        self.session = session
    }

    public func startOrResume(sessionID: String?) async throws -> AgentSession {
        guard session != nil else {
            throw LocalFoundationModelTransportError.notConnected
        }
        if let sessionID, !sessionID.isEmpty {
            throw LocalFoundationModelTransportError.sessionResumeUnsupported
        }
        guard activeGeneration == nil else {
            throw LocalFoundationModelTransportError.turnInProgress
        }

        let transportSession = AgentSession(id: UUID().uuidString)
        self.transportSession = transportSession
        return transportSession
    }

    public func send(_ prompt: String) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard session != nil else {
            throw LocalFoundationModelTransportError.notConnected
        }
        guard transportSession != nil else {
            throw LocalFoundationModelTransportError.sessionNotStarted
        }
        guard activeGeneration == nil else {
            throw LocalFoundationModelTransportError.turnInProgress
        }

        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw VoiceCoreError.emptyTranscript
        }

        let token = UUID()
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.consumerTerminated(token: token)
            }
        }
        activeContinuation = pair.continuation
        activeToken = token
        pair.continuation.yield(.connected)
        activeGeneration = Task { [weak self] in
            await self?.generateResponse(to: text, token: token)
        }
        return pair.stream
    }

    public func interrupt() async {
        finishActiveGeneration(throwing: CancellationError())
        if session != nil {
            let freshSession = makeSession()
            freshSession.prewarm()
            session = freshSession
        }
    }

    public func disconnect() async {
        finishActiveGeneration(throwing: CancellationError())
        transportSession = nil
        session = nil
    }

    private func generateResponse(to prompt: String, token: UUID) async {
        guard let session, activeToken == token else { return }

        do {
            let stream = session.streamResponse(to: prompt)
            var emittedText = ""
            var finalText = ""

            for try await snapshot in stream {
                try Task.checkCancellation()
                guard activeToken == token else { throw CancellationError() }
                finalText = snapshot.content
                guard finalText.hasPrefix(emittedText) else {
                    // Snapshots may revise an earlier token. The canonical final
                    // message below replaces any provisional UI text.
                    continue
                }
                let delta = String(finalText.dropFirst(emittedText.count))
                if !delta.isEmpty {
                    activeContinuation?.yield(.messageDelta(delta))
                    emittedText = finalText
                }
            }

            try Task.checkCancellation()
            guard activeToken == token else { throw CancellationError() }
            activeContinuation?.yield(.messageCompleted(finalText))
            activeContinuation?.yield(.turnCompleted)
            finishActiveGeneration(token: token)
        } catch {
            if activeToken == token {
                let freshSession = makeSession()
                freshSession.prewarm()
                self.session = freshSession
            }
            finishActiveGeneration(token: token, throwing: error)
        }
    }

    private func consumerTerminated(token: UUID) {
        guard activeToken == token else { return }
        finishActiveGeneration(token: token, throwing: CancellationError())
    }

    private func finishActiveGeneration(
        token expectedToken: UUID? = nil,
        throwing error: Error? = nil
    ) {
        if let expectedToken, activeToken != expectedToken { return }
        activeGeneration?.cancel()
        activeGeneration = nil
        activeToken = nil
        if let error {
            activeContinuation?.finish(throwing: error)
        } else {
            activeContinuation?.finish()
        }
        activeContinuation = nil
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            model: model,
            instructions: """
                You are a private, on-device planning partner for software work.
                Help reason through requirements, tradeoffs, risks, tests, and
                implementation steps. You have no tools and cannot inspect project
                files, so state that limitation whenever file-specific facts matter.
                Keep answers concise, conversational, and easy to understand when
                spoken aloud. Never claim that you changed files or ran commands.
                """
        )
    }

    private static func unavailableReason(
        _ availability: SystemLanguageModel.Availability
    ) -> String {
        switch availability {
        case .available:
            "unknown reason"
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                "Apple Intelligence is not enabled"
            case .deviceNotEligible:
                "this Mac is not eligible"
            case .modelNotReady:
                "the system model is still downloading or preparing"
            @unknown default:
                "the system reported an unknown availability state"
            }
        }
    }
}
