import Foundation

/// Splits text into segments that are each synthesized as one utterance.
///
/// Qwen3-TTS generates audio tokens autoregressively at `temperature: 0.9`, so
/// sampling error compounds across a long utterance and the voice drifts into
/// nonsense partway through. Synthesizing in segments restarts that context.
///
/// A blank line always ends a segment — it is already a pause in the delivery.
/// Within a paragraph, segments are packed greedily rather than split per
/// sentence: a sentence at a time would restart prosody constantly and sound
/// clipped, so sentences are grouped until the next one would exceed the
/// budget. Boundaries are then taken at the strongest structure available —
/// sentence, then clause — and only a single run of text longer than the budget
/// with no punctuation at all is broken between words.
enum SpeechTextSegmenter {
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard budget > 0 else { return [trimmed] }

        var segments: [String] = []
        for paragraph in paragraphs(of: trimmed) {
            guard paragraph.count > budget else {
                segments.append(paragraph)
                continue
            }
            segments.append(contentsOf: pack(sentences(of: paragraph), budget: budget))
        }
        return segments
    }

    /// Greedily joins pieces until the next one would exceed the budget. A
    /// piece that is itself over budget is broken down further.
    private static func pack(_ pieces: [String], budget: Int) -> [String] {
        var segments: [String] = []
        var current = ""

        func flush() {
            let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { segments.append(candidate) }
            current = ""
        }

        for piece in pieces {
            if piece.count > budget {
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
            return pack(clauses, budget: budget)
        }
        let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [sentence] }
        return pack(words, budget: budget)
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
