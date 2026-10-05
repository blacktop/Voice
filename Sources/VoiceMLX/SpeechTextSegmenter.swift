import Foundation

/// Splits text into segments that are each synthesized as one utterance.
///
/// Qwen3-TTS generates audio tokens autoregressively, and one utterance is
/// bounded by the decoded-audio cap in `SpeechNarration`, so long text is
/// synthesized in segments. Each segment re-samples the voice, so fewer
/// boundaries means a steadier read; the pacing drift that used to build up
/// inside a long utterance came from the streaming text feed, which the
/// runtime's checkpoint no longer uses for preset and described voices.
///
/// A blank line always ends a segment — it is already a pause in the delivery.
/// Within a paragraph, segments are packed greedily rather than split per
/// sentence: a sentence at a time would restart prosody constantly and sound
/// clipped, so sentences are grouped until the next one would exceed the
/// budget. Boundaries are then taken at the strongest structure available —
/// sentence, then clause — and only a single run of text longer than the budget
/// with no punctuation at all is broken between words.
enum SpeechTextSegmenter {
    struct NarrationSegment: Equatable, Sendable {
        let text: String
        let pauseAfter: Double
    }

    /// Larger than the app's budget: a document listener values a steady
    /// voice over the first sound arriving sooner, and a paragraph within the
    /// budget is one utterance. Roughly 40 seconds of speech.
    static let narrationBudget = 500

    /// A sentence longer than this is broken at clause punctuation even in
    /// narration. Anything shorter is spoken whole: every synthesis call
    /// re-samples the voice, so a break inside a sentence is audible as a
    /// change of speaker, and the 90-second audio limit leaves room for it.
    static let narrationSentenceLimit = 600

    /// Paragraph-sized groups: a paragraph within the budget is one utterance,
    /// so the voice cannot change inside it. Paragraph breaks survive as a
    /// rest after the group rather than as whitespace sent to the model.
    static func narration(
        for text: String, budget: Int = narrationBudget,
        sentenceLimit: Int = narrationSentenceLimit
    ) -> [NarrationSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [NarrationSegment] = []
        for paragraph in paragraphs(of: normalized) {
            let words = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let pieces = segments(for: words, budget: budget, sentenceLimit: sentenceLimit)
            for (index, piece) in pieces.enumerated() {
                let sentenceEnd = piece.last.map { ".!?\"”’".contains($0) } ?? false
                result.append(
                    NarrationSegment(
                        text: piece,
                        pauseAfter: index == pieces.count - 1 ? 1.0 : (sentenceEnd ? 0.22 : 0.12)
                    )
                )
            }
        }
        return result
    }

    /// Roughly half a minute of speech at a conversational rate. Short enough
    /// that generation stays stable, long enough that ordinary announcements
    /// remain a single utterance and keep their prosody.
    static let defaultBudget = 400

    /// Splits text into the utterances to synthesize, in speaking order.
    ///
    /// - Parameters:
    ///   - text: The text to speak. Surrounding whitespace is trimmed.
    ///   - budget: The largest segment to aim for, in characters. A run of text
    ///     with no boundary to break on can still exceed it, since speaking it
    ///     beats dropping it.
    /// - Returns: The segments, or an empty array when `text` is blank.
    static func segments(for text: String, budget: Int = defaultBudget) -> [String] {
        segments(for: text, budget: budget, sentenceLimit: budget)
    }

    /// `sentenceLimit` is the length a single sentence may reach before it is
    /// broken inside; between `budget` and the limit it becomes a segment of
    /// its own instead.
    private static func segments(for text: String, budget: Int, sentenceLimit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard budget > 0 else { return [trimmed] }

        var segments: [String] = []
        for paragraph in paragraphs(of: trimmed) {
            guard paragraph.count > budget else {
                segments.append(paragraph)
                continue
            }
            segments.append(
                contentsOf: pack(sentences(of: paragraph), budget: budget, limit: sentenceLimit)
            )
        }
        return segments
    }

    /// Greedily joins pieces until the next one would exceed the budget. A
    /// piece over the limit is broken down further; one between the budget
    /// and the limit stands alone.
    private static func pack(_ pieces: [String], budget: Int, limit: Int) -> [String] {
        var segments: [String] = []
        var current = ""

        func flush() {
            let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { segments.append(candidate) }
            current = ""
        }

        for piece in pieces {
            if piece.count > max(budget, limit) {
                flush()
                segments.append(contentsOf: breakDown(piece, budget: budget))
                continue
            }
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= budget {
                current += " " + piece
            } else {
                flush()
                current = piece
            }
        }
        flush()
        return segments
    }

    /// A single sentence over budget: fall back to clause punctuation, and only
    /// then to word boundaries, so a wall of text still gets spoken.
    private static func breakDown(_ sentence: String, budget: Int) -> [String] {
        let clauses = split(sentence, on: clauseBreaks)
        if clauses.count > 1 {
            return pack(clauses, budget: budget, limit: budget)
        }
        let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [sentence] }
        return pack(words, budget: budget, limit: budget)
    }

    private static func paragraphs(of text: String) -> [String] {
        let parts = split(text, on: paragraphBreaks)
        return parts.isEmpty ? [text] : parts
    }

    private static func sentences(of paragraph: String) -> [String] {
        // Matches the convention used elsewhere in the MLX audio models: split
        // after .!? when followed by whitespace.
        let parts = split(paragraph, on: sentenceBreaks)
        return parts.isEmpty ? [paragraph] : parts
    }

    // NSRegularExpression is immutable and documented thread-safe, so each
    // pattern is compiled once rather than on every split.
    private static let paragraphBreaks = expression(#"\n\s*\n"#)
    private static let sentenceBreaks = expression(#"(?<=[.!?])\s+"#)
    private static let clauseBreaks = expression(#"(?<=[,;:—–])\s+"#)

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func split(_ text: String, on regex: NSRegularExpression?) -> [String] {
        guard let regex else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var pieces: [String] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let bound = Range(match.range, in: text) else { continue }
            let piece = String(text[cursor..<bound.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            cursor = bound.upperBound
        }
        let tail = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
