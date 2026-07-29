import Foundation

/// Reconciles overlapping volatile and final SpeechAnalyzer results by time range.
public struct TranscriptAssembler: Sendable {
    private var segments: [TranscriptSegment] = []

    public init() {}

    /// Segments are kept in presentation order by apply(), so reading the
    /// transcript on every partial result does not re-sort.
    public var transcript: Transcript {
        Transcript(segments: segments)
    }

    public mutating func apply(_ event: TranscriptEvent) {
        let tolerance = 0.015
        var incoming = TranscriptSegment(event: event)

        segments.removeAll { existing in
            if existing.isFinal, !incoming.isFinal {
                return false
            }
            // Half-open audio ranges that merely touch are consecutive, not
            // overlapping. Expanding both ends by the tail tolerance would
            // delete adjacent finalized chunks under frequent finalization.
            let overlaps =
                incoming.startTime < existing.endTime
                && existing.startTime < incoming.endTime
            let replacesVolatileTail =
                !existing.isFinal
                && abs(incoming.startTime - existing.startTime) <= tolerance
            return overlaps || replacesVolatileTail
        }

        if !incoming.isFinal {
            guard let deduplicated = removingWordsAlreadyFinalized(from: incoming) else {
                return
            }
            incoming = deduplicated
        }

        guard !incoming.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        segments.append(incoming)
        segments.sort(by: Self.precedesInPresentationOrder)
    }

    private static func precedesInPresentationOrder(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment
    ) -> Bool {
        if lhs.startTime == rhs.startTime {
            return lhs.isFinal && !rhs.isFinal
        }
        return lhs.startTime < rhs.startTime
    }

    /// A volatile result that reaches back into finalized audio re-transcribes the
    /// tail of that final. Keeping both duplicates those words in the transcript,
    /// so trim the re-transcribed prefix (or drop the volatile entirely when the
    /// finalized audio already covers it).
    private func removingWordsAlreadyFinalized(
        from incoming: TranscriptSegment
    ) -> TranscriptSegment? {
        let overlappingFinal =
            segments
            .filter { existing in
                existing.isFinal
                    && existing.startTime < incoming.endTime
                    && incoming.startTime < existing.endTime
            }
            .max { $0.endTime < $1.endTime }
        guard let overlappingFinal else {
            return incoming
        }
        if incoming.endTime <= overlappingFinal.endTime {
            return nil
        }

        let finalWords = overlappingFinal.text.split(whereSeparator: \.isWhitespace)
        let incomingWords = incoming.text.split(whereSeparator: \.isWhitespace)
        var duplicateCount = 0
        for count in stride(from: min(finalWords.count, incomingWords.count), through: 1, by: -1)
        where finalWords.suffix(count).elementsEqual(
            incomingWords.prefix(count),
            by: { $0.lowercased() == $1.lowercased() }
        ) {
            duplicateCount = count
            break
        }
        guard duplicateCount > 0 else {
            return incoming
        }

        let remainingWords = incomingWords.dropFirst(duplicateCount)
        guard !remainingWords.isEmpty else {
            return nil
        }
        let clippedStart = max(incoming.startTime, overlappingFinal.endTime)
        return TranscriptSegment(
            event: TranscriptEvent(
                text: remainingWords.joined(separator: " "),
                startTime: clippedStart,
                duration: incoming.endTime - clippedStart,
                isFinal: false,
                confidence: incoming.confidence
            )
        )
    }

    public mutating func reset() {
        segments.removeAll(keepingCapacity: true)
    }
}
