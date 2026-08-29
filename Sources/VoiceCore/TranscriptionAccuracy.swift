import Foundation

/// Word-level edit-distance statistics between a reference transcript and a
/// recognizer hypothesis, using the standard WER definition:
/// (substitutions + insertions + deletions) / reference word count.
public struct WordErrorRate: Equatable, Sendable {
    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int
    public let referenceWordCount: Int

    public var errorCount: Int { substitutions + insertions + deletions }

    /// 0.0 for a perfect match; can exceed 1.0 when the hypothesis inserts
    /// more words than the reference contains. Nil when the reference is
    /// empty (WER is undefined without reference words).
    public var rate: Double? {
        guard referenceWordCount > 0 else { return nil }
        return Double(errorCount) / Double(referenceWordCount)
    }

    /// Case, punctuation, and whitespace differences are not recognition
    /// errors for dictation purposes, so both strings are normalized to
    /// lowercase words containing only letters, digits, and apostrophes
    /// before alignment.
    public static func compute(reference: String, hypothesis: String) -> WordErrorRate {
        let referenceWords = normalizedWords(reference)
        let hypothesisWords = normalizedWords(hypothesis)

        // Wagner-Fischer over words, tracking S/I/D counts through the
        // backtrace-free triple so memory stays linear in one dimension.
        var previous = (0...hypothesisWords.count).map { column in
            Counts(substitutions: 0, insertions: column, deletions: 0)
        }
        for (row, referenceWord) in referenceWords.enumerated() {
            var current = [Counts]()
            current.reserveCapacity(hypothesisWords.count + 1)
            current.append(
                Counts(substitutions: 0, insertions: 0, deletions: row + 1)
            )
            for (column, hypothesisWord) in hypothesisWords.enumerated() {
                if referenceWord == hypothesisWord {
                    current.append(previous[column])
                    continue
                }
                let substituted = previous[column].adding(substitutions: 1)
                let inserted = current[column].adding(insertions: 1)
                let deleted = previous[column + 1].adding(deletions: 1)
                current.append(Counts.min(substituted, Counts.min(inserted, deleted)))
            }
            previous = current
        }

        let best = previous[hypothesisWords.count]
        return WordErrorRate(
            substitutions: best.substitutions,
            insertions: best.insertions,
            deletions: best.deletions,
            referenceWordCount: referenceWords.count
        )
    }

    public static func normalizedWords(_ text: String) -> [String] {
        var normalized = ""
        normalized.reserveCapacity(text.count)
        for character in text.lowercased() {
            if character == "‘" || character == "’" {
                normalized.append("'")
            } else if character.isLetter || character.isNumber || character == "'" {
                normalized.append(character)
            } else {
                normalized.append(" ")
            }
        }
        return normalized.split(separator: " ").map(String.init)
    }

    private struct Counts {
        var substitutions: Int
        var insertions: Int
        var deletions: Int

        var total: Int { substitutions + insertions + deletions }

        func adding(substitutions: Int = 0, insertions: Int = 0, deletions: Int = 0) -> Counts {
            Counts(
                substitutions: self.substitutions + substitutions,
                insertions: self.insertions + insertions,
                deletions: self.deletions + deletions
            )
        }

        static func min(_ lhs: Counts, _ rhs: Counts) -> Counts {
            lhs.total <= rhs.total ? lhs : rhs
        }
    }
}
