import Foundation
import NaturalLanguage

/// Finds source ranges that cleanup engines must preserve byte-for-byte.
public struct ProtectedSpanDetector: Sendable {
    public init() {}

    /// Detects technical and semantic tokens using UTF-16 ranges.
    ///
    /// When candidates overlap, the containing construct wins. For example, a
    /// quoted URL is returned as quoted text, and a number in a command flag is
    /// returned as part of the command flag.
    public func detect(in text: String) -> [ProtectedSpan] {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var candidates: [SpanCandidate] = []

        for pattern in Self.patterns {
            guard let expression = pattern.expression.expression else {
                continue
            }

            for match in expression.matches(in: text, options: [], range: fullRange) {
                var range = match.range
                if pattern.trimsTrailingPunctuation {
                    range = trimmingTrailingPunctuation(from: range, in: source)
                }
                guard range.length > 0 else {
                    continue
                }

                candidates.append(
                    SpanCandidate(
                        range: TextRange(location: range.location, length: range.length),
                        kind: pattern.kind,
                        priority: pattern.priority,
                        text: source.substring(with: range)
                    )
                )
            }
        }

        let preferred = candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }

        var selected: [SpanCandidate] = []
        for candidate in preferred
        where !selected.contains(where: {
            $0.range.intersects(candidate.range)
                || $0.range == candidate.range
        }) {
            selected.append(candidate)
        }

        return
            selected
            .sorted { $0.range.location < $1.range.location }
            .map { candidate in
                ProtectedSpan(
                    range: candidate.range,
                    kind: candidate.kind,
                    text: candidate.text
                )
            }
    }

    private func trimmingTrailingPunctuation(
        from range: NSRange,
        in source: NSString
    ) -> NSRange {
        var length = range.length
        let removable = CharacterSet(charactersIn: ".,;:!?)]}")

        while length > 0 {
            let location = range.location + length - 1
            let suffix = source.substring(with: NSRange(location: location, length: 1))
            guard let scalar = suffix.unicodeScalars.first,
                removable.contains(scalar)
            else {
                break
            }
            length -= 1
        }

        return NSRange(location: range.location, length: length)
    }
}

/// Applies a deliberately small, deterministic cleanup pass without a model.
public struct DeterministicPromptCleaner: PromptCleaning, Sendable {
    private let detector: ProtectedSpanDetector
    private let normalizer: DeterministicPromptNormalizer

    public init() {
        detector = ProtectedSpanDetector()
        normalizer = DeterministicPromptNormalizer()
    }

    public func clean(
        _ transcript: Transcript,
        mode _: CleanupMode,
        protectedSpans: [ProtectedSpan]
    ) async -> CleanedPrompt {
        let source = transcript.text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CleanedPrompt(text: "", source: .deterministic)
        }

        guard
            let spans = validatedSpans(
                detected: detector.detect(in: source),
                supplied: protectedSpans,
                source: source
            )
        else {
            return CleanedPrompt(text: source, source: .deterministic)
        }

        return CleanedPrompt(
            text: normalizer.normalize(source, protecting: spans),
            source: .deterministic
        )
    }

    private func validatedSpans(
        detected: [ProtectedSpan],
        supplied: [ProtectedSpan],
        source: String
    ) -> [ProtectedSpan]? {
        let sourceString = source as NSString

        for span in supplied {
            guard Self.isValid(span.range, inUTF16Length: sourceString.length),
                sourceString.substring(
                    with: NSRange(
                        location: span.range.location,
                        length: span.range.length
                    )
                ) == span.text
            else {
                return nil
            }
        }

        let combined = (supplied + detected).sorted { lhs, rhs in
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }

        var selected: [ProtectedSpan] = []
        for span in combined
        where !selected.contains(where: {
            $0.range.intersects(span.range) || $0.range == span.range
        }) {
            selected.append(span)
        }
        return selected.sorted { $0.range.location < $1.range.location }
    }

    private static func isValid(_ range: TextRange, inUTF16Length length: Int) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

/// Validates and applies model-generated edits as one atomic operation.
public struct EditPlanValidator: Sendable {
    public init() {}

    /// Validates exact source anchors before applying the corresponding edits.
    /// This rejects model output whose UTF-16 offsets do not identify the text
    /// the model claims to be replacing.
    public func validateAndApply(
        anchoredEdits: [AnchoredTextEdit],
        to source: String,
        protectedSpans: [ProtectedSpan],
        mode: CleanupMode
    ) throws -> String {
        let sourceString = source as NSString
        let sourceLength = sourceString.length

        for edit in anchoredEdits {
            guard Self.isValid(edit.range, inUTF16Length: sourceLength) else {
                throw invalid("an anchored edit range is outside the source text")
            }
            guard Self.isAlignedToStringBoundaries(edit.range, in: source) else {
                throw invalid("an anchored edit range splits a Unicode character")
            }
            let range = NSRange(
                location: edit.range.location,
                length: edit.range.length
            )
            guard sourceString.substring(with: range) == edit.original else {
                throw invalid("an anchored edit does not match the source text")
            }
        }

        return try validateAndApply(
            edits: anchoredEdits.map(\.textEdit),
            to: source,
            protectedSpans: protectedSpans,
            mode: mode
        )
    }

    /// Returns the edited string only after every range, protected span, and
    /// mode-specific budget has been validated. No partial result is exposed.
    public func validateAndApply(
        edits: [TextEdit],
        to source: String,
        protectedSpans: [ProtectedSpan],
        mode: CleanupMode
    ) throws -> String {
        let sourceString = source as NSString
        let sourceLength = sourceString.length

        try validate(protectedSpans: protectedSpans, in: source)

        var effectiveEdits: [ValidatedEdit] = []
        for edit in edits {
            guard Self.isValid(edit.range, inUTF16Length: sourceLength) else {
                throw invalid("an edit range is outside the source text")
            }
            guard Self.isAlignedToStringBoundaries(edit.range, in: source) else {
                throw invalid("an edit range splits a Unicode character")
            }
            guard !Self.containsUnsupportedControlCharacter(edit.replacement) else {
                throw invalid("an edit replacement contains a control character")
            }

            let nsRange = NSRange(location: edit.range.location, length: edit.range.length)
            let original = sourceString.substring(with: nsRange)
            guard original != edit.replacement else {
                continue
            }

            effectiveEdits.append(
                ValidatedEdit(
                    edit: edit,
                    replacementUTF16Length: (edit.replacement as NSString).length
                )
            )
        }

        let ordered = effectiveEdits.sorted { lhs, rhs in
            if lhs.edit.range.location != rhs.edit.range.location {
                return lhs.edit.range.location < rhs.edit.range.location
            }
            return lhs.edit.range.length < rhs.edit.range.length
        }

        try validateNoOverlaps(ordered)
        try validateProtectedSpans(protectedSpans, against: ordered)

        guard !ordered.isEmpty else {
            return source
        }
        try validateBudget(ordered, sourceUTF16Length: sourceLength, mode: mode)
        guard sourceLength > 0 else {
            throw invalid("cleanup cannot invent text for an empty transcript")
        }

        let result = NSMutableString(string: source)
        for validated in ordered.reversed() {
            let range = validated.edit.range
            result.replaceCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: validated.edit.replacement
            )
        }

        let output = result as String
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("the edit plan would erase the transcript")
        }
        try verifyProtectedSpans(
            protectedSpans,
            afterApplying: ordered,
            to: output
        )
        return output
    }

    private func validate(protectedSpans: [ProtectedSpan], in source: String) throws {
        let sourceString = source as NSString
        for span in protectedSpans {
            guard Self.isValid(span.range, inUTF16Length: sourceString.length),
                Self.isAlignedToStringBoundaries(span.range, in: source)
            else {
                throw invalid("a protected span is outside the source text")
            }

            let range = NSRange(location: span.range.location, length: span.range.length)
            guard sourceString.substring(with: range) == span.text else {
                throw invalid("a protected span does not match the source text")
            }
        }
    }

    private func validateNoOverlaps(_ edits: [ValidatedEdit]) throws {
        for index in edits.indices.dropFirst() {
            let previous = edits[edits.index(before: index)].edit.range
            let current = edits[index].edit.range
            if current.location < previous.upperBound
                || current.location == previous.location
            {
                throw invalid("edit ranges overlap or are ambiguous")
            }
        }
    }

    private func validateProtectedSpans(
        _ spans: [ProtectedSpan],
        against edits: [ValidatedEdit]
    ) throws {
        for validated in edits {
            let editRange = validated.edit.range
            for span in spans {
                let changesProtectedText: Bool
                if editRange.length == 0 {
                    changesProtectedText =
                        editRange.location > span.range.location
                        && editRange.location < span.range.upperBound
                } else {
                    changesProtectedText = editRange.intersects(span.range)
                }

                if changesProtectedText {
                    throw invalid("an edit changes a protected \(span.kind.rawValue) span")
                }
            }
        }
    }

    private func validateBudget(
        _ edits: [ValidatedEdit],
        sourceUTF16Length: Int,
        mode: CleanupMode
    ) throws {
        let budget = EditBudget(mode: mode, sourceUTF16Length: sourceUTF16Length)
        guard edits.count <= budget.maximumEditCount else {
            throw invalid("the edit plan exceeds the \(mode.rawValue) edit-count budget")
        }

        var replacedUnits = 0
        var replacementUnits = 0
        for edit in edits {
            guard replacedUnits <= Int.max - edit.edit.range.length,
                replacementUnits <= Int.max - edit.replacementUTF16Length
            else {
                throw invalid("the edit plan size overflowed")
            }
            replacedUnits += edit.edit.range.length
            replacementUnits += edit.replacementUTF16Length
        }

        guard replacedUnits <= budget.maximumReplacedUTF16Units else {
            throw invalid("the edit plan replaces too much source text")
        }
        guard replacementUnits <= budget.maximumReplacementUTF16Units else {
            throw invalid("the edit plan introduces too much replacement text")
        }
        if mode == .conservative,
            sourceUTF16Length > 0,
            edits.contains(where: {
                $0.edit.range.location == 0
                    && $0.edit.range.length == sourceUTF16Length
            })
        {
            throw invalid("conservative cleanup cannot replace the whole transcript")
        }

        let retainedUnits = sourceUTF16Length - replacedUnits
        guard retainedUnits <= Int.max - replacementUnits else {
            throw invalid("the edited output size overflowed")
        }
        let outputLength = retainedUnits + replacementUnits
        guard outputLength >= budget.minimumOutputUTF16Units,
            outputLength <= budget.maximumOutputUTF16Units
        else {
            throw invalid("the edited output is outside the \(mode.rawValue) size budget")
        }
    }

    private func verifyProtectedSpans(
        _ spans: [ProtectedSpan],
        afterApplying edits: [ValidatedEdit],
        to output: String
    ) throws {
        let outputString = output as NSString

        for span in spans {
            var shift = 0
            for edit in edits where edit.edit.range.upperBound <= span.range.location {
                shift += edit.replacementUTF16Length - edit.edit.range.length
            }

            let location = span.range.location + shift
            let adjusted = TextRange(location: location, length: span.range.length)
            guard Self.isValid(adjusted, inUTF16Length: outputString.length),
                outputString.substring(
                    with: NSRange(location: adjusted.location, length: adjusted.length)
                ) == span.text
            else {
                throw invalid("a protected span was not preserved exactly")
            }
        }
    }

    private func invalid(_ reason: String) -> VoiceCoreError {
        .invalidEditPlan(reason)
    }

    private static func isValid(_ range: TextRange, inUTF16Length length: Int) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private static func isAlignedToStringBoundaries(
        _ range: TextRange,
        in source: String
    ) -> Bool {
        let utf16 = source.utf16
        guard
            let lowerUTF16 = utf16.index(
                utf16.startIndex,
                offsetBy: range.location,
                limitedBy: utf16.endIndex
            ),
            let upperUTF16 = utf16.index(
                lowerUTF16,
                offsetBy: range.length,
                limitedBy: utf16.endIndex
            )
        else {
            return false
        }

        return String.Index(lowerUTF16, within: source) != nil
            && String.Index(upperUTF16, within: source) != nil
    }

    private static func containsUnsupportedControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || value == 0x7F
        }
    }
}

/// The deterministic text transformation is public for fixture and benchmark use.
public struct DeterministicPromptNormalizer: Sendable {
    public init() {}

    public func normalize(_ source: String, protecting spans: [ProtectedSpan]) -> String {
        guard let masked = MaskedText(source: source, protectedSpans: spans) else {
            return source
        }

        var text = masked.text
        text = Self.newParagraphCommand.replacing(in: text, with: "\n\n")
        text = Self.newLineCommand.replacing(in: text, with: "\n")
        text = Self.questionMarkCommand.replacing(in: text, with: "?")
        text = Self.fullStopCommand.replacing(in: text, with: ".")
        text = Self.semicolonCommand.replacing(in: text, with: ";")
        text = Self.colonCommand.replacing(in: text, with: ":")
        text = Self.commaCommand.replacing(in: text, with: ",")

        text = Self.fillerWords.replacing(in: text, with: "")

        text = Self.horizontalWhitespaceRuns.replacing(in: text, with: " ")
        text = Self.spacePaddedNewlines.replacing(in: text, with: "\n")
        text = Self.blankLineRuns.replacing(in: text, with: "\n\n")
        text = Self.spaceBeforePunctuation.replacing(in: text, with: "$1")
        text = Self.repeatedSeparators.replacing(in: text, with: "$1")
        text = Self.missingSpaceAfterPunctuation.replacing(in: text, with: "$1 ")
        text = Self.leadingClutter.replacing(in: text, with: "")
        text = Self.trailingClutter.replacing(in: text, with: "")
        text = capitalizeSentenceStarts(in: text)
        // The final sentence is inspected while protected spans are still
        // masked, so punctuation inside a protected URL or identifier cannot
        // truncate it.
        let finalSentence = Self.finalSentence(of: text)
        text = masked.restoring(in: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return ""
        }
        guard
            shouldAppendTerminalPunctuation(
                to: text,
                originalSource: source,
                protectedSpans: spans
            )
        else {
            return text
        }

        let question = Self.interrogativeOpening.matches(in: finalSentence)
        return text + (question ? "?" : ".")
    }

    /// The last sentence decides the appended terminal mark; an interrogative
    /// opening earlier in the text must not turn an unrelated closing
    /// statement into a question.
    private static func finalSentence(of text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var finalSentence = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let candidate = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                finalSentence = candidate
            }
            return true
        }
        return finalSentence
    }

    private func capitalizeSentenceStarts(in text: String) -> String {
        guard let expression = Self.sentenceStartLetter.expression else {
            return text
        }

        let mutable = NSMutableString(string: text)
        let fullRange = NSRange(location: 0, length: mutable.length)
        for match in expression.matches(in: text, options: [], range: fullRange).reversed() {
            let letterRange = match.range(at: 1)
            guard letterRange.location != NSNotFound else {
                continue
            }
            let uppercase = mutable.substring(with: letterRange).uppercased()
            mutable.replaceCharacters(in: letterRange, with: uppercase)
        }
        return mutable as String
    }

    private func shouldAppendTerminalPunctuation(
        to text: String,
        originalSource: String,
        protectedSpans: [ProtectedSpan]
    ) -> Bool {
        guard let last = text.unicodeScalars.last else {
            return false
        }
        let terminalCharacters = CharacterSet(charactersIn: ".!?;:)]}\"'`")
        if terminalCharacters.contains(last) {
            return false
        }

        let originalLength = endOffsetExcludingTrailingWhitespace(in: originalSource)
        return !protectedSpans.contains { span in
            span.kind != .negation && span.range.upperBound == originalLength
        }
    }

    private func endOffsetExcludingTrailingWhitespace(in text: String) -> Int {
        var trailingUTF16Length = 0
        for scalar in text.unicodeScalars.reversed() {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            trailingUTF16Length += String(scalar).utf16.count
        }
        return (text as NSString).length - trailingUTF16Length
    }
}

extension DeterministicPromptNormalizer {
    fileprivate static let newParagraphCommand = CompiledExpression(#"(?i)\bnew\s+paragraph\b"#)
    fileprivate static let newLineCommand = CompiledExpression(#"(?i)\bnew\s+line\b"#)
    fileprivate static let questionMarkCommand = CompiledExpression(#"(?i)\bquestion\s+mark\b"#)
    fileprivate static let fullStopCommand = CompiledExpression(#"(?i)\b(?:full\s+stop|period)\b"#)
    fileprivate static let semicolonCommand = CompiledExpression(#"(?i)\bsemicolon\b"#)
    fileprivate static let colonCommand = CompiledExpression(#"(?i)\bcolon\b"#)
    fileprivate static let commaCommand = CompiledExpression(#"(?i)\bcomma\b"#)
    fileprivate static let fillerWords = CompiledExpression(
        #"(?i)(?<![\p{L}\p{N}_])(?:um+|uh+|erm+|er+|ah+|hmm+)(?![\p{L}\p{N}_])(?:[.!?]+(?=\s|$))?"#
    )
    fileprivate static let horizontalWhitespaceRuns = CompiledExpression(#"[ \t]+"#)
    fileprivate static let spacePaddedNewlines = CompiledExpression(#" *\n *"#)
    fileprivate static let blankLineRuns = CompiledExpression(#"\n{3,}"#)
    fileprivate static let spaceBeforePunctuation = CompiledExpression(#"\s+([,.;:!?])"#)
    fileprivate static let repeatedSeparators = CompiledExpression(#"([,;:])(?:\s*[,;:])+"#)
    fileprivate static let missingSpaceAfterPunctuation = CompiledExpression(
        #"([,;:.!?])(?=[\p{L}\p{N}])"#)
    /// Terminal marks attached to a leading filler are consumed with that
    /// filler, so intentional leading ellipses remain untouched here.
    fileprivate static let leadingClutter = CompiledExpression(#"^[\s,;:]+"#)
    fileprivate static let trailingClutter = CompiledExpression(#"[\s,;]+$"#)
    fileprivate static let sentenceStartLetter = CompiledExpression(
        #"(?:^|[.!?]\s+|\n\n)([\p{Ll}])"#)
    fileprivate static let interrogativeOpening = CompiledExpression(
        #"(?i)^(?:who|what|where|when|why|how|can|could|would|should|is|are|do|does|did|will|have|has)\b"#
    )
}

/// NSRegularExpression is immutable and documented thread-safe; the unchecked
/// conformance lets each pattern be compiled once and shared instead of being
/// recompiled on every cleanup pass.
private struct CompiledExpression: @unchecked Sendable {
    let expression: NSRegularExpression?

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        expression = try? NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(in text: String) -> Bool {
        guard let expression else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    func replacing(in text: String, with template: String) -> String {
        guard let expression else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

private struct DetectorPattern: Sendable {
    let expression: CompiledExpression
    let kind: ProtectedSpanKind
    let priority: Int
    let trimsTrailingPunctuation: Bool

    init(
        _ pattern: String,
        kind: ProtectedSpanKind,
        priority: Int,
        options: NSRegularExpression.Options = [],
        trimsTrailingPunctuation: Bool = false
    ) {
        expression = CompiledExpression(pattern, options: options)
        self.kind = kind
        self.priority = priority
        self.trimsTrailingPunctuation = trimsTrailingPunctuation
    }
}

private struct SpanCandidate: Sendable {
    let range: TextRange
    let kind: ProtectedSpanKind
    let priority: Int
    let text: String
}

extension ProtectedSpanDetector {
    fileprivate static let patterns: [DetectorPattern] = [
        DetectorPattern(#"```[\s\S]*?```"#, kind: .code, priority: 1_000),
        DetectorPattern(#"`[^`\r\n]+`"#, kind: .code, priority: 1_000),
        DetectorPattern(#"\"(?:\\.|[^\"\\\r\n])+\""#, kind: .quotedText, priority: 1_000),
        DetectorPattern(
            #"(?<![\p{L}\p{N}])'(?:\\.|[^'\\\r\n])+'(?![\p{L}\p{N}])"#,
            kind: .quotedText,
            priority: 1_000
        ),
        DetectorPattern(#"“[^”\r\n]+”|‘[^’\r\n]+’"#, kind: .quotedText, priority: 1_000),
        DetectorPattern(
            #"(?<![\p{L}\p{N}_])--?[A-Za-z][A-Za-z0-9-]*(?:=[^\s,;]+)?"#,
            kind: .commandFlag,
            priority: 950,
            trimsTrailingPunctuation: true
        ),
        DetectorPattern(
            #"\b(?:https?|file)://[^\s<>\"'`]+"#,
            kind: .url,
            priority: 900,
            options: [.caseInsensitive],
            trimsTrailingPunctuation: true
        ),
        DetectorPattern(
            #"\bwww\.[^\s<>\"'`]+"#,
            kind: .url,
            priority: 900,
            options: [.caseInsensitive],
            trimsTrailingPunctuation: true
        ),
        DetectorPattern(
            #"(?<![\p{L}\p{N}_])(?:~|\.{1,2})?/(?:[^\s\"'`<>]+)"#,
            kind: .path,
            priority: 800,
            trimsTrailingPunctuation: true
        ),
        DetectorPattern(
            #"\b(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+\b"#,
            kind: .path,
            priority: 800
        ),
        DetectorPattern(
            #"(?i)(?<![\p{L}\p{N}_])[-+]?0x[0-9a-f]+(?![\p{L}\p{N}_])"#,
            kind: .number,
            priority: 700
        ),
        DetectorPattern(
            #"(?<![\p{L}\p{N}_])[-+]?(?:\d+(?:[.,]\d+)*|\.\d+)(?:%|[A-Za-z]{1,4})?(?![\p{L}\p{N}_])"#,
            kind: .number,
            priority: 700
        ),
        DetectorPattern(
            #"(?i)\b(?:no|not|never|without|neither|nor|cannot|can['’]?t|won['’]?t|don['’]?t|doesn['’]?t|didn['’]?t|isn['’]?t|aren['’]?t|wasn['’]?t|weren['’]?t|shouldn['’]?t|wouldn['’]?t|couldn['’]?t|mustn['’]?t|needn['’]?t)\b"#,
            kind: .negation,
            priority: 600
        ),
        DetectorPattern(
            #"(?<![\p{L}\p{N}_])(?:@|\$)[A-Za-z_][A-Za-z0-9_]*\b"#,
            kind: .code,
            priority: 500
        ),
        DetectorPattern(
            #"\b[A-Za-z_][A-Za-z0-9_]*\s*\(\)"#,
            kind: .code,
            priority: 500
        ),
        DetectorPattern(
            #"\b[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+\b"#,
            kind: .identifier,
            priority: 400
        ),
        DetectorPattern(
            #"\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b"#,
            kind: .identifier,
            priority: 400
        ),
        DetectorPattern(
            #"\b[a-z]+(?:[A-Z][A-Za-z0-9]*)+\b"#,
            kind: .identifier,
            priority: 400
        ),
        DetectorPattern(
            #"\b(?:[A-Z][a-z0-9]+){2,}\b"#,
            kind: .identifier,
            priority: 400
        ),
        DetectorPattern(#"\b[A-Z][A-Z0-9]{1,}\b"#, kind: .identifier, priority: 400),
    ]
}

private struct ValidatedEdit: Sendable {
    let edit: TextEdit
    let replacementUTF16Length: Int
}

private struct EditBudget: Sendable {
    let maximumEditCount: Int
    let maximumReplacedUTF16Units: Int
    let maximumReplacementUTF16Units: Int
    let minimumOutputUTF16Units: Int
    let maximumOutputUTF16Units: Int

    init(mode: CleanupMode, sourceUTF16Length: Int) {
        switch mode {
        case .conservative:
            maximumEditCount = 12
            maximumReplacedUTF16Units = max(8, Self.ceilingFraction(sourceUTF16Length, 1, 4))
            maximumReplacementUTF16Units = max(16, Self.ceilingFraction(sourceUTF16Length, 1, 2))
            minimumOutputUTF16Units = max(1, sourceUTF16Length / 2)
            maximumOutputUTF16Units = Self.addingWithoutOverflow(
                sourceUTF16Length,
                max(16, Self.ceilingFraction(sourceUTF16Length, 1, 3))
            )
        case .polish:
            maximumEditCount = 48
            maximumReplacedUTF16Units = max(32, sourceUTF16Length)
            maximumReplacementUTF16Units = max(
                64,
                Self.addingWithoutOverflow(sourceUTF16Length, sourceUTF16Length)
            )
            minimumOutputUTF16Units = max(1, sourceUTF16Length / 3)
            maximumOutputUTF16Units = max(
                128, Self.addingWithoutOverflow(sourceUTF16Length, sourceUTF16Length))
        }
    }

    private static func ceilingFraction(_ value: Int, _ numerator: Int, _ denominator: Int) -> Int {
        let quotient = value / denominator
        let remainder = value % denominator
        return quotient * numerator + (remainder == 0 ? 0 : numerator)
    }

    private static func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        lhs <= Int.max - rhs ? lhs + rhs : Int.max
    }
}

private struct MaskedText: Sendable {
    let text: String
    private let replacements: [(marker: String, original: String)]

    init?(source: String, protectedSpans: [ProtectedSpan]) {
        let sourceString = source as NSString
        let ordered = protectedSpans.sorted { $0.range.location < $1.range.location }

        for span in ordered {
            guard span.range.location >= 0,
                span.range.length >= 0,
                span.range.location <= sourceString.length,
                span.range.length <= sourceString.length - span.range.location,
                sourceString.substring(
                    with: NSRange(location: span.range.location, length: span.range.length)
                ) == span.text
            else {
                return nil
            }
        }

        for index in ordered.indices.dropFirst() {
            let previous = ordered[ordered.index(before: index)].range
            if ordered[index].range.location < previous.upperBound {
                return nil
            }
        }

        var prefix = "\u{E000}"
        while source.contains(prefix) {
            prefix.append("\u{E000}")
        }
        let suffix = "\u{E001}"
        let replacements = ordered.enumerated().map { index, span in
            (marker: "\(prefix)\(index)\(suffix)", original: span.text)
        }

        let mutable = NSMutableString(string: source)
        for (index, span) in ordered.enumerated().reversed() {
            mutable.replaceCharacters(
                in: NSRange(location: span.range.location, length: span.range.length),
                with: replacements[index].marker
            )
        }

        text = mutable as String
        self.replacements = replacements
    }

    func restoring(in maskedText: String) -> String {
        replacements.reduce(maskedText) { partial, replacement in
            partial.replacingOccurrences(of: replacement.marker, with: replacement.original)
        }
    }
}
