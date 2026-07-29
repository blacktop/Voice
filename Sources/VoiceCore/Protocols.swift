import Foundation

public protocol PromptCleaning: Sendable {
    func clean(
        _ transcript: Transcript,
        mode: CleanupMode,
        protectedSpans: [ProtectedSpan]
    ) async -> CleanedPrompt
}

public protocol SpeechRecognizing: Sendable {
    func prepare(contextualStrings: [String]) async throws
    func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    func stop() async throws
    func cancel() async
    func shutdown() async
}

extension SpeechRecognizing {
    /// Stops work and releases backend-specific resources when the recognizer
    /// is no longer selected. Unlike `cancel()`, implementations should not
    /// immediately warm another recognition session.
    public func shutdown() async {
        await cancel()
    }
}

public protocol SpeechOutputting: Sendable {
    func speak(_ text: String, voiceIdentifier: String?) async throws
    func stopImmediately() async
}

public struct AgentConfiguration: Sendable {
    public let executableURL: URL
    public let projectURL: URL
    public let arguments: [String]
    public let sessionConfigurationValues: [String: AgentSessionConfigurationValue]

    public init(
        executableURL: URL,
        projectURL: URL,
        arguments: [String] = [],
        sessionConfigurationValues: [String: AgentSessionConfigurationValue] = [:]
    ) {
        self.executableURL = executableURL
        self.projectURL = projectURL
        self.arguments = arguments
        self.sessionConfigurationValues = sessionConfigurationValues
    }
}

public enum AgentSessionConfigurationValue: Hashable, Sendable {
    case boolean(Bool)
    case string(String)
}

public struct AgentSessionConfigurationChoice: Identifiable, Hashable, Sendable {
    public let value: String
    public let name: String
    public let description: String?

    public var id: String { value }

    public init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }
}

public struct AgentSessionConfigurationOption: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case boolean
        case select
    }

    public let id: String
    public let name: String
    public let description: String?
    public let category: String?
    public let kind: Kind
    public let currentValue: AgentSessionConfigurationValue
    public let choices: [AgentSessionConfigurationChoice]

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        kind: Kind,
        currentValue: AgentSessionConfigurationValue,
        choices: [AgentSessionConfigurationChoice] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.kind = kind
        self.currentValue = currentValue
        self.choices = choices
    }

    public var displayChoices: [AgentSessionConfigurationChoice] {
        guard case .string(let selectedValue) = currentValue,
            !choices.contains(where: { $0.value == selectedValue })
        else {
            return choices
        }
        return [
            AgentSessionConfigurationChoice(
                value: selectedValue,
                name: selectedValue
            )
        ] + choices
    }

    public func accepts(_ value: AgentSessionConfigurationValue) -> Bool {
        switch (kind, value) {
        case (.boolean, .boolean):
            true
        case (.select, .string(let selected)):
            currentValue == value || choices.contains { $0.value == selected }
        default:
            false
        }
    }

    public func replacingCurrentValue(
        _ value: AgentSessionConfigurationValue
    ) -> AgentSessionConfigurationOption {
        AgentSessionConfigurationOption(
            id: id,
            name: name,
            description: description,
            category: category,
            kind: kind,
            currentValue: value,
            choices: choices
        )
    }
}

public struct AgentSession: Hashable, Sendable {
    public let id: String
    public let configurationOptions: [AgentSessionConfigurationOption]

    public init(
        id: String,
        configurationOptions: [AgentSessionConfigurationOption] = []
    ) {
        self.id = id
        self.configurationOptions = configurationOptions
    }
}

public enum AgentEvent: Sendable {
    case connected
    case messageDelta(String)
    case messageCompleted(String)
    case turnCompleted
    case status(String)
}

public protocol AgentTransport: Sendable {
    func connect(_ configuration: AgentConfiguration) async throws
    func startOrResume(sessionID: String?) async throws -> AgentSession
    func send(_ prompt: String) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func interrupt() async
    func disconnect() async

    /// Registers a handler invoked with a reason when the transport's
    /// connection ends for any cause other than an explicit `disconnect()`
    /// (process crash, protocol failure). Without it, callers keep treating a
    /// dead transport as connected.
    func setDisconnectHandler(_ handler: (@Sendable (String) -> Void)?) async
    func setSessionConfigurationHandler(
        _ handler: (@Sendable ([AgentSessionConfigurationOption]) -> Void)?
    ) async
    func setSessionConfiguration(
        id: String,
        value: AgentSessionConfigurationValue
    ) async throws -> [AgentSessionConfigurationOption]
}

extension AgentTransport {
    /// Transports without an external connection (e.g. in-process models) have
    /// no unexpected-disconnect condition to report.
    public func setDisconnectHandler(_: (@Sendable (String) -> Void)?) async {}

    /// Transports that do not advertise session configuration have no updates.
    public func setSessionConfigurationHandler(
        _: (@Sendable ([AgentSessionConfigurationOption]) -> Void)?
    ) async {}

    public func setSessionConfiguration(
        id _: String,
        value _: AgentSessionConfigurationValue
    ) async throws -> [AgentSessionConfigurationOption] {
        throw VoiceCoreError.unavailable(
            "This planning agent does not expose session configuration."
        )
    }
}
