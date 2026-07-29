import Foundation

/// A stable UTF-16 range suitable for Accessibility and JSON boundaries.
public struct TextRange: Codable, Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var upperBound: Int { location + length }

    public func intersects(_ other: TextRange) -> Bool {
        location < other.upperBound && other.location < upperBound
    }

    public func contains(_ other: TextRange) -> Bool {
        location <= other.location && upperBound >= other.upperBound
    }
}

public enum CleanupMode: String, Codable, CaseIterable, Sendable {
    case conservative
    case polish
}

public enum ProtectedSpanKind: String, Codable, Sendable {
    case code
    case commandFlag
    case identifier
    case negation
    case number
    case path
    case quotedText
    case url
}

public struct ProtectedSpan: Codable, Hashable, Sendable {
    public let range: TextRange
    public let kind: ProtectedSpanKind
    public let text: String

    public init(range: TextRange, kind: ProtectedSpanKind, text: String) {
        self.range = range
        self.kind = kind
        self.text = text
    }
}

public struct TextEdit: Codable, Hashable, Sendable {
    public let range: TextRange
    public let replacement: String

    public init(range: TextRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// A source edit that carries the exact text expected at its UTF-16 range.
/// Model-generated edits use this anchor so a plausible replacement cannot be
/// applied at a miscounted or stale offset.
public struct AnchoredTextEdit: Codable, Hashable, Sendable {
    public let range: TextRange
    public let original: String
    public let replacement: String

    public init(range: TextRange, original: String, replacement: String) {
        self.range = range
        self.original = original
        self.replacement = replacement
    }

    public var textEdit: TextEdit {
        TextEdit(range: range, replacement: replacement)
    }
}

public struct TranscriptEvent: Hashable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let isFinal: Bool
    public let confidence: Double?

    public init(
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        isFinal: Bool,
        confidence: Double? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.isFinal = isFinal
        self.confidence = confidence
    }

    public var endTime: TimeInterval { startTime + duration }
}

public struct TranscriptSegment: Hashable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let isFinal: Bool
    public let confidence: Double?

    public init(event: TranscriptEvent) {
        text = event.text
        startTime = event.startTime
        duration = event.duration
        isFinal = event.isFinal
        confidence = event.confidence
    }

    public var endTime: TimeInterval { startTime + duration }
}

public struct Transcript: Hashable, Sendable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    public init(text: String) {
        segments = [
            TranscriptSegment(
                event: TranscriptEvent(
                    text: text,
                    startTime: 0,
                    duration: 0,
                    isFinal: true
                )
            )
        ]
    }

    public var text: String {
        segments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct CleanedPrompt: Hashable, Sendable {
    public enum Source: String, Sendable {
        case deterministic
        case foundationModels
    }

    public let text: String
    public let source: Source
    public let appliedEdits: [TextEdit]

    public init(text: String, source: Source, appliedEdits: [TextEdit] = []) {
        self.text = text
        self.source = source
        self.appliedEdits = appliedEdits
    }
}

public enum VoiceSessionPhase: String, Sendable {
    case idle
    case preparing
    case listening
    case finalizing
    case cleaning
    case inserting
    case planning
    case speaking
    case failed
}

public struct VoicePresentation: Sendable {
    public let phase: VoiceSessionPhase
    public let transcript: String
    public let message: String
    public let isConnectedPlanning: Bool
    public let cleanupSource: CleanedPrompt.Source?
    public let revision: UInt64

    public init(
        phase: VoiceSessionPhase,
        transcript: String = "",
        message: String = "",
        isConnectedPlanning: Bool = false,
        cleanupSource: CleanedPrompt.Source? = nil,
        revision: UInt64 = 0
    ) {
        self.phase = phase
        self.transcript = transcript
        self.message = message
        self.isConnectedPlanning = isConnectedPlanning
        self.cleanupSource = cleanupSource
        self.revision = revision
    }

    public static let idle = VoicePresentation(phase: .idle, message: "Ready")
}

public enum VoiceCoreError: LocalizedError, Sendable {
    case emptyTranscript
    case invalidEditPlan(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "No speech was recognized."
        case .invalidEditPlan(let reason):
            "The cleanup edit plan was rejected: \(reason)"
        case .unavailable(let reason):
            reason
        }
    }
}
