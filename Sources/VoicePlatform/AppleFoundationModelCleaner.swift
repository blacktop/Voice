import Foundation
import FoundationModels
import VoiceCore

@Generable(description: "A minimal set of source edits that repairs dictated text")
private struct GeneratedCleanupPlan {
    var edits: [GeneratedCleanupEdit]
}

@Generable(description: "One source-anchored UTF-16 range replacement")
private struct GeneratedCleanupEdit {
    var location: Int
    var length: Int
    var original: String
    var replacement: String
}

enum CleanupExecutionPolicy {
    static func usesFoundationModels(for mode: CleanupMode) -> Bool {
        mode == .polish
    }
}

/// Deterministic conservative cleanup plus opt-in Apple model polishing.
public actor AppleFoundationModelCleaner: PromptCleaning {
    private let deterministic = DeterministicPromptCleaner()
    private let detector = ProtectedSpanDetector()
    private let validator = EditPlanValidator()
    private let model: SystemLanguageModel
    private var prewarmedSession: LanguageModelSession?

    public init() {
        model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    public func prewarm() {
        guard case .available = model.availability else { return }
        prepareNextSession()
    }

    public func clean(
        _ transcript: VoiceCore.Transcript,
        mode: CleanupMode,
        protectedSpans suppliedProtectedSpans: [ProtectedSpan]
    ) async -> CleanedPrompt {
        let fallback = await deterministic.clean(
            transcript,
            mode: mode,
            protectedSpans: suppliedProtectedSpans
        )

        // Conservative dictation is the default path for commands and coding
        // prompts. Keep it deterministic: a generative model cannot be allowed
        // to make arbitrary lexical changes such as `bit` -> `bite`. Polish is
        // the explicit opt-in for model-assisted prose editing.
        guard CleanupExecutionPolicy.usesFoundationModels(for: mode) else {
            return fallback
        }

        let source = fallback.text
        guard !source.isEmpty, case .available = model.availability else {
            return fallback
        }

        let protectedSpans = detector.detect(in: source)
        let protectedSummary =
            protectedSpans
            .map { "\($0.kind.rawValue): \($0.text)" }
            .joined(separator: "\n")

        do {
            let response = try await takeSession().respond(
                to: prompt(
                    source: source,
                    protectedSummary: protectedSummary
                ),
                generating: GeneratedCleanupPlan.self
            )
            let anchoredEdits = response.content.edits.map {
                AnchoredTextEdit(
                    range: TextRange(location: $0.location, length: $0.length),
                    original: $0.original,
                    replacement: $0.replacement
                )
            }
            let cleaned = try validator.validateAndApply(
                anchoredEdits: anchoredEdits,
                to: source,
                protectedSpans: protectedSpans,
                mode: mode
            )
            prepareNextSession()
            return CleanedPrompt(
                text: cleaned,
                source: .foundationModels,
                appliedEdits: anchoredEdits.map(\.textEdit)
            )
        } catch is CancellationError {
            prepareNextSession()
            return fallback
        } catch {
            // Generated edits are untrusted. Any generation or validation
            // failure falls back atomically to deterministic cleanup.
            prepareNextSession()
            return fallback
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            model: model,
            instructions: """
                You edit dictated prompts for software engineering work. Return only
                minimal source-anchored UTF-16 range edits. For every edit, original
                must exactly equal the source substring at location and length; use an
                empty original only for a zero-length insertion. Never answer the prompt.
                Never invent facts, commands, names, numbers, constraints, or code.
                Preserve every protected token exactly. Preserve negation, scope, and
                intent. Empty edits are valid.
                """
        )
    }

    private func takeSession() -> LanguageModelSession {
        if let prewarmedSession {
            self.prewarmedSession = nil
            return prewarmedSession
        }
        return makeSession()
    }

    private func prepareNextSession() {
        guard prewarmedSession == nil, case .available = model.availability else {
            return
        }
        let session = makeSession()
        session.prewarm()
        prewarmedSession = session
    }

    private func prompt(
        source: String,
        protectedSummary: String
    ) -> String {
        return """
            MODE
            You may reorganize prose into clear paragraphs or bullets, but preserve
            meaning and every protected token.

            PROTECTED TOKENS
            \(protectedSummary.isEmpty ? "(none)" : protectedSummary)

            SOURCE TEXT
            <dictation>\(source)</dictation>
            """
    }
}
